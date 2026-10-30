import Foundation

/// The songs Music has been asked to download and hasn't brought down yet (RESEARCH.md §6.9),
/// and when to stop waiting for them. Music never says when a download is done, or that one
/// failed: a song has arrived once the library shows it as a file on this Mac, which the
/// re-ingest after Music's change notification reads like any other change.
///
/// Rules only, so the playlists bench can run a quarter of an hour of them on a made-up clock.
/// AppController reads the rows, runs the re-ingests, asks Music and draws the blue clouds. A
/// song is watched from the moment Download is chosen: queued until OldTunes asks Music for it,
/// then on its way until its file is here, it leaves the library, or the watch gives up on it.
@MainActor
final class DownloadWatch {
    /// Nothing came down, and nothing was asked for, this long: Music has most likely stopped.
    /// The watch then has the library read once more before it gives up (`tick`).
    static let quietLimit: TimeInterval = 15 * 60
    /// The longest the library goes unread while songs are on their way and Music isn't posting
    /// its change notification, in case it doesn't post one when a file lands (not measured yet,
    /// RESEARCH.md §10-R7). While Music keeps posting, the re-read this asks for gives way to the
    /// one Music's notifications have scheduled (`LibraryIngest.refreshIfIdle`), so re-reads
    /// follow the change back-off, up to 5 minutes apart (`LibraryIngest.changeWait`).
    static let refreshInterval: TimeInterval = 3 * 60
    /// How long a re-ingest is given to finish before the watch trusts the rows read after it.
    /// One takes 5 to 18 s on this Mac.
    static let refreshAllowance: TimeInterval = 30
    /// How often AppController settles and ticks while anything is watched.
    static let tickInterval: Duration = .seconds(30)
    /// Ticks come 30 s apart while the Mac is awake, a little more when one re-reads the library.
    /// A longer gap since the last one means the Mac slept, when Music can't bring anything down,
    /// or OldTunes was stalled; either way that time isn't counted as quiet (`tick`).
    static let sleepGap: TimeInterval = 2 * 60

    /// Every song showing as downloading, and when Download was chosen for it.
    private(set) var pending: [Track.ID: Date] = [:] {
        // Nothing left to watch: the next Download's first tick has no gap to measure.
        didSet { if pending.isEmpty { lastTick = nil } }
    }
    /// The pending songs OldTunes hasn't asked Music for yet.
    private(set) var queued = Set<Track.ID>()
    /// The song OldTunes is asking Music about right now, until Music answers.
    private(set) var inFlight: Track.ID?
    /// The last time a song came down, a song was added, Music took a request, or the Mac woke.
    /// Fifteen minutes after it, with nothing queued, the watch starts to give up.
    private(set) var lastProgress: Date?

    /// When the quiet limit passed and the watch asked for a re-ingest to check by.
    private var checkAskedAt: Date?
    /// When the first re-ingest that read the library after that ask started.
    private var checkRefresh: Date?
    /// When the last tick came, while anything was watched.
    private var lastTick: Date?
    /// Since nothing was last pending: songs that came down (or left the library), songs the
    /// watch gave up on, in the order they were asked for, and whether Music quitting was why.
    private var arrived = 0
    private var unfinished: [Track.ID] = []
    private var musicQuit = false

    var ids: Set<Track.ID> { Set(pending.keys) }
    var isEmpty: Bool { pending.isEmpty }
    /// Songs are still waiting to be asked for: File ▸ Download reads Stop Downloading.
    var isAsking: Bool { !queued.isEmpty }

    /// Starts watching songs Download was just chosen for, queued. Returns the ones it wasn't
    /// watching already: only those are asked for, since Music already has the others.
    @discardableResult
    func add(_ ids: some Sequence<Track.ID>, now: Date) -> Set<Track.ID> {
        var added = Set<Track.ID>()
        for id in ids where pending[id] == nil {
            pending[id] = now
            queued.insert(id)
            added.insert(id)
        }
        // New work for Music: it gets a fresh quarter of an hour.
        if !added.isEmpty { noteProgress(now) }
        return added
    }

    /// The next song to ask Music for. False when Stop Downloading, Music quitting or its
    /// arrival took it off the queue since; then it isn't asked for.
    func take(_ id: Track.ID) -> Bool {
        guard queued.remove(id) != nil else { return false }
        inFlight = id
        return true
    }

    /// Music's answer about the song just taken. `rest`: the songs after it in its batch.
    /// Returns the songs no longer watched and whether to ask about the next one (`reduce`).
    func answer(_ outcome: MusicDownloadOutcome, for id: Track.ID, rest: [Track.ID],
                now: Date) -> (dropped: [Track.ID], goOn: Bool) {
        if inFlight == id { inFlight = nil }
        let step = Self.reduce(outcome, for: id, rest: rest.filter(queued.contains))
        remove(step.dropped)
        // A long batch takes many minutes to send; nothing gives up on it while it goes out.
        if outcome == .requested { noteProgress(now) }
        return step
    }

    /// What one answer from Music means for its batch. `.requested` keeps the song; `.refused`
    /// drops it and goes on. `.unanswered` keeps it, since Music still carries out a request it
    /// didn't answer in time, but drops the rest; `.stopped` drops it and the rest, since
    /// nothing reached Music for them. Pure, so the bench checks it by itself.
    static func reduce(_ outcome: MusicDownloadOutcome, for id: Track.ID,
                       rest: [Track.ID]) -> (dropped: [Track.ID], goOn: Bool) {
        switch outcome {
        case .requested: ([], true)
        case .refused: ([id], true)
        case .unanswered: (rest, false)
        case .stopped: ([id] + rest, false)
        }
    }

    /// Music turning down a batch's songs one after another, the same way, before it has taken
    /// any of them. Three in a row with the same error code stop the batch, as they stop an add
    /// (MusicPlaylistEditor): the rest would only be turned down one by one, at about four Apple
    /// Events a song. The code is what's compared, since Music's words may name the song, and a
    /// song that couldn't be looked up (no code) neither counts nor breaks the run, as in an add.
    /// Once Music has taken a song it can download these, and a refusal is about its own song
    /// only. Pure, so the bench runs it by itself.
    struct RefusalStreak: Sendable, Equatable {
        /// Followed by Music's reason for the third refusal.
        static let threeInARowReason = "Music turned down three songs in a row, "
            + "so OldTunes stopped asking it to download songs."

        /// The error code the refusals in a row share, how many there are, and Music's reason for
        /// the last of them, which the stop quotes.
        private(set) var code: Int?
        private(set) var count = 0
        private(set) var reason: String?
        /// Music has taken one of the batch's songs.
        private(set) var tookOne = false

        /// Music's answer about the batch's next song. Returns the user-facing reason when the
        /// batch stops here.
        mutating func note(_ outcome: MusicDownloadOutcome) -> String? {
            switch outcome {
            case .requested:
                (code, count, reason, tookOne) = (nil, 0, nil, true)
            case .refused(let why, let number?):
                count = number == code ? count + 1 : 1
                code = number
                reason = why
            case .refused(_, nil), .unanswered, .stopped:
                break
            }
            guard !tookOne, count >= 3, let reason else { return nil }
            return "\(Self.threeInARowReason) \(reason)"
        }
    }

    /// Stops watching songs Music won't be asked for after all.
    func remove(_ ids: some Sequence<Track.ID>) {
        for id in ids {
            pending[id] = nil
            queued.remove(id)
            if inFlight == id { inFlight = nil }
        }
    }

    /// File ▸ Stop Downloading: the queued songs aren't asked for. Songs Music was already
    /// asked for keep coming, and stay watched. Returns the ones dropped.
    func stopAsking() -> Set<Track.ID> {
        let dropped = queued
        remove(dropped)
        return dropped
    }

    /// Fresh rows for `requested`, the watched songs whose rows were just read; an id with no
    /// row has left the library (or came back as a new song). Returns the songs that are done:
    /// a file on this Mac now, or gone. A dimmed row, whose file isn't there yet, keeps waiting.
    func settle(rows: [Track], requested: Set<Track.ID>, now: Date) -> Set<Track.ID> {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var done = Set<Track.ID>()
        for id in requested where pending[id] != nil {
            guard let row = byID[id] else {
                done.insert(id)
                continue
            }
            if row.fileURL != nil { done.insert(id) }
        }
        guard !done.isEmpty else { return done }
        for id in done {
            pending[id] = nil
            queued.remove(id)
        }
        arrived += done.count
        noteProgress(now)
        return done
    }

    /// Every 30 s while anything is watched. `lastRefresh`: when the newest re-ingest that read
    /// the library started (`LibraryIngest.lastWrittenRefreshStarted`). One that failed (no
    /// permission, or iTunesLibrary or the index write failing) read nothing in, so it counts for
    /// nothing here.
    ///
    /// Asks for a re-ingest when the library hasn't been read for 3 minutes. When nothing has
    /// happened for 15, and nothing is left to ask for, it asks for one more, and the first tick
    /// at least 30 s after one that read the library started gives up on everything still
    /// watched: a song whose arrival Music never announced is found first, and never called not
    /// downloaded. Until such a re-ingest starts, every tick asks again. Only time awake counts:
    /// after a gap longer than `sleepGap` since the last tick, the 15 minutes start again, and a
    /// check asked for before the gap is called off.
    func tick(now: Date, lastRefresh: Date?) -> (refreshDue: Bool, expired: Set<Track.ID>) {
        guard !pending.isEmpty else { return (false, []) }
        // The Mac slept: Music couldn't download meanwhile. This covers a tick in a dark wake too.
        if let lastTick, now.timeIntervalSince(lastTick) > Self.sleepGap { noteProgress(now) }
        lastTick = now
        let stale = lastRefresh.map { now.timeIntervalSince($0) >= Self.refreshInterval } ?? true
        // Still asking: what Music hasn't brought down may just be behind the rest.
        guard queued.isEmpty, inFlight == nil else { return (stale, []) }
        if let asked = checkAskedAt {
            // No re-ingest has read the library since the ask (another was running, or it
            // failed): ask again.
            guard let started = lastRefresh, started > asked else { return (true, []) }
            let first = checkRefresh ?? started
            checkRefresh = first
            // A newer one starting means the first has finished.
            guard started > first || now.timeIntervalSince(first) >= Self.refreshAllowance else { return (false, []) }
            return (false, expireAll(musicQuit: false))
        }
        guard let lastProgress, now.timeIntervalSince(lastProgress) >= Self.quietLimit else { return (stale, []) }
        checkAskedAt = now
        return (true, [])
    }

    /// Gives up on every watched song, queued ones included: the quiet limit passed, or Music
    /// quit (`musicQuit`), which leaves nothing to come down. Returns them.
    @discardableResult
    func expireAll(musicQuit: Bool) -> Set<Track.ID> {
        guard !pending.isEmpty else { return [] }
        let expired = pending.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.map(\.key)
        unfinished += expired
        if musicQuit { self.musicQuit = true }
        pending.removeAll()
        queued.removeAll()
        inFlight = nil
        checkAskedAt = nil
        checkRefresh = nil
        return Set(expired)
    }

    /// Once nothing is watched: the songs given up on since nothing last was, how many songs
    /// that is about in all, and whether Music quitting was why; nil when every one came down,
    /// since then there is nothing to say. Either way the count starts over.
    func end() -> (unfinished: [Track.ID], watched: Int, musicQuit: Bool)? {
        guard pending.isEmpty else { return nil }
        let ending = (unfinished: unfinished, watched: arrived + unfinished.count, musicQuit: musicQuit)
        arrived = 0
        unfinished = []
        musicQuit = false
        return ending.unfinished.isEmpty ? nil : ending
    }

    private func noteProgress(_ now: Date) {
        lastProgress = now
        checkAskedAt = nil
        checkRefresh = nil
    }
}
