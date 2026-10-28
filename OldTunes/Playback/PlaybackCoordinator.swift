import Foundation
import MusicKit

/// The one place that knows what "now playing" means (RESEARCH.md §2, §5.4).
///
/// The queue is a list of track ids, not songs, and the engine is chosen per track when it starts:
/// a file on this Mac plays through AVFoundation, anything else streams through MusicKit. That is
/// why shuffle and repeat work across both kinds of song for free, and why a song whose file
/// went missing since launch still plays from iCloud.
///
/// The per-song checkbox works as it did in iTunes: next(), previous(), the end of a song and
/// shuffle pass over unchecked songs, but a song the user double-clicks plays anyway. The checkbox
/// is read from the rows the coordinator fetches as it goes, so the queue stays a list of ids.
///
/// A double-clicked song that cannot play stops playback on it with the reason in
/// `state.lastError`. Only songs reached by stepping through the list are skipped.
@MainActor
final class PlaybackCoordinator: PlaybackControlling {
    private(set) var state = PlaybackState() {
        didSet { if state != oldValue { notify() } }
    }

    private let library: any LibraryReading
    private let resolver: any CloudSongResolving
    /// MusicKit's permission state, read before each iCloud lookup. Injectable so the harness can
    /// play the unauthorized case without changing the Mac's privacy settings.
    private let cloudAuthorization: @MainActor () -> MusicAuthorization.Status
    /// Held for the coordinator's lifetime; the app owns exactly one.
    private var libraryObserver: NSObjectProtocol?
    /// Internal rather than private so the harness can log both engines at a song boundary.
    let local = LocalTransport()
    let cloud = CloudTransport()
    private let clock = PlaybackClock()
    private var nowPlayingPublisher: NowPlayingPublisher?

    /// The visible, sorted, filtered order the user is playing from.
    private var order: [Track.ID] = []
    /// A permutation of `order`; live instead of it while shuffle is on.
    private var shuffleOrder: [Track.ID] = []
    /// Index into the live list. -1 means the playing song is not in the list (a search hid it);
    /// next() then starts at the top.
    private(set) var cursor = -1
    /// The transport that is playing or paused on a song. Nil while a song is loading.
    private var active: (any Transport)?
    /// The transport the newest load is using. A superseded load stops its transport unless the
    /// newest load claimed the same one, so two quick double-clicks can never leave two streams.
    private var claimed: (any Transport)?
    /// Bumped by every song change. Each async step re-checks it, so the newest request wins.
    private var generation = 0
    /// The song playing, paused, or being started. Set the moment a song is chosen, before its row
    /// has even loaded, so a second next() or a re-sort in the same turn builds on the right song.
    private var currentID: Track.ID?
    /// Whether the song being started plays once it is ready. Play/pause pressed while a cloud
    /// song loads flips it: the press counts, as it did in iTunes, instead of being dropped.
    private var playWhenLoaded = true
    /// Songs the current start has skipped. Reported once, not one by one, so a long run of
    /// unplayable rows (Sync Library off) doesn't strobe every title through the LCD, Now Playing
    /// and the log. Unchecked songs are passed over silently and never counted here.
    private var skips: SkippedSongs?
    /// A scrub made while the song was still loading, applied the moment it starts. The LCD lets
    /// the scrubber move as soon as the song is shown, which is before its audio is ready.
    private var pendingSeek: (id: Track.ID, at: TimeInterval)?
    /// A Play press whose engine start has not run yet (resume() starts it from a Task). Until it
    /// runs, the paused engine still says "not playing", which the clock must not copy into the
    /// state; a Pause pressed meanwhile cancels it by clearing this.
    private var pendingResume: (any Transport)?
    private var loadTask: Task<Void, Never>?
    private var observers: [UUID: @MainActor (PlaybackState) -> Void] = [:]
    /// OldTunes's own volume, the slider's, for files and for iCloud songs alike. Only when
    /// CloudTransport can't set an iCloud song's level itself (no System Audio Recording
    /// permission) does the slider move the Mac's volume during that song, and show it.
    private(set) var appVolume: Float = 0.75
    private var ticks = 0
    /// When to take the media keys back after MusicKit starts playing, in seconds. Measured with
    /// the Now Playing pid at 25 ms resolution: MusicKit's player takes over 0.05–0.08 s after it
    /// starts; reclaiming on the first tick then gives the keys back 0.10–0.16 s after the
    /// takeover (it was 0.62–0.73 s with a single 0.5 s delay). The 0.5 s retry covers a first
    /// reclaim that lands before MusicKit's takeover. Internal so the harness can widen the window.
    var nowPlayingReclaimDelays: [TimeInterval] = [0, 0.5]

    var queue: [Track.ID] { live }
    private var live: [Track.ID] { state.isShuffling ? shuffleOrder : order }

    init(library: any LibraryReading, cloud resolver: any CloudSongResolving,
         cloudAuthorization: @escaping @MainActor () -> MusicAuthorization.Status = { MusicAuthorization.currentStatus }) {
        self.library = library
        self.resolver = resolver
        self.cloudAuthorization = cloudAuthorization
        local.volume = appVolume
        cloud.volume = appVolume
        for transport in [local, cloud] as [any Transport] {
            transport.onFinish = { [weak self, weak transport] in
                guard let self, let transport else { return }
                self.transportFinished(transport)
            }
            transport.onError = { [weak self, weak transport] error in
                guard let self, let transport else { return }
                self.transportFailed(transport, error)
            }
        }
        cloud.onMusicKitStartedPlaying = { [weak self] in self?.reclaimNowPlaying() }
        clock.onTick = { [weak self] in self?.tick() }
        nowPlayingPublisher = NowPlayingPublisher(actions: .init(
            play: { [weak self] in if self?.state.isPlaying == false { self?.playPause() } },
            pause: { [weak self] in if self?.state.isPlaying == true { self?.playPause() } },
            toggle: { [weak self] in self?.playPause() },
            next: { [weak self] in self?.next() },
            previous: { [weak self] in self?.previous() },
            seek: { [weak self] in self?.seek(to: $0) }))
        // Tag edits, checkbox changes and re-ingests. The coordinator listens itself, so nothing
        // else needs to tell it.
        libraryObserver = NotificationCenter.default.addObserver(forName: .libraryDidChange, object: nil,
                                                                 queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNowPlaying()
                // A checkbox change can move which file comes next.
                self?.refreshPreload()
            }
        }
    }

    // MARK: Observers

    func addObserver(_ handler: @escaping @MainActor (PlaybackState) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    private func notify() {
        for handler in observers.values { handler(state) }
        nowPlayingPublisher?.update(state)
    }

    // MARK: Queue

    func play(queue: [Track.ID], startAt: Track.ID?) {
        order = queue
        guard !queue.isEmpty else {
            // The shuffle order is the live list while shuffling; leaving it would let next()
            // resume the old list.
            shuffleOrder = []
            stop()
            cursor = -1
            return
        }
        let start = startAt.flatMap { queue.firstIndex(of: $0) }
        if state.isShuffling {
            shuffleOrder = Shuffle.permutation(of: queue, first: start.map { queue[$0] })
            cursor = 0
        } else {
            cursor = start ?? 0
        }
        state.lastError = nil
        // A named song is the user's pick: it plays even if unchecked, and if it can't play,
        // playback stops on it. With none named, the first checked, playable song starts.
        begin(at: cursor, direction: 1, userInitiated: true, picked: start != nil)
    }

    func replaceQueue(_ ids: [Track.ID]) {
        let current = currentID
        order = ids
        if state.isShuffling {
            // Search calls this on every keystroke. Keep the shuffle's existing order for the songs
            // still listed, so what was coming up (and what previous() goes back to) stays put;
            // newly listed songs are shuffled in after them.
            let listed = Set(ids)
            let survivors = shuffleOrder.filter { listed.contains($0) }
            let known = Set(survivors)
            shuffleOrder = survivors + Shuffle.permutation(of: ids.filter { !known.contains($0) }, first: nil)
        }
        cursor = current.flatMap { live.firstIndex(of: $0) } ?? -1
        refreshPreload()
    }

    func setShuffle(_ on: Bool) {
        guard on != state.isShuffling else { return }
        let kept = currentID.flatMap { order.contains($0) ? $0 : nil }
        if on {
            shuffleOrder = Shuffle.permutation(of: order, first: kept)
            cursor = kept == nil ? -1 : 0
        } else {
            cursor = kept.flatMap { order.firstIndex(of: $0) } ?? -1
            shuffleOrder = []
        }
        state.isShuffling = on
        refreshPreload()
    }

    func setRepeat(_ mode: RepeatMode) {
        state.repeatMode = mode
        refreshPreload()
    }

    // MARK: Transport controls

    func playPause() {
        if let active {
            if state.isPlaying {
                pendingResume = nil
                active.pause()
                state.isPlaying = false
            } else {
                resume(active)
            }
        } else if currentID != nil {
            // Pause (not Play: a run paused during its first load is resumed by Play) while
            // searching past songs that can't play, which can take a while when each one waits on
            // iCloud: end the run, so nothing starts later behind the user's back. Once the run has
            // found a song and shows it loading, Pause holds that song like any other load.
            if let report = skips, playWhenLoaded, state.nowPlaying?.id != currentID {
                let at = cursor
                stop()
                state.lastError = report.message
                cursor = at
                Log.info("playback: pause ended a run of skipped songs")
                return
            }
            // Still loading the song: the press counts once it is ready.
            playWhenLoaded.toggle()
            state.isPlaying = playWhenLoaded
        } else if !live.isEmpty {
            state.lastError = nil
            begin(at: max(cursor, 0), direction: 1, userInitiated: true)
        }
    }

    func next() {
        guard !live.isEmpty else { return }
        state.lastError = nil
        if let index = step(from: cursor, by: 1) {
            begin(at: index, direction: 1, userInitiated: true)
        } else {
            endOfQueue()
        }
    }

    func previous() {
        if active != nil, state.position > 3 {
            seek(to: 0)
            return
        }
        previousSong()
    }

    func previousSong() {
        guard !live.isEmpty else { return }
        state.lastError = nil
        if let index = step(from: cursor, by: -1) {
            // If nothing before it can play (all unchecked, say), restart this song instead, as
            // going back from the first song does.
            begin(at: index, direction: -1, userInitiated: true, restartIfNone: currentID)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: TimeInterval) {
        let upper = state.duration > 0 ? state.duration : max(seconds, 0)
        let t = min(max(seconds, 0), upper)
        guard let active else {
            // Still loading. Keep the spot for when the song starts, and show it now so the
            // scrubber stays where it was dropped. Only for the song on display.
            guard let id = currentID, state.nowPlaying?.id == id else { return }
            pendingSeek = (id, t)
            state.position = t
            return
        }
        active.seek(to: t)
        state.position = t
        // MusicKit re-announces itself to Now Playing after a seek, often too fast for the clock
        // to see its status blink.
        if active === cloud { reclaimNowPlaying() }
    }

    func stop() {
        generation += 1
        loadTask?.cancel()
        claimed = nil
        currentID = nil
        playWhenLoaded = true
        skips = nil
        pendingSeek = nil
        pendingResume = nil
        local.stop()
        cloud.stop()
        active = nil
        clock.stop()
        // One change, so observers never see a half-stopped state.
        var s = state
        s.isPlaying = false
        s.isLoading = false
        s.position = 0
        s.duration = 0
        s.nowPlaying = nil
        s.isVolumeEnabled = true
        state = s
    }

    func setVolume(_ volume: Float) {
        let v = min(max(volume, 0), 1)
        appVolume = v
        local.volume = v
        cloud.volume = v
        state.volume = v
    }

    /// Takes effect at once, on the song playing too.
    func setSoundCheck(_ on: Bool) {
        guard on != local.isSoundCheckOn else { return }
        local.isSoundCheckOn = on
        cloud.isSoundCheckOn = on
        Log.info("playback: Sound Check \(on ? "on" : "off")")
    }

    // MARK: Song changes

    /// Starts the song at `index` of the live list. Unchecked and unplayable songs are passed over
    /// in `direction`, except a `picked` one (the song the user named), which plays even if
    /// unchecked and stops playback on itself if it can't play. `restartIfNone` is the song to
    /// start over when the walk finds nothing to play (previous() on the first playable song).
    private func begin(at index: Int, direction: Int, userInitiated: Bool, picked: Bool = false,
                       restartIfNone: Track.ID? = nil) {
        generation += 1
        let gen = generation
        loadTask?.cancel()
        // A user's click silences the old song now, not after the new one has resolved. After a
        // natural end there is nothing to silence, and pausing would undo a preloaded local item.
        if userInitiated { active?.pause() }
        active = nil
        claimed = nil
        cursor = index
        currentID = live.indices.contains(index) ? live[index] : nil
        playWhenLoaded = true
        skips = nil
        pendingSeek = nil
        pendingResume = nil
        // isPlaying is what the play button shows, so it says "playing" from the click on, as
        // iTunes did; isLoading says the audio isn't there yet. From a stop it waits for the row,
        // so observers never see "playing" with no song.
        if state.nowPlaying != nil { state.isPlaying = true }
        loadTask = Task { [weak self] in
            await self?.run(from: index, direction: direction, generation: gen, picked: picked,
                            restartIfNone: restartIfNone)
        }
    }

    private func run(from first: Int, direction: Int, generation gen: Int, picked: Bool,
                     restartIfNone: Track.ID?) async {
        var index = first
        // At most one attempt per song, so a list of nothing but unplayable or unchecked songs
        // (or one that wraps under repeat-all) cannot loop forever.
        var attempts = 0
        var unchecked = 0
        var rows: [Track.ID: Track] = [:]
        var asked: Set<Track.ID> = []
        while attempts < max(live.count, 1) {
            guard gen == generation else { return }
            // A re-sort or search since the song was chosen may have moved it; follow it by id.
            if attempts == 0, let id = currentID, let moved = live.firstIndex(of: id) { index = moved }
            guard live.indices.contains(index) else { break }
            let id = live[index]
            cursor = index
            currentID = id
            attempts += 1
            let isPick = picked && attempts == 1

            if !asked.contains(id) {
                // The chosen song alone; once skipping, the stretch ahead in one read, so a long
                // run of unplayable rows costs one library call per 256 songs, not one per song.
                let ids = attempts == 1 ? [id] : stretch(from: index, direction: direction, count: 256)
                asked.formUnion(ids)
                for track in (try? await library.tracks(ids: ids)) ?? [] { rows[track.id] = track }
                guard gen == generation else { return }
            }
            if let track = rows[id], !track.isChecked, !isPick {
                // Passed over without a word, as iTunes did.
                unchecked += 1
            } else {
                let failure: String
                if let track = rows[id] {
                    // Shown at once unless songs have already failed on the way to it; see start().
                    switch await start(track, announce: skips == nil, generation: gen) {
                    case .playing, .superseded: return
                    case .failed(let reason):
                        failure = "\u{201C}\(track.displayTitle)\u{201D} could not be played: \(reason)"
                    }
                } else {
                    failure = "A song in this list is no longer in your library."
                }
                if isPick {
                    // iTunes stopped and said why; playing the next song instead looked like the
                    // app had picked a different song.
                    stop(on: index, saying: failure)
                    return
                }
                skipped(failure)
            }
            // Re-find the song only if the list changed under the await; a scan per skipped row
            // made a 15,900-row run quadratic (6 s of the 7).
            let at = live.indices.contains(index) && live[index] == id ? index : (live.firstIndex(of: id) ?? index)
            guard let nextIndex = step(from: at, by: direction) else { break }
            index = nextIndex
        }
        guard gen == generation else { return }
        if let id = restartIfNone, let at = live.firstIndex(of: id) {
            begin(at: at, direction: 1, userInitiated: true, picked: true)
            return
        }
        giveUp(nothingChecked: unchecked > 0 && unchecked >= live.count)
    }

    /// Up to `count` ids of the live list starting at `index`, walking in `direction`.
    private func stretch(from index: Int, direction: Int, count: Int) -> [Track.ID] {
        let end = direction > 0 ? min(live.count, index + count) : max(-1, index - count)
        return stride(from: index, to: end, by: direction > 0 ? 1 : -1).map { live[$0] }
    }

    private func skipped(_ message: String) {
        if skips == nil {
            skips = SkippedSongs(first: message)
            Log.error("playback: \(message)")
        } else {
            skips?.count += 1
        }
    }

    /// Nothing left to try: stop, and say why. Running out of checked songs at the end of the list
    /// is just the end of the list; a list with none checked at all gets a reason.
    private func giveUp(nothingChecked: Bool) {
        let report = skips
        endOfQueue()
        if let report {
            state.lastError = report.message
            if report.count > 1 { Log.error("playback: gave up after skipping \(report.count) unplayable songs") }
        } else if nothingChecked {
            state.lastError = "None of the songs in this list are checked. Check a song's box to include it, "
                + "or double-click it to play it anyway."
            Log.info("playback: \(state.lastError ?? "")")
        }
    }

    /// The song the user picked can't play: stop on it and say why. The cursor stays on it, so
    /// next() goes on to the song after it.
    private func stop(on index: Int, saying message: String) {
        Log.error("playback: \(message)")
        stop()
        state.lastError = message
        cursor = index
    }

    private enum Outcome { case playing, superseded, failed(String) }

    /// The §1 fallback chain, evaluated now: the file if it is still there, then iCloud.
    ///
    /// The song the user chose is shown at once. A song reached by skipping is shown only once
    /// there is something to try (a file, or a MusicKit song), so a run of unplayable rows passes
    /// without a notification per row.
    private func start(_ track: Track, announce: Bool, generation gen: Int) async -> Outcome {
        var shown = false
        func show() {
            guard !shown else { return }
            shown = true
            var s = state
            s.nowPlaying = track
            s.duration = track.duration
            s.position = 0
            s.isPlaying = playWhenLoaded
            // A reason left from an earlier song is stale once a new song is on display.
            s.lastError = skips?.message
            state = s
        }
        if announce { show() }
        var reason = "it is not on this Mac and is not in your iCloud Music Library."
        if let url = track.fileURL, FileManager.default.fileExists(atPath: url.path) {
            show()
            // Before the load: a preloaded file starts sounding the moment load() advances to it.
            local.soundCheckGain = SoundCheck.gain(energy: track.soundCheckEnergy)
            switch await start(.local(url), on: local, generation: gen) {
            case .failed(let why): reason = why
            case let outcome: return outcome
            }
        }
        // Without permission every MusicKit lookup fails, some only after a long hang (RESEARCH.md
        // §3.6), so don't ask: say why at once. Folder tracks never come from iCloud.
        if track.origin == .musicLibrary, let refusal = Self.refusal(cloudAuthorization()) {
            return .failed(refusal)
        }
        // Stays true across a run of skipped songs; the start that succeeds, or stop(), clears it.
        state.isLoading = true
        let song: Song?
        do {
            song = try await withTimeout(10) { [resolver] in await resolver.cloudSong(for: track) }
        } catch {
            song = nil
            reason = "iCloud did not answer in time."
            Log.error("playback: iCloud lookup for \(track.id) failed: \(error)")
        }
        guard gen == generation else { return .superseded }
        guard let song else { return .failed(reason) }
        show()
        cloud.soundCheckGain = SoundCheck.gain(energy: track.soundCheckEnergy)
        return await start(.cloud(song), on: cloud, generation: gen)
    }

    private func start(_ playable: Playable, on transport: any Transport, generation gen: Int) async -> Outcome {
        let other: any Transport = transport === local ? cloud : local
        // Stop the other engine BEFORE loading this one: two loaded transports are two streams.
        other.stop()
        claimed = transport
        if transport === cloud { state.isLoading = true }
        do {
            try await transport.load(playable)
            guard gen == generation else { return abandon(transport) }
            if transport === local { local.volume = appVolume }
            if playWhenLoaded {
                try await transport.play()
                guard gen == generation else { return abandon(transport) }
            }
        } catch {
            guard gen == generation else { return abandon(transport) }
            transport.stop()
            Log.error("playback: \(transport === cloud ? "MusicKit" : "AVFoundation") could not start it: \(error)")
            return .failed(Self.plainReason(error, fromCloud: transport === cloud))
        }
        active = transport
        // Pause pressed while the engine was starting; also stops a preloaded file, which
        // starts by itself when it is advanced to.
        if !playWhenLoaded { transport.pause() }
        // A scrub made while it loaded. Applied after play(), the path a seek on a playing song
        // already takes on both engines.
        var landed: TimeInterval?
        if let scrub = pendingSeek {
            pendingSeek = nil
            if scrub.id == currentID {
                transport.seek(to: scrub.at)
                landed = scrub.at
            }
        }
        if let skips, skips.count > 1 { Log.info("playback: skipped \(skips.count) unplayable songs") }
        var s = state
        s.isLoading = false
        s.isPlaying = playWhenLoaded
        if transport.duration > 0 { s.duration = transport.duration }
        // MusicKit's playbackTime trails a seek by a tick.
        s.position = landed ?? transport.position
        s.volume = appVolume
        s.isVolumeEnabled = volumeApplies(to: transport)
        // Clears a reason left from an earlier song: only this start's skips are news.
        s.lastError = skips?.message
        state = s
        skips = nil
        clock.start()
        refreshPreload()
        // MusicKit re-announces itself to Now Playing after a seek; see seek(to:).
        if landed != nil, transport === cloud { reclaimNowPlaying() }
        return .playing
    }

    /// Says why a song could not start in words, not as an error domain and code
    /// ("MPMusicPlayerControllerErrorDomain error 6" is what MusicKit gives for some uploaded songs).
    static func plainReason(_ error: any Error, fromCloud: Bool) -> String {
        if error is TimeoutError {
            return fromCloud ? "iCloud took too long to start it." : "its file took too long to open."
        }
        if (error as NSError).domain == NSURLErrorDomain { return "iCloud can't be reached right now." }
        return fromCloud ? "iCloud couldn\u{2019}t prepare it for playback." : "its file could not be opened."
    }

    /// Why no song can stream from iCloud right now, or nil if MusicKit is authorized.
    static func refusal(_ status: MusicAuthorization.Status) -> String? {
        switch status {
        case .authorized:
            return nil
        case .restricted:
            return "it streams from iCloud, and access to Apple Music is restricted on this Mac."
        default:
            return "it streams from iCloud, which needs the Media & Apple Music permission. Turn on OldTunes in "
                + "System Settings \u{25B8} Privacy & Security \u{25B8} Media & Apple Music, then quit and reopen OldTunes."
        }
    }

    private func abandon(_ transport: any Transport) -> Outcome {
        if claimed !== transport { transport.stop() }
        return .superseded
    }

    private func resume(_ transport: any Transport) {
        let gen = generation
        pendingResume = transport
        state.isPlaying = true
        Task { [weak self] in
            // A pause pressed before this task ran wins (it clears pendingResume). Starting anyway
            // would play over it while the button says paused: three quick presses used to end up
            // playing. state.isPlaying can't be the test: a clock tick that ran first set it from
            // the still-paused engine, and Play after Pause then did nothing.
            guard let self, gen == self.generation, self.active === transport,
                  self.pendingResume === transport else { return }
            self.pendingResume = nil
            do {
                try await transport.play()
            } catch {
                guard gen == self.generation else { return }
                self.state.isPlaying = false
                self.state.lastError = error.localizedDescription
            }
        }
    }

    /// The next index under the repeat rules, or nil at an end of the list.
    private func step(from index: Int, by delta: Int) -> Int? {
        let count = live.count
        guard count > 0 else { return nil }
        let target = index + delta
        if (0..<count).contains(target) { return target }
        guard state.repeatMode == .all else { return nil }
        return target < 0 ? count - 1 : 0
    }

    private func endOfQueue() {
        let reason = state.lastError
        stop()
        state.lastError = reason
        cursor = live.isEmpty ? -1 : 0
    }

    private func transportFinished(_ transport: any Transport) {
        guard transport === active else { return }
        Log.info("playback: finished \u{201C}\(state.nowPlaying?.displayTitle ?? "?")\u{201D}")
        if state.repeatMode == .one {
            replay(transport)
        } else if let index = step(from: cursor, by: 1) {
            begin(at: index, direction: 1, userInitiated: false)
        } else {
            endOfQueue()
        }
    }

    /// Repeat One: rewind the same engine instead of reloading, so there is no gap.
    private func replay(_ transport: any Transport) {
        transport.seek(to: 0)
        state.position = 0
        let gen = generation
        Task { [weak self] in
            do {
                try await transport.play()
            } catch {
                guard let self, gen == self.generation else { return }
                self.begin(at: max(self.cursor, 0), direction: 1, userInitiated: false)
            }
        }
    }

    private func transportFailed(_ transport: any Transport, _ error: Error) {
        guard transport === active else { return }
        state.lastError = "\u{201C}\(state.nowPlaying?.displayTitle ?? "This song")\u{201D} stopped: "
            + Self.plainReason(error, fromCloud: transport === cloud)
        Log.error("playback: \(state.lastError ?? "") (\(error))")
        if let index = step(from: cursor, by: 1) {
            begin(at: index, direction: 1, userInitiated: false)
        } else {
            endOfQueue()
        }
    }

    /// When the next song is also a file, queue it behind this one so its decode overlaps. The
    /// next song is the next checked one, since the end of this song passes over the rest.
    private func refreshPreload() {
        guard active === local, state.repeatMode != .one, let index = step(from: cursor, by: 1) else { return }
        let ids = stretch(from: index, direction: 1, count: 32)
        let gen = generation
        Task { [weak self] in
            guard let self, let rows = try? await self.library.tracks(ids: ids),
                  gen == self.generation, self.active === self.local,
                  let track = rows.first(where: \.isChecked),
                  let url = track.fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
            self.local.preload(url)
        }
    }

    /// A Get Info save or a re-ingest may have changed the playing song's row. Swap the fresh row
    /// in so the LCD and Now Playing show it; the audio, position and duration are left alone.
    private func refreshNowPlaying() {
        guard let id = state.nowPlaying?.id else { return }
        let gen = generation
        Task { [weak self] in
            guard let self, let fresh = try? await self.library.tracks(ids: [id]).first,
                  gen == self.generation, self.state.nowPlaying?.id == id, self.state.nowPlaying != fresh else { return }
            self.state.nowPlaying = fresh
        }
    }

    /// macOS sends the media keys to whichever Now Playing player most recently started playing,
    /// and MusicKit's player service starts a moment after OldTunes publishes. A key that reaches
    /// MusicKit's player does the wrong thing (Next pauses at 0:00, Previous restarts the song;
    /// measured in the verify run), so OldTunes takes the keys back as soon as it has.
    private func reclaimNowPlaying() {
        let gen = generation
        let delays = nowPlayingReclaimDelays
        Task { [weak self] in
            var slept = 0.0
            for delay in delays {
                try? await Task.sleep(for: .seconds(max(0, delay - slept)))
                slept = delay
                guard let self, gen == self.generation, self.active === self.cloud, self.state.isPlaying else { return }
                await self.nowPlayingPublisher?.reclaim()
            }
        }
    }

    /// The slider greys out during an iCloud song OldTunes can't set the level of (no System Audio
    /// Recording permission): moving it would change nothing anyone hears.
    private func volumeApplies(to transport: any Transport) -> Bool {
        transport !== cloud || cloud.ownsVolume
    }

    // MARK: Clock

    private func tick() {
        guard let transport = active else { return }
        transport.clockDidTick()
        // A finish or failure inside the tick may already have moved on to another song.
        guard transport === active else { return }
        ticks += 1
        var next = state
        next.position = min(transport.position, state.duration > 0 ? state.duration : .infinity)
        next.isPlaying = transport.isPlaying || pendingResume === transport
        // An iCloud song's route can give up mid-song (its tap heard silence, and so did the probe).
        next.isVolumeEnabled = volumeApplies(to: transport)
        if next != state {
            state = next
        } else if next.isPlaying {
            notify()
        }
    }
}

/// What a start skipped on its way to a playable song, as one user-facing line.
private struct SkippedSongs {
    /// The first skip's message: usually the song the user asked for.
    var first: String
    var count = 1

    var message: String {
        guard count > 1 else { return first }
        let more = count - 1
        return "\(first)\(first.hasSuffix(".") ? "" : ".") \(more.formatted()) more \(more == 1 ? "song" : "songs") could not be played either."
    }
}
