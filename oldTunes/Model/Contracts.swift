import Foundation
import MusicKit

// The seams between modules. Each module codes against these protocols, never against another
// module's concrete types, so modules build and test independently. App/AppAssembly.swift is the
// only file that names concrete implementations.
//
// Ownership:
//   Library/   implements LibraryReading, LibraryWriting, LibraryIngesting, CloudSongResolving
//   Playback/  implements PlaybackControlling
//   Metadata/  implements TagEditing, MusicLibraryAdding, PlaylistEditing and SongDownloading
//              (all script Music.app), and owns the Get Info window
//   UI/        consumes all of the above; implements nothing here

// MARK: - Querying the library

/// What the left-hand source list has selected.
enum LibraryScope: Sendable, Hashable {
    /// Every song.
    case library
    /// Songs with a file on this Mac (Music-library local files plus added folders).
    case onThisMac
    /// A Music.app playlist, by its persistent id bit pattern.
    case playlist(Int64)
}

/// Everything that decides which ids the track list shows, in which order.
struct TrackQuery: Sendable, Hashable {
    var scope: LibraryScope = .library
    /// Raw text from the search field. Empty means no filter.
    var search: String = ""
    var sort: TrackSort = .default
    /// Column-browser filters. Nil means "All".
    var genre: String? = nil
    var artist: String? = nil
    var album: String? = nil
}

/// The three column-browser panes.
enum BrowserField: String, Sendable, CaseIterable { case genre, artist, album }

/// The bottom bar's "15,900 songs, 46.2 days, 102.4 GB".
struct LibrarySummary: Sendable, Hashable {
    var count: Int
    var totalSeconds: Double
    /// Bytes on disk plus the library's recorded size for cloud tracks.
    var totalBytes: Int64

    static let empty = LibrarySummary(count: 0, totalSeconds: 0, totalBytes: 0)
}

struct PlaylistInfo: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable { case regular, smart, folder, genius }
    /// Persistent id bit pattern.
    var id: Int64
    var name: String
    var kind: Kind
    var parentID: Int64?
    var trackCount: Int
}

/// Read side of the index. Every call is fast enough to make per keystroke (see RESEARCH.md §4.4).
protocol LibraryReading: Sendable {
    /// The full ordered id list for a query. Descending sorts are reversed, never re-queried.
    func ids(for query: TrackQuery) async throws -> [Track.ID]
    /// Rows for the given ids, returned in the same order as `ids`. Unknown ids are skipped.
    func tracks(ids: [Track.ID]) async throws -> [Track]
    func summary(for ids: [Track.ID]) async throws -> LibrarySummary
    func playlists() async throws -> [PlaylistInfo]
    /// Distinct values for one browser pane, honoring the query's scope, search, and the
    /// browser filters to the LEFT of `field` (genre filters artist; genre+artist filter album).
    func browserValues(_ field: BrowserField, for query: TrackQuery) async throws -> [String]
    /// Number of rows in the index. 0 means "never ingested".
    func count() async throws -> Int
}

/// Write side, used after a tag edit succeeds so the list updates without a full re-ingest.
protocol LibraryWriting: Sendable {
    /// Also posts `.libraryDidChange` on the main thread; callers must not post it again.
    func update(ids: [Track.ID], applying patch: TagPatch) async throws
    /// The per-song checkbox. Kept in the index and survives re-ingest. Posts `.libraryDidChange`.
    func setChecked(ids: [Track.ID], checked: Bool) async throws
    /// A playlist change Music has already made, shown at once instead of after Music's change
    /// notification and the re-ingest (about 7 s). That re-ingest then rewrites every playlist
    /// from Music's own database. Posts `.libraryDidChange`, saying which playlist for
    /// `.songsAdded` (`LibraryChange.songsAddedTo`).
    func apply(_ edit: PlaylistEdit) async throws
}

extension LibraryWriting {
    /// Test doubles that never toggle checkboxes don't need to implement this.
    func setChecked(ids: [Track.ID], checked: Bool) async throws {
        throw CocoaError(.featureUnsupported)
    }

    /// Nor do ones that never edit playlists.
    func apply(_ edit: PlaylistEdit) async throws {
        throw CocoaError(.featureUnsupported)
    }
}

/// One playlist change, for `LibraryWriting.apply(_:)`.
enum PlaylistEdit: Sendable, Equatable {
    /// A new playlist or folder. `songsFrom` names the playlist a duplicate copied its songs from.
    case added(PlaylistInfo, songsFrom: Int64?)
    case renamed(Int64, to: String)
    /// Takes every playlist inside a folder with it, as Music does.
    case deleted(Int64)
    /// Songs Music appended to a plain playlist, by persistent ID, in the order they went in,
    /// repeats included.
    case songsAdded(Int64, persistentIDs: [Int64])
    /// All entries for these songs removed from this playlist; the library songs stay.
    case songsRemoved(Int64, persistentIDs: [Int64])
}

// MARK: - Playlist commands

/// The source list's right-click commands, and adding songs to playlists. MusicKit can't make,
/// rename or delete playlists on macOS, or put songs in them (RESEARCH.md §6.1), but Music's
/// scripting can, and Sync Library carries the change to iCloud Music Library like any change
/// made in Music. Playlists are named by persistent id, never by name: two playlists can share
/// one. Errors carry a user-facing description.
protocol PlaylistEditing: Sendable {
    /// Makes an empty playlist, or a folder, named `name` inside the folder `parent` (nil: the
    /// top level). Returns it as made.
    func makePlaylist(named name: String, isFolder: Bool, in parent: Int64?) async throws -> PlaylistInfo
    /// `continuing` is true for a name typed over the playlist an add is filling, sent between
    /// two of its chunks. Like those chunks (`addSongs`), it never starts Music: if Music has
    /// quit, it throws, code -600, since quitting Music is how a user stops a long add.
    func renamePlaylist(_ id: Int64, to name: String, continuing: Bool) async throws
    /// A new playlist named `name` beside `playlist`, with its songs in its order. Plain
    /// playlists only: a copy of a smart playlist's songs would lose its rules.
    func duplicatePlaylist(_ playlist: PlaylistInfo, named name: String) async throws -> PlaylistInfo
    /// A folder goes with every playlist in it.
    func deletePlaylist(_ id: Int64) async throws
    /// Appends songs, by persistent ID and in this order, to the end of the plain playlist
    /// `playlist`, one `duplicate … to` per song (RESEARCH.md §6.10). One chunk of an add, in one
    /// conversation with Music: callers send about 25 songs at a time, so a tag save or a
    /// download never waits long behind a big add (other playlist commands wait for the whole
    /// add), and each chunk can reach the index as it goes in. Music adds a song again if it is
    /// already there, so callers leave those out.
    ///
    /// `continuing` is false for an add's first chunk, which starts Music (hidden) if it isn't
    /// running and asks for permission if oldTunes never had it, as every playlist command does.
    /// It is true for the chunks after that, which never start Music: quitting Music is how a
    /// user stops a long add, so if Music has quit, the add stops there.
    ///
    /// Never throws: what went in and why the rest didn't are in the report, so a partial add
    /// still reaches the index.
    func addSongs(_ persistentIDs: [Int64], to playlist: Int64, continuing: Bool) async -> PlaylistAddReport
    /// Removes playlist membership only. Later chunks never relaunch Music after a quit.
    func removeSongs(_ persistentIDs: [Int64], from playlist: Int64, continuing: Bool) async -> PlaylistRemoveReport
}

extension PlaylistEditing {
    /// An add's first chunk, or a whole add of a few songs.
    func addSongs(_ persistentIDs: [Int64], to playlist: Int64) async -> PlaylistAddReport {
        await addSongs(persistentIDs, to: playlist, continuing: false)
    }

    /// A rename on its own, which starts Music (hidden) if it isn't running, as every playlist
    /// command does.
    func renamePlaylist(_ id: Int64, to name: String) async throws {
        try await renamePlaylist(id, to: name, continuing: false)
    }
}

struct PlaylistRemoveReport: Sendable, Equatable {
    /// Confirmed absent from the playlist, including songs already removed elsewhere.
    var removed: [Int64] = []
    /// Stops at the first error; a timed-out request may still complete in Music.
    var stopReason: String?
}

/// What Music did with one chunk of an add to a playlist.
struct PlaylistAddReport: Sendable, Equatable {
    /// One song Music turned down.
    struct Refusal: Sendable, Equatable {
        var persistentID: Int64
        /// User-facing.
        var reason: String
    }

    /// Persistent IDs Music put in, in the order they went in.
    var added: [Int64] = []
    /// Songs Music turned down. The add went on past each of them, unless it was the first song
    /// the add asked Music to take (a playlist Music takes no songs into) or the third in a row
    /// turned down the same way.
    var refused: [Refusal] = []
    /// Why the add stopped before the end (permission, Music quit, Music not answering, a
    /// playlist Music takes no songs into or no longer has); user-facing. The song it stopped at
    /// is in `refused` when Music turned it down, or is `unanswered`, which may still go in;
    /// otherwise it, like every song after it, is in neither list and didn't go in.
    var stopReason: String?
    /// The song whose `duplicate` Music didn't answer in time, where the add stopped. Music still
    /// carries out an event it didn't answer in time, so this song may still go in.
    var unanswered: Int64? = nil
    /// Trying again would stop the same way: Music takes no songs into this playlist (it turned
    /// down the first song, or three in a row the same way), the playlist is gone from Music, the
    /// sandbox doesn't let the request through (-10004, -1742), or Music's dictionary has no
    /// `duplicate`.
    var retryWontHelp = false
}

// MARK: - Ingest

struct SubscriptionInfo: Sendable, Hashable {
    var canPlayCatalogContent: Bool
    var canBecomeSubscriber: Bool
    var hasCloudLibraryEnabled: Bool
}

struct IngestReport: Sendable {
    enum Status: Sendable, Equatable {
        case ok
        /// Media & Apple Music permission is missing. The message is user-facing.
        case notAuthorized(String)
        case failed(String)
    }
    var status: Status
    var musicLibrarySongs = 0
    var localFiles = 0
    var cloudOnly = 0
    var missing = 0
    var musicKitSongs = 0
    var joined = 0
    var folderTracks = 0
    var subscription: SubscriptionInfo?
    var seconds: Double = 0
}

protocol LibraryIngesting: Sendable {
    /// Reads Music.app's library and MusicKit, upserts the index, posts `.libraryDidChange`.
    /// Safe to call repeatedly; rows keep their ids.
    func refresh() async -> IngestReport
    /// File ▸ Add Folder to Library…: scan a folder tree for audio files and index them.
    /// Returns how many tracks were added or updated.
    func addFolder(_ url: URL) async throws -> Int
    /// Add Folder with "Also add to the Music app": offers `music` each file under `url` that
    /// Music doesn't already have, one at a time, then adds the folder like `addFolder(_:)`.
    /// A file Music takes is never indexed as a folder song; it arrives through the Music library
    /// on the next re-ingest, so it shows once. Refusals are reported, not thrown.
    func addFolder(_ url: URL, handingOffTo music: any MusicLibraryAdding) async throws -> MusicHandoffReport
    /// After the index was rebuilt: puts back the record of files handed to Music, before the
    /// added folders are scanned again.
    func restoreHandoffs(_ paths: [String]) async
    /// Full-size artwork bytes for a track, or nil. Callers downscale.
    func artworkData(for track: Track) async -> Data?
}

// MARK: - Handing songs to Music

/// What Music said about one file it was asked to add.
enum MusicAddOutcome: Sendable, Equatable {
    /// In Music's library now, as the song with this persistent ID (nil if Music didn't say).
    case added(persistentID: Int64?)
    /// Music didn't take this file. The text is for the log.
    case refused(String)
    /// Music stopped answering: it quit, timed out, or oldTunes lost permission. The text is
    /// user-facing. Send nothing more.
    case stopped(String)
}

/// File ▸ Add Folder's "Also add to the Music app". MusicKit can't add songs on macOS
/// (RESEARCH.md §1), but Music's own scripting `add` command can, and Music's Sync Library then
/// matches or uploads what it took to iCloud Music Library. A protocol so the library bench can
/// stand in for Music and prove the hand-off without adding anything to Noah's library.
protocol MusicLibraryAdding: Sendable {
    /// Gets Music ready: running (hidden), and oldTunes allowed to control it, asking if it never
    /// has. Nil when ready; otherwise the user-facing reason nothing can be added.
    func prepare() async -> String?
    /// Adds one file to Music's library (not to a playlist). Never starts Music: if it has quit
    /// since `prepare()`, the answer is `.stopped`.
    func add(_ file: URL) async -> MusicAddOutcome
}

/// What one Add Folder did with "Also add to the Music app" on. Paths are as the folder walk
/// spells them, in the order they were offered.
struct MusicHandoffReport: Sendable {
    /// The added folder, as the index stores it.
    var root: String
    /// Files Music took. Each reaches oldTunes through the Music library.
    var handedOff: [String] = []
    /// Files Music didn't take. They are oldTunes-only folder songs.
    var refused: [String] = []
    /// Files never offered because Music wasn't ready or stopped answering. oldTunes-only too.
    var notSent: [String] = []
    /// Why `notSent` is not empty. User-facing.
    var stopReason: String?
    /// Files skipped because Music already has them (its own files, or handed to it before).
    var alreadyInMusic = 0
    /// Folder songs added or updated in oldTunes.
    var folderTracks = 0
}

/// Finds the MusicKit `Song` that can stream a track (fallback steps 2 and 3, RESEARCH.md §1).
protocol CloudSongResolving: Sendable {
    func cloudSong(for track: Track) async -> Song?
}

// MARK: - Downloading songs

/// What Music said when asked to download one song.
enum MusicDownloadOutcome: Sendable, Equatable {
    /// Music took the request. The file comes down in the background.
    case requested
    /// Music didn't answer in time. It may still be downloading the song; send nothing more for
    /// now. User-facing.
    case unanswered(String)
    /// Music turned this song down. User-facing. `code`: the error number Music turned the
    /// `download` down with, which three refusals in a row must share to stop a batch (Music's
    /// words may name the song); nil when the song couldn't be looked up, so no `download` went
    /// out, which says nothing about the songs after it, or when the error had no number.
    case refused(String, code: Int? = nil)
    /// Music stopped answering, quit, or oldTunes lost permission. User-facing. Send nothing more.
    /// `retryWontHelp`: choosing Download again would stop the same way (the sandbox doesn't let
    /// the request through, or Music's dictionary has no `download`).
    case stopped(String, retryWontHelp: Bool = false)
}

/// Download: brings iCloud songs down to this Mac. MusicKit can't on macOS (RESEARCH.md §1), but
/// Music's scripting `download` command (hookDwnl) can (§6.9). Music then fetches the file in the
/// background and never says when it is done, so callers watch the library for the song to
/// become a file.
protocol SongDownloading: Sendable {
    /// Gets Music ready: running (hidden), and oldTunes allowed to control it, asking if it never
    /// has. Nil when ready; otherwise the user-facing reason nothing can be downloaded.
    func prepare() async -> String?
    /// Asks Music to download one song. Returns once Music has answered (or didn't in time), not
    /// when the file is on this Mac. Never starts Music: if it has quit since `prepare()`, the
    /// answer is `.stopped`.
    func download(_ persistentID: Int64) async -> MusicDownloadOutcome
}

// MARK: - Playback

enum RepeatMode: Sendable, Hashable { case off, all, one }

struct PlaybackState: Sendable, Equatable {
    var nowPlaying: Track?
    var isPlaying = false
    /// True while a cloud track is being prepared.
    var isLoading = false
    var position: TimeInterval = 0
    var duration: TimeInterval = 0
    var isShuffling = false
    var repeatMode: RepeatMode = .off
    /// 0...1
    var volume: Float = 0.75
    /// False during an iCloud song oldTunes can't set the level of (no System Audio Recording
    /// permission). The volume slider greys out then.
    var isVolumeEnabled = true
    /// User-facing reason the last track could not play, if any.
    var lastError: String?
}

@MainActor
protocol PlaybackControlling: AnyObject {
    var state: PlaybackState { get }
    /// Called on every state change, about 10 times a second while playing. Returns a token
    /// for `removeObserver`.
    func addObserver(_ handler: @escaping @MainActor (PlaybackState) -> Void) -> UUID
    func removeObserver(_ token: UUID)

    /// Double-click: play `startAt` (or the first playable id) with `queue` as the context.
    func play(queue: [Track.ID], startAt: Track.ID?)
    /// The visible order changed (sort/search/scope). The current song keeps playing and the
    /// queue continues from its position in the new order.
    func replaceQueue(_ ids: [Track.ID])
    func playPause()
    func next()
    /// iTunes rule: more than 3 s into a song restarts it; otherwise goes to the previous one.
    func previous()
    /// The previous song however far into this one, for the Dock menu: previous() needs a second
    /// press within 3 s to get past the restart, and reopening that menu takes longer.
    func previousSong()
    /// ⌥→, iTunes's "next album in a list": the first song after the playing song's album.
    func nextAlbum()
    /// ⌥←: the first song of the album before the playing song's.
    func previousAlbum()
    func seek(to seconds: TimeInterval)
    func stop()
    func setVolume(_ volume: Float)
    /// Settings ▸ Sound Check: play each song at the level Music measured for it.
    func setSoundCheck(_ on: Bool)
    func setShuffle(_ on: Bool)
    func setRepeat(_ mode: RepeatMode)
}

// MARK: - Tag editing

/// Current tag values for the Get Info sheet.
struct TagFields: Sendable, Equatable {
    var title = "", artist = "", album = "", albumArtist = "", composer = ""
    var genre = "", grouping = "", comments = ""
    /// 0 = blank.
    var year = 0, trackNumber = 0, trackCount = 0, discNumber = 0, discCount = 0, bpm = 0
    var isCompilation = false
}

/// A change to apply. Nil fields are left alone, so one patch can edit many songs at once
/// (multi-selection Get Info, like iTunes).
struct TagPatch: Sendable, Equatable {
    var title: String?, artist: String?, album: String?, albumArtist: String?, composer: String?
    var genre: String?, grouping: String?, comments: String?
    var year: Int?, trackNumber: Int?, trackCount: Int?, discNumber: Int?, discCount: Int?, bpm: Int?
    var isCompilation: Bool?
    /// New front-cover image bytes (PNG or JPEG).
    var artwork: Data?
    var removeArtwork = false

    var isEmpty: Bool { self == TagPatch() }
}

struct TagApplyResult: Sendable {
    struct Failure: Sendable { var id: Track.ID; var reason: String }
    var succeeded: [Track.ID] = []
    var failed: [Failure] = []
}

protocol TagEditing: Sendable {
    /// Music-library songs read from the index (what the list shows); added-folder songs read their file.
    func readFields(of track: Track) async throws -> TagFields
    /// Music-library songs save through Music.app, which also rewrites the song's file if it has one,
    /// so the next ingest agrees. Added-folder files are rewritten atomically (RESEARCH.md §6.4).
    func apply(_ patch: TagPatch, to tracks: [Track]) async -> TagApplyResult
}

// MARK: - Events

extension Notification.Name {
    /// Posted on the main thread after the index changes (ingest, folder add, tag edit, a playlist
    /// edit). Anything may have changed, unless `userInfo` says what did (`LibraryChange`).
    static let libraryDidChange = Notification.Name("oldTunes.libraryDidChange")
}

/// What `.libraryDidChange`'s `userInfo` can say about a change.
enum LibraryChange {
    /// An `Int64`: the playlist songs were just added to (`PlaylistEdit.songsAdded`, one chunk of
    /// an add), and nothing else changed: no song, no other playlist's songs, and no playlist's
    /// name, kind or place. Only a list showing that playlist has anything new.
    static let songsAddedTo = "oldTunes.libraryDidChange.songsAddedTo"
}
