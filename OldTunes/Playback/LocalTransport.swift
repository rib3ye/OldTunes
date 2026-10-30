import AVFoundation

/// Plays files on this Mac with `AVQueuePlayer` (RESEARCH.md §5.2).
///
/// The player never advances on its own (`actionAtItemEnd = .none`): it reports the end and the
/// coordinator decides what comes next, so shuffle and repeat live in exactly one place. The
/// queue holds at most one item beyond the current one, a preloaded next file, which is as close
/// to gapless as AVFoundation gets without a custom decoder.
@MainActor
final class LocalTransport: Transport {
    var onFinish: (() -> Void)?
    var onError: ((Error) -> Void)?

    private let player = AVQueuePlayer()
    private(set) var duration: TimeInterval = 0
    /// Bumped by load() and stop(), so a load that finishes awaiting after a stop() gives up.
    private var loadToken = 0
    private var reportedFailure = false
    private var preloaded: (url: URL, asset: AVURLAsset, item: AVPlayerItem)?
    /// Held for the transport's lifetime; the coordinator owns exactly one.
    private var observers: [NSObjectProtocol] = []

    init() {
        player.actionAtItemEnd = .none
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let item = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated { self?.itemEnded(item) }
        })
        observers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let item = (note.object as AnyObject?).map(ObjectIdentifier.init)
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.itemFailed(item, error) }
        })
    }

    var position: TimeInterval {
        let t = player.currentTime().seconds
        return t.isFinite ? max(0, t) : 0
    }

    var isPlaying: Bool { player.currentItem != nil && player.rate != 0 }

    /// The slider's setting. The player gets this times the Sound Check gain.
    var volume: Float {
        get { sliderVolume }
        set {
            sliderVolume = min(max(newValue, 0), 1)
            applyVolume()
        }
    }

    /// Settings ▸ Sound Check.
    var isSoundCheckOn = false {
        didSet { applyVolume() }
    }

    /// The Sound Check gain of the song being loaded or played, as a factor (SoundCheck). The player
    /// has one volume for every item, so the coordinator sets this just before each load, while
    /// nothing is sounding; a preloaded file then starts at its own level.
    var soundCheckGain: Float = 1 {
        didSet { applyVolume() }
    }

    private var sliderVolume: Float = 1

    /// What AVPlayer was given: the slider times the gain. For the harness's logs.
    var playerVolume: Float { player.volume }

    /// The file queued behind the current one, if any. For the playback bench, which checks
    /// that a protected download or a package is never queued.
    var preloadedURL: URL? { preloaded?.url }

    /// AVPlayer's volume stops at 1, the file's own level. So a song Sound Check makes louder
    /// (energy under 1000) is matched only as far as the slider leaves room: exactly while
    /// slider × gain ≤ 1, and held at the file's own level above that.
    private func applyVolume() {
        player.volume = min(sliderVolume * (isSoundCheckOn ? soundCheckGain : 1), 1)
    }

    /// Throws `.protected` for a protected download, which AVFoundation may still call playable
    /// (AVAsset.h), so the coordinator streams the song from iCloud instead. Checked here, at
    /// load, because a failure once playing skips to the next song rather than trying iCloud.
    func load(_ what: Playable) async throws {
        guard case .local(let url) = what else { throw TransportError.unsupported }
        loadToken += 1
        let token = loadToken
        reportedFailure = false

        if let next = preloaded, next.url == url, player.items().dropFirst().first === next.item {
            preloaded = nil
            // The same checks as a fresh load; on a throw the coordinator's stop() empties the queue.
            let (playable, protected, length) = try await next.asset.load(.isPlayable, .hasProtectedContent, .duration)
            guard token == loadToken else { throw CancellationError() }
            guard !protected else { throw TransportError.protected }
            guard playable else { throw TransportError.notPlayable }
            player.advanceToNextItem()
            duration = length.seconds.isFinite ? length.seconds : 0
            Log.info("local: started the preloaded next file \(url.lastPathComponent)")
            return
        }

        let asset = AVURLAsset(url: url)
        let (playable, protected, length) = try await asset.load(.isPlayable, .hasProtectedContent, .duration)
        guard token == loadToken else { throw CancellationError() }
        guard !protected else { throw TransportError.protected }
        guard playable else { throw TransportError.notPlayable }
        preloaded = nil
        player.removeAllItems()
        player.insert(AVPlayerItem(asset: asset), after: nil)
        duration = length.seconds.isFinite ? length.seconds : 0
    }

    /// Queues `url` behind the current item so its decode overlaps the current song's playback.
    /// Not a protected download: queued, it would sit behind this song only to fail when reached,
    /// while its own start sends it to iCloud.
    func preload(_ url: URL) async {
        guard player.currentItem != nil, preloaded?.url != url else { return }
        let token = loadToken
        let asset = AVURLAsset(url: url)
        // A file that won't say is left to its own start too, which reports why.
        guard let protected = try? await asset.load(.hasProtectedContent), !protected else { return }
        // A load() or stop() meanwhile changed what is playing.
        guard token == loadToken, player.currentItem != nil, preloaded?.url != url else { return }
        for item in player.items().dropFirst() { player.remove(item) }
        let item = AVPlayerItem(asset: asset)
        player.insert(item, after: player.currentItem)
        preloaded = (url, asset, item)
    }

    func play() async throws {
        guard player.currentItem != nil else { throw TransportError.notPlayable }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        loadToken += 1
        player.pause()
        player.removeAllItems()
        preloaded = nil
        duration = 0
    }

    func seek(to seconds: TimeInterval) {
        guard player.currentItem != nil else { return }
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func clockDidTick() {
        // A file that opens but cannot be decoded fails here rather than in load().
        if !reportedFailure, let item = player.currentItem, item.status == .failed {
            reportedFailure = true
            onError?(item.error ?? TransportError.notPlayable)
        }
    }

    /// Items are compared by identity because the notification also fires for other players' items.
    private func itemEnded(_ item: ObjectIdentifier?) {
        guard let current = player.currentItem, item == ObjectIdentifier(current) else { return }
        onFinish?()
    }

    private func itemFailed(_ item: ObjectIdentifier?, _ error: Error?) {
        guard let current = player.currentItem, item == ObjectIdentifier(current), !reportedFailure else { return }
        reportedFailure = true
        onError?(error ?? TransportError.notPlayable)
    }
}
