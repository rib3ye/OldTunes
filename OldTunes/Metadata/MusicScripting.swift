import AppKit
import ScriptingBridge

// Music.app's scripting dictionary, declared by hand because the project has no bridging header
// for an sdp-generated Music.h. Only element accessors and the commands `add`, `delete`, `move`,
// `duplicate` and `download` are declared; properties go through KVC by their sdef names so
// there is one table of keys (see `MusicScriptingSession`). Every member is optional:
// ScriptingBridge builds these methods at runtime from the sdef, and an optional requirement
// turns a missing one into nil instead of a crash. Optional members are only callable through
// the protocol type, hence the `as …Scripting` casts at each call.

@objc private protocol MusicApplicationScripting {
    @objc optional func sources() -> SBElementArray
    /// `add` (hookAdd): `- (MusicTrack *) add:(NSArray<NSURL *> *)x to:(SBObject *)to` in an
    /// sdp-generated Music.h. A nil `to` puts the files in the library itself (seen live, §6.7).
    /// Typed `Any?` because Music may answer with one track or a list of them.
    @objc optional func add(_ files: [URL], to location: SBObject?) -> Any?
}

@objc private protocol MusicSourceScripting {
    @objc optional func libraryPlaylists() -> SBElementArray
    /// Every playlist in the library, folders included.
    @objc optional func playlists() -> SBElementArray
}

@objc private protocol MusicPlaylistScripting {
    @objc optional func tracks() -> SBElementArray
}

@objc private protocol MusicTrackScripting {
    @objc optional func artworks() -> SBElementArray
}

@objc private protocol MusicItemScripting {
    @objc optional func delete()
    /// `move` (core/move), which in Music moves playlists only: into a folder playlist.
    @objc optional func moveTo(_ location: SBObject)
    /// `duplicate` (core/clon). A track duplicated to a playlist is added to that playlist.
    @objc optional func duplicateTo(_ location: SBObject?) -> SBObject?
    /// `download` (hookDwnl): `- (void) download` on every item in an sdp-generated Music.h. A
    /// cloud song comes down to this Mac. Void, but sent with kAEWaitReply like every
    /// ScriptingBridge call, so it returns when Music answers or the session's timeout passes.
    @objc optional func download()
}

extension SBApplication: MusicApplicationScripting {}
extension SBObject: MusicSourceScripting, MusicPlaylistScripting, MusicTrackScripting, MusicItemScripting {}

/// ScriptingBridge raises an Objective-C exception for every error reply when its application has
/// no delegate (SBApplication.h: "If no delegate has been assigned, the receiver raises an
/// exception"). Swift cannot catch those, so a timeout, a refused property write or a vanished
/// track would crash OldTunes. With this delegate the failed call returns nil instead, and the
/// session turns the recorded error into a thrown, user-facing `TagEditError`.
private final class ScriptingErrorRecorder: NSObject, SBApplicationDelegate {
    private var pending: Error?

    func eventDidFail(_ event: UnsafePointer<AppleEvent>, withError error: any Error) -> Any? {
        // Keep the first failure of a step; it names the real cause, later ones are fallout.
        if pending == nil { pending = error }
        return nil
    }

    func take() -> Error? {
        defer { pending = nil }
        return pending
    }
}

/// One conversation with Music.app. Not Sendable: ScriptingBridge objects belong to the thread
/// that made them, so a session is created, used and dropped inside one `run` on the scripting
/// queue (`MusicAppTagWriter`, `MusicAppLibraryAdder`, `MusicPlaylistEditor`,
/// `MusicSongDownloader`).
///
/// Property reads and writes, `add`, `delete` (artwork, playlists, and the live hand-off check's
/// own test song), `make` (a plain Apple Event) and `move` for playlists only, `duplicate` of
/// songs into playlists, and `download` for iCloud songs. This type deliberately has no way to
/// send play, pause, next track or any other playback command (§6.5): Music answering those
/// would take over Now Playing.
final class MusicScriptingSession {
    /// What the conversation is for, so a refusal names the right consequence.
    enum Purpose {
        case savingTags
        case addingSongs
        case editingPlaylists
        case downloadingSongs

        var deniedReason: String {
            switch self {
            case .savingTags: MusicAutomation.deniedReason
            case .addingSongs: MusicAutomation.addDeniedReason
            case .editingPlaylists: MusicAutomation.playlistDeniedReason
            case .downloadingSongs: MusicAutomation.downloadDeniedReason
            }
        }

        var unavailableReason: String {
            switch self {
            case .savingTags: MusicAutomation.unavailableReason
            case .addingSongs: MusicAutomation.addUnavailableReason
            case .editingPlaylists: MusicAutomation.playlistUnavailableReason
            case .downloadingSongs: MusicAutomation.downloadUnavailableReason
            }
        }

        /// What errAENoSuchObject means here.
        var missingReason: String {
            self == .editingPlaylists ? "Music couldn’t find the playlist. It may have been deleted already."
                : Self.songMissingReason
        }

        /// …and what it means for a song's own lookup (`track(persistentID:)`), whatever the
        /// conversation is for: an add to a playlist looks each of its songs up too.
        static let songMissingReason = "Music couldn’t find the song. It may have been removed from the library."
    }

    private let app: SBApplication
    private let errors = ScriptingErrorRecorder()
    private let purpose: Purpose

    /// `timeout`: how long to wait for each of Music's answers, in seconds; nil takes the
    /// purpose's own. Only the live download check passes one, to learn how long Music takes.
    init(for purpose: Purpose = .savingTags, timeout: TimeInterval? = nil) throws {
        guard let app = SBApplication(bundleIdentifier: MusicAutomation.bundleID) else {
            throw TagEditError(message: purpose.unavailableReason, code: -600)
        }
        app.delegate = errors
        // If Music quit after `launchHiddenIfNeeded`, ScriptingBridge relaunches it for the next
        // event; make that launch hidden and in the background too.
        app.launchFlags = [.dontAddToRecents, .dontSwitch, .andHide]
        // Ticks (1/60 s). A whose-query over 16k tracks is fast; 20 s means Music is stuck. An add
        // may wait on Music copying a long file into its Media folder, so it gets a minute. Whether
        // Music answers `download` at once or only once the file is down isn't known yet
        // (RESEARCH.md §10-R7): 30 s, and a download that runs out of time may still come down.
        let seconds = switch purpose {
        case .addingSongs: 60
        case .downloadingSongs: 30
        case .savingTags, .editingPlaylists: 20
        }
        app.timeout = timeout.map { Int(($0 * 60).rounded()) } ?? seconds * 60
        self.app = app
        self.purpose = purpose
    }

    /// Every conversation with Music, tag saves and song adds alike, runs one at a time on its own
    /// thread: ScriptingBridge calls block on Music's reply, and SB objects are not thread-safe.
    private static let queue = DispatchQueue(label: "com.noahtsutsui.oldtunes.music-scripting")

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// Adds one file to Music's library. Returns the new track, or nil when Music answered with
    /// nothing. Music turns down a file it can't import either that way or with an error; which
    /// one is not yet seen live (§6.7), and the hand-off treats both as a refusal.
    func add(file: URL) throws -> SBObject? {
        _ = errors.take()
        guard let add = (app as MusicApplicationScripting).add else {
            throw TagEditError(message: "Music’s scripting dictionary has no “add” command, so songs can’t be added to it.",
                               code: -1708)
        }
        let answer = add([file], nil)
        try check("Music couldn’t add “\(file.lastPathComponent)”")
        if let track = answer as? SBObject { return track }
        return (answer as? [Any])?.first as? SBObject
    }

    /// The `persistent ID` Music gave a track or playlist, as the index's Int64 bit pattern.
    func persistentID(of item: SBObject, failure: String = "Music couldn’t read the new song’s ID") throws -> Int64? {
        try requireProperty("persistentID", on: item)
        let hex = item.value(forKey: "persistentID") as? String
        try check(failure)
        return hex.flatMap(MusicPersistentID.bitPattern(fromHex:))
    }

    /// Errors after which nothing more should be sent: OldTunes lost permission, its sandbox lets
    /// nothing reach Music, Music stopped answering, Music is gone, or it doesn't handle the
    /// command at all. Any other error is about the one request.
    static func endsConversation(_ code: Int?) -> Bool {
        [-1743, -1742, -1712, -600, -609, -1708].contains(code)   // -1708: errAEEventNotHandled
    }

    /// For the loops that send one request per song (downloads, adds to a playlist): whether the
    /// songs after this error should be sent at all. As `endsConversation`, with two changes.
    /// Music also answers -1708 to turn down one request, so only OldTunes's own finding that the
    /// command is missing stops. And -10004 stops: it means a request the sandbox doesn't let
    /// through (§3.1), which every other song's would be too.
    static func stopsBatch(_ error: TagEditError) -> Bool {
        if error.missingCommand || error.code == -10004 { return true }
        return error.code != -1708 && endsConversation(error.code)
    }

    /// The library track with this persistent ID, matched by `whose persistent ID is "…"`.
    /// Never matched by title/artist/album: duplicates are common in a 20-year library.
    func track(persistentID: Int64) throws -> SBObject {
        let hex = MusicPersistentID.hex(persistentID)
        _ = errors.take()
        guard let library = try librarySource(),
              let playlists = (library as MusicSourceScripting).libraryPlaylists?(), playlists.count > 0,
              let libraryPlaylist = playlists.object(at: 0) as? SBObject,
              let tracks = (libraryPlaylist as MusicPlaylistScripting).tracks?() else {
            try check("Music’s library couldn’t be read")
            throw TagEditError(message: "Music’s library couldn’t be read.")
        }
        try check("Music’s library couldn’t be read")
        let track = firstMatch(in: tracks, NSPredicate(format: "persistentID == %@", hex))
        // errAENoSuchObject here means this song, in an add too, not the playlist.
        try check("Music couldn’t look up the song \(hex)", missing: Purpose.songMissingReason)
        guard let track else {
            throw TagEditError(message: "Music has no song with this ID (\(hex)). It may have been removed from the library.")
        }
        return track
    }

    /// The first of `elements` that matches `predicate` (`whose …`), named the way Music answers
    /// the lookup (`shared track id 12345 of library playlist id 67 of source id 64`). Swift's
    /// `filtered(using:)` comes back as an array whose first element ScriptingBridge names
    /// `item 1 of every track whose …`, and from a sandboxed app Music refuses everything sent to
    /// an `item` (-10004, errAEPrivilegeError): no access group in its dictionary reaches it
    /// (RESEARCH.md §3.1). So the filter is applied through Objective-C, which keeps it a lookup
    /// still to be sent, and `get` sends it. A timeout is reported as itself, not as no match.
    private func firstMatch(in elements: SBElementArray, _ predicate: NSPredicate) -> SBObject? {
        (whose(elements, predicate)?.get() as? [Any])?.first as? SBObject
    }

    /// `elements whose <predicate>`, a lookup not sent yet.
    private func whose(_ elements: SBElementArray, _ predicate: NSPredicate) -> SBElementArray? {
        elements.perform(#selector(NSArray.filtered(using:)), with: predicate)?.takeUnretainedValue() as? SBElementArray
    }

    /// Music's own library (`source 1`), which holds every playlist.
    private func librarySource() throws -> SBObject? {
        guard let sources = (app as MusicApplicationScripting).sources?(), sources.count > 0 else {
            try check("Music’s library couldn’t be read")
            return nil
        }
        return sources.object(at: 0) as? SBObject
    }

    // MARK: Playlists

    /// The playlist or folder with this persistent ID, matched like songs (`whose persistent ID
    /// is "…"`), never by name.
    ///
    /// Addressed as `playlist id 23456 of source 1`: Music would name a folder
    /// `folder playlist id 23456 of source id 64`, and a source has no folder playlist element in
    /// its dictionary, so from a sandboxed app Music refuses every event sent to that (-10004).
    /// So only the playlist's id is looked up, and the playlist then addressed by it.
    ///
    /// No such playlist throws -1728 (errAENoSuchObject), the code Music answers for an object
    /// that isn't there, so an add can tell a playlist that is gone from a passing failure
    /// (`MusicPlaylistEditor.retryWontHelp`).
    func playlist(persistentID: Int64) throws -> SBObject {
        let hex = MusicPersistentID.hex(persistentID)
        _ = errors.take()
        guard let library = try librarySource(),
              let playlists = (library as MusicSourceScripting).playlists?() else {
            try check("Music’s playlists couldn’t be read")
            throw TagEditError(message: "Music’s playlists couldn’t be read.")
        }
        let ids = whose(playlists, NSPredicate(format: "persistentID == %@", hex))?
            .array(byApplying: NSSelectorFromString("id")) as? [Any]
        try check("Music couldn’t look up the playlist \(hex)")
        guard let id = ids?.first, let playlist = playlists.object(withID: id) as? SBObject else {
            throw TagEditError(message: "Music has no playlist with this ID (\(hex)). It may have been deleted already.",
                               code: -1728)
        }
        return playlist
    }

    /// Makes an empty playlist, or a folder, at the top level of Music's playlists, and returns
    /// the persistent ID Music gives it.
    ///
    /// A plain Apple Event, `make new user playlist with properties {name: …}`, not
    /// ScriptingBridge: on macOS 27 `classForScriptingClass:` answers with an SBPseudoClass,
    /// and the object it makes is an SBProxyByCode (an NSProxy) that a Swift cast crashes on
    /// (seen October 20, 2026). Objects ScriptingBridge hands back from Music are plain SBObjects.
    func makePlaylist(named name: String, isFolder: Bool) throws -> Int64 {
        let what = "Music couldn’t make the \(isFolder ? "folder" : "playlist") “\(name)”"
        let make = Self.coreEvent(0x6372_656C)                                                   // crel
        make.setParam(NSAppleEventDescriptor(typeCode: isFolder ? 0x6346_6F50 : 0x6355_7350),    // cFoP / cUsP
                      forKeyword: 0x6B6F_636C)                                                    // kocl
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(NSAppleEventDescriptor(string: name), forKeyword: 0x706E_616D)  // pnam
        make.setParam(properties, forKeyword: 0x7072_6474)                                        // prdt
        guard let answer = try send(make, what).paramDescriptor(forKeyword: Self.directObject) else {
            throw TagEditError(message: "\(what): Music didn’t say what it made.")
        }
        let made = Self.asPlaylist(answer)
        // persistent ID of <what Music made>
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(NSAppleEventDescriptor(typeCode: 0x7072_6F70), forKeyword: 0x7761_6E74)  // want: prop
        property.setDescriptor(made, forKeyword: 0x6672_6F6D)                                           // from
        property.setDescriptor(NSAppleEventDescriptor(enumCode: 0x7072_6F70), forKeyword: 0x666F_726D)  // form: prop
        property.setDescriptor(NSAppleEventDescriptor(typeCode: 0x7050_4953), forKeyword: 0x7365_6C64)  // seld: pPIS
        let get = Self.coreEvent(0x6765_7464)                                                           // getd
        get.setParam(property.coerce(toDescriptorType: 0x6F62_6A20) ?? property, forKeyword: Self.directObject)  // obj
        let hex: String?
        do {
            hex = try send(get, "Music couldn’t read the new playlist’s ID").paramDescriptor(forKeyword: Self.directObject)?.stringValue
        } catch {
            Log.error("music scripting: Music answered make with \(answer), read as \(made)")
            throw error
        }
        guard let id = hex.flatMap(MusicPersistentID.bitPattern(fromHex:)) else {
            throw TagEditError(message: "Music made “\(name)” but didn’t say which one it is. It appears in a few seconds.")
        }
        return id
    }

    /// Music's answer to `make`, readdressed as `playlist id 23456 of source id 64`. Music names
    /// the new playlist by its own class (seen October 28, 2026:
    /// `folder playlist id 23456 of source id 64`), and a source has no folder playlist element in
    /// its dictionary, so from a sandboxed app Music refuses every event sent to that (-10004).
    /// `playlist` is an element of a source and covers every kind (RESEARCH.md §3.1).
    private static func asPlaylist(_ reference: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        guard reference.descriptorType == 0x6F62_6A20,                                     // obj
              let record = reference.coerce(toDescriptorType: 0x7265_636F) else {          // reco
            return reference
        }
        record.setDescriptor(NSAppleEventDescriptor(typeCode: 0x6350_6C79), forKeyword: 0x7761_6E74)  // want: cPly
        return record.coerce(toDescriptorType: 0x6F62_6A20) ?? reference
    }

    /// '----', the direct object.
    private static let directObject: AEKeyword = 0x2D2D_2D2D

    /// A Core Suite event ('core') to Music.
    private static func coreEvent(_ id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor.appleEvent(withEventClass: 0x636F_7265, eventID: id,
                                          targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: MusicAutomation.bundleID),
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
    }

    /// Sends a plain Apple Event as this session's ScriptingBridge calls go: Music never asked to
    /// come forward, the same timeout, the same user-facing errors.
    private func send(_ event: NSAppleEventDescriptor, _ what: String) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: TimeInterval(app.timeout) / 60)
        } catch {
            throw TagEditError(message: Self.describe(error, what: what, purpose: purpose), code: Self.number(of: error))
        }
        if let number = reply.paramDescriptor(forKeyword: 0x6572_726E)?.int32Value, number != 0 {     // errn
            let text = reply.paramDescriptor(forKeyword: 0x6572_7273)?.stringValue                      // errs
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(number),
                                userInfo: text.map { ["ErrorString": $0] } ?? [:])
            throw TagEditError(message: Self.describe(error, what: what, purpose: purpose), code: Int(number))
        }
        return reply
    }

    func rename(_ playlist: SBObject, to name: String) throws {
        _ = errors.take()
        try requireProperty("name", on: playlist, settable: true)
        playlist.setValue(name, forKey: "name")
        try check("Music didn’t accept the name “\(name)”")
    }

    func move(_ playlist: SBObject, into folder: SBObject) throws {
        _ = errors.take()
        guard let move = (playlist as MusicItemScripting).moveTo else {
            throw TagEditError(message: "Music’s scripting dictionary has no “move” command.", code: -1708)
        }
        move(folder)
        try check("Music couldn’t move the playlist into its folder")
    }

    /// Adds every song of `source` to `destination` in order, repeats included, with one
    /// `duplicate … to` per song: a one-event `duplicate every track` has no ScriptingBridge
    /// form. Returns how many songs went in.
    func copyTracks(of source: SBObject, to destination: SBObject) throws -> Int {
        _ = errors.take()
        guard let tracks = (source as MusicPlaylistScripting).tracks?() else {
            try check("Music couldn’t read the playlist’s songs")
            throw TagEditError(message: "Music couldn’t read the playlist’s songs.")
        }
        let count = tracks.count
        try check("Music couldn’t read the playlist’s songs")
        for index in 0..<count {
            guard let track = tracks.object(at: index) as? SBObject,
                  let duplicate = (track as MusicItemScripting).duplicateTo else {
                throw TagEditError(message: "Music’s scripting dictionary has no “duplicate” command.", code: -1708)
            }
            _ = duplicate(destination)
            try check("Music couldn’t copy song \(index + 1) of \(count)")
        }
        return count
    }

    /// Adds one library song, as `track(persistentID:)` found it, to the end of a plain
    /// playlist: copyTracks' `duplicate … to` for a single song. Music adds it again if it is
    /// already there, without asking.
    func add(_ track: SBObject, to playlist: SBObject) throws {
        _ = errors.take()
        guard let duplicate = (track as MusicItemScripting).duplicateTo else {
            throw TagEditError(message: "Music’s scripting dictionary has no “duplicate” command, so songs can’t be added to playlists.",
                               code: -1708, missingCommand: true)
        }
        _ = duplicate(playlist)
        try check("Music couldn’t add the song")
    }

    /// Music deletes a folder together with every playlist in it.
    func deletePlaylist(_ playlist: SBObject) throws {
        _ = errors.take()
        guard let delete = (playlist as MusicItemScripting).delete else {
            throw TagEditError(message: "Music’s scripting dictionary has no “delete” command.", code: -1708)
        }
        delete()
        try check("Music couldn’t delete the playlist")
    }

    /// Resolve the playlist, then check Music's own class and flags before permitting removal.
    /// A library or special playlist must never be the container of a track delete.
    func playlistRemovalTarget(_ persistentID: Int64) throws -> NSAppleEventDescriptor {
        let playlist = try playlist(persistentID: persistentID)
        try requireProperty("id", on: playlist)
        let id = playlist.value(forKey: "id") as? NSNumber
        try check("Music couldn’t read the playlist’s ID")
        guard let id else { throw TagEditError(message: "Music couldn’t read the playlist’s ID.") }
        let reference = Self.playlistReference(id: id.int32Value)
        func property(_ code: OSType) throws -> NSAppleEventDescriptor? {
            let get = Self.coreEvent(0x6765_7464) // getd
            get.setParam(Self.objectReference(want: 0x7072_6F70, from: reference, form: 0x7072_6F70,
                                              key: NSAppleEventDescriptor(typeCode: code)), forKeyword: Self.directObject)
            return try send(get, "Music couldn’t check the playlist").paramDescriptor(forKeyword: Self.directObject)
        }
        let kind = try property(0x7063_6C73)?.typeCodeValue // pcls
        let special = try property(0x7053_704B)?.enumCodeValue // pSpK
        guard kind == 0x6355_7350, special == 0x6B4E_6F6E, // cUsP, kNon
              try property(0x7053_6D74)?.booleanValue == false, // pSmt
              try property(0x7047_6E73)?.booleanValue == false else { // pGns
            throw TagEditError(message: "Songs can only be removed from a plain playlist you can edit.")
        }
        return reference
    }

    /// Keep the whose specifier inside the playlist all the way to the delete event. Calling
    /// `track(persistentID:)` here would resolve a library track and delete the library song.
    /// Music evaluates the ID test at the delete, so a concurrent reorder cannot change its target.
    func removeSong(_ persistentID: Int64, from playlist: NSAppleEventDescriptor) throws {
        _ = try send(Self.playlistRemovalEvent(persistentID, from: playlist), "Music couldn’t remove the song from the playlist")
    }

    static func playlistReference(id: Int32) -> NSAppleEventDescriptor {
        let source = objectReference(want: 0x6353_7263, from: .null(), form: 0x696E_6478,
                                     key: NSAppleEventDescriptor(int32: 1)) // source 1
        return objectReference(want: 0x6350_6C79, from: source, form: 0x4944_2020,
                               key: NSAppleEventDescriptor(int32: id)) // playlist id
    }

    /// Pure event construction, inspected by the offline playlist bench; never a library-track
    /// reference, and all occurrences of a song in this playlist match OldTunes's single row.
    static func playlistRemovalEvent(_ persistentID: Int64, from playlist: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let examined = NSAppleEventDescriptor(descriptorType: 0x6578_6D6E, data: Data())! // exmn
        let property = objectReference(want: 0x7072_6F70, from: examined, form: 0x7072_6F70,
                                       key: NSAppleEventDescriptor(typeCode: 0x7050_4953)) // pPIS
        let comparison = NSAppleEventDescriptor.record()
        comparison.setDescriptor(NSAppleEventDescriptor(enumCode: 0x3D20_2020), forKeyword: 0x7265_6C6F) // relo: =
        comparison.setDescriptor(property, forKeyword: 0x6F62_6A31) // obj1
        comparison.setDescriptor(NSAppleEventDescriptor(string: MusicPersistentID.hex(persistentID)), forKeyword: 0x6F62_6A32) // obj2
        let tracks = objectReference(want: 0x6354_726B, from: playlist, form: 0x7465_7374,
                                     key: comparison.coerce(toDescriptorType: 0x636D_7064)!) // cTrk, test, cmpd
        let event = coreEvent(0x6465_6C6F) // delo
        event.setParam(tracks, forKeyword: directObject)
        return event
    }

    private static func objectReference(want: OSType, from: NSAppleEventDescriptor, form: OSType,
                                        key: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let reference = NSAppleEventDescriptor.record()
        reference.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: 0x7761_6E74)
        reference.setDescriptor(from, forKeyword: 0x6672_6F6D)
        reference.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: 0x666F_726D)
        reference.setDescriptor(key, forKeyword: 0x7365_6C64)
        return reference.coerce(toDescriptorType: 0x6F62_6A20)!
    }

    /// Asks Music to download `item`, a cloud song as `track(persistentID:)` found it, to this
    /// Mac. Music fetches the file in the background and never says when it is done.
    func download(_ item: SBObject) throws {
        _ = errors.take()
        guard let download = (item as MusicItemScripting).download else {
            throw TagEditError(message: "Music’s scripting dictionary has no “download” command, so songs can’t be downloaded.",
                               code: -1708, missingCommand: true)
        }
        download()
        try check("Music couldn’t download the song")
    }

    func name(of item: SBObject, failure: String = "Music couldn’t read the song’s name") throws -> String? {
        try requireProperty("name", on: item)
        let name = item.value(forKey: "name") as? String
        try check(failure)
        return name
    }

    /// Removes one track from Music's library. Only the live hand-off check calls this, to take
    /// its own invented test song back out, and only with Noah's go-ahead.
    func delete(_ track: SBObject) throws {
        _ = errors.take()
        guard let delete = (track as MusicItemScripting).delete else {
            throw TagEditError(message: "Music’s scripting dictionary has no “delete” command.")
        }
        delete()
        try check("Music couldn’t remove the song")
    }

    /// Writes only the properties §6.5 lists as read-write on `track`.
    func apply(_ patch: TagPatch, to track: SBObject) throws {
        _ = errors.take()
        for (key, value) in Self.propertyWrites(for: patch) {
            try requireProperty(key, on: track, settable: true)
            track.setValue(value, forKey: key)
            try check("Music didn’t accept the change to \(key)")
        }

        if patch.removeArtwork || patch.artwork != nil, let artworks = (track as MusicTrackScripting).artworks?() {
            // Delete from the end so the remaining indexes stay valid.
            for index in stride(from: artworks.count - 1, through: 0, by: -1) {
                (artworks.object(at: index) as? MusicItemScripting)?.delete?()
            }
            try check("Music couldn’t remove the old artwork")
        }
        if let data = patch.artwork {
            guard let image = NSImage(data: data) else {
                throw TagEditError(message: "The artwork image couldn’t be read.")
            }
            // `artwork 1` is created by setting its data, exactly as in AppleScript.
            guard let artworks = (track as MusicTrackScripting).artworks?(), let first = artworks.object(at: 0) as? SBObject else {
                try check("Music didn’t accept the artwork")
                throw TagEditError(message: "Music didn’t accept the artwork.")
            }
            try requireProperty("data", on: first, settable: true)
            first.setValue(image, forKey: "data")
            try check("Music didn’t accept the artwork")
        }
    }

    /// KVC on a key the scripting dictionary lacks raises NSUndefinedKeyException, which Swift
    /// cannot catch either; ask the generated class first so a renamed sdef property fails as a
    /// message, not a crash.
    private func requireProperty(_ key: String, on object: SBObject, settable: Bool = false) throws {
        let selector = settable ? "set\(key.prefix(1).uppercased())\(key.dropFirst()):" : key
        guard object.responds(to: NSSelectorFromString(selector)) else {
            throw TagEditError(message: "Music’s scripting dictionary has no “\(key)” property, so the change wasn’t saved.")
        }
    }

    /// Throws the error ScriptingBridge reported since the last check, if any. `missing`: what
    /// errAENoSuchObject means for this step, when not the purpose's (`describe`).
    private func check(_ what: String, missing: String? = nil) throws {
        guard let error = errors.take() else { return }
        throw TagEditError(message: Self.describe(error, what: what, purpose: purpose, missing: missing),
                           code: Self.number(of: error))
    }

    /// The Apple Event error number in a ScriptingBridge error.
    static func number(of error: Error) -> Int {
        let ns = error as NSError
        return (ns.userInfo["ErrorNumber"] as? NSNumber)?.intValue ?? ns.code
    }

    /// One sentence for the per-song failure list. The few codes a user can act on get their
    /// own wording; anything else keeps Music's own description and number. `missing` words
    /// errAENoSuchObject for a step that looked for something other than what the purpose is
    /// about (a song's lookup while editing playlists); nil takes the purpose's own.
    static func describe(_ error: Error, what: String, purpose: Purpose = .savingTags, missing: String? = nil) -> String {
        let ns = error as NSError
        let number = Self.number(of: error)
        switch number {
        case -1743:   // errAEEventNotPermitted
            return purpose.deniedReason
        case -10004:  // errAEPrivilegeError
            // What Music answers a sandboxed app for an event its access groups don't reach
            // (RESEARCH.md §3.1). No setting fixes that, so it is an OldTunes bug, never the
            // user's to solve.
            Log.error("music scripting: Music refused “\(what)” (-10004): an event outside OldTunes's access group")
            return "\(what): Music refused this request (error -10004)."
        case -1742:   // errAETargetAddressNotPermitted: the sandbox let nothing reach Music at all
            return "\(what): this copy of OldTunes isn’t allowed to send anything to Music (error -1742)."
        case -1712:   // errAETimeout
            return "\(what): Music didn’t answer in time. Try again when Music isn’t busy."
        case -1728:   // errAENoSuchObject
            return "\(what): \(missing ?? purpose.missingReason)"
        case -600, -609:  // procNotFound, connectionInvalid
            return purpose.unavailableReason
        default:
            let detail = (ns.userInfo["ErrorString"] as? String)
                ?? (ns.userInfo["ErrorBriefMessage"] as? String)
                ?? ns.localizedDescription
            return "\(what): \(detail) (error \(number))."
        }
    }

    /// sdef property name (ScriptingBridge's camel-case spelling) → value. Strings, integers and
    /// one boolean; ScriptingBridge converts each by the sdef's declared type.
    static func propertyWrites(for p: TagPatch) -> [(String, Any)] {
        var writes: [(String, Any)] = []
        if let v = p.title { writes.append(("name", v)) }
        if let v = p.artist { writes.append(("artist", v)) }
        if let v = p.album { writes.append(("album", v)) }
        if let v = p.albumArtist { writes.append(("albumArtist", v)) }
        if let v = p.composer { writes.append(("composer", v)) }
        if let v = p.genre { writes.append(("genre", v)) }
        if let v = p.grouping { writes.append(("grouping", v)) }
        if let v = p.comments { writes.append(("comment", v)) }
        if let v = p.year { writes.append(("year", NSNumber(value: v))) }
        if let v = p.trackNumber { writes.append(("trackNumber", NSNumber(value: v))) }
        if let v = p.trackCount { writes.append(("trackCount", NSNumber(value: v))) }
        if let v = p.discNumber { writes.append(("discNumber", NSNumber(value: v))) }
        if let v = p.discCount { writes.append(("discCount", NSNumber(value: v))) }
        if let v = p.bpm { writes.append(("bpm", NSNumber(value: v))) }
        if let v = p.isCompilation { writes.append(("compilation", NSNumber(value: v))) }
        return writes
    }
}
