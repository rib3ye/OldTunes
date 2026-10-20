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

    var volume: Float {
        get { player.volume }
        set { player.volume = min(max(newValue, 0), 1) }
    }

    func load(_ what: Playable) async throws {
        guard case .local(let url) = what else { throw TransportError.unsupported }
        loadToken += 1
        let token = loadToken
        reportedFailure = false

        if let next = preloaded, next.url == url, player.items().dropFirst().first === next.item {
            preloaded = nil
            let seconds = try await next.asset.load(.duration).seconds
            guard token == loadToken else { throw CancellationError() }
            player.advanceToNextItem()
            duration = seconds.isFinite ? seconds : 0
            Log.info("local: started the preloaded next file \(url.lastPathComponent)")
            return
        }

        let asset = AVURLAsset(url: url)
        let (playable, length) = try await asset.load(.isPlayable, .duration)
        guard token == loadToken else { throw CancellationError() }
        guard playable else { throw TransportError.notPlayable }
        preloaded = nil
        player.removeAllItems()
        player.insert(AVPlayerItem(asset: asset), after: nil)
        duration = length.seconds.isFinite ? length.seconds : 0
    }

    /// Queues `url` behind the current item so its decode overlaps the current song's playback.
    func preload(_ url: URL) {
        guard player.currentItem != nil, preloaded?.url != url else { return }
        for item in player.items().dropFirst() { player.remove(item) }
        let asset = AVURLAsset(url: url)
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
