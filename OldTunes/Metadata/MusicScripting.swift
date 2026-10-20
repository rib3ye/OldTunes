import AppKit
import ScriptingBridge

// Music.app's scripting dictionary, declared by hand because the project has no bridging header
// for an sdp-generated Music.h. Only element accessors and the commands `add`, `delete`, `move`
// and `duplicate` are declared; properties go through KVC by their sdef names so there is one
// table of keys (see `MusicScriptingSession`). Every member is optional: ScriptingBridge builds
// these methods at runtime from the sdef, and an optional requirement turns a missing one into
// nil instead of a crash. Optional members are only callable through the protocol type, hence
// the `as …Scripting` casts at each call.

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
/// queue (`MusicAppTagWriter`, `MusicAppLibraryAdder`, `MusicPlaylistEditor`).
///
/// Property reads and writes, `add`, `delete` (artwork, playlists, and the live hand-off check's
/// own test song), and `make` (a plain Apple Event), `move` and `duplicate` for playlists only.
/// This type deliberately has no way to send play, pause, next track or any other playback
/// command (§6.5): Music answering those would take over Now Playing.
final class MusicScriptingSession {
    /// What the conversation is for, so a refusal names the right consequence.
    enum Purpose {
        case savingTags
        case addingSongs
        case editingPlaylists

        var deniedReason: String {
            switch self {
            case .savingTags: MusicAutomation.deniedReason
            case .addingSongs: MusicAutomation.addDeniedReason
            case .editingPlaylists: MusicAutomation.playlistDeniedReason
            }
        }

        var unavailableReason: String {
            switch self {
            case .savingTags: MusicAutomation.unavailableReason
            case .addingSongs: MusicAutomation.addUnavailableReason
            case .editingPlaylists: MusicAutomation.playlistUnavailableReason
            }
        }

        /// What errAENoSuchObject means here.
        var missingReason: String {
            self == .editingPlaylists ? "Music couldn’t find the playlist. It may have been deleted already."
                : "Music couldn’t find the song. It may have been removed from the library."
        }
    }

    private let app: SBApplication
    private let errors = ScriptingErrorRecorder()
    private let purpose: Purpose

    init(for purpose: Purpose = .savingTags) throws {
        guard let app = SBApplication(bundleIdentifier: MusicAutomation.bundleID) else {
            throw TagEditError(message: purpose.unavailableReason, code: -600)
        }
        app.delegate = errors
        // If Music quit after `launchHiddenIfNeeded`, ScriptingBridge relaunches it for the next
        // event; make that launch hidden and in the background too.
        app.launchFlags = [.dontAddToRecents, .dontSwitch, .andHide]
        // Ticks (1/60 s). A whose-query over 16k tracks is fast; 20 s means Music is stuck. An add
        // may wait on Music copying a long file into its Media folder, so it gets a minute.
        app.timeout = (purpose == .addingSongs ? 60 : 20) * 60
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

    /// Errors after which nothing more should be sent: OldTunes lost permission, Music stopped
    /// answering, Music is gone, or it doesn't handle the command at all. Any other error is
    /// about the one request.
    static func endsConversation(_ code: Int?) -> Bool {
        [-1743, -1712, -600, -609, -1708].contains(code)   // -1708: errAEEventNotHandled
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
        let matches = tracks.filtered(using: NSPredicate(format: "persistentID == %@", hex))
        try check("Music couldn’t look up the song \(hex)")
        guard let track = matches.first as? SBObject else {
            throw TagEditError(message: "Music has no song with this ID (\(hex)). It may have been removed from the library.")
        }
        return track
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
    func playlist(persistentID: Int64) throws -> SBObject {
        let hex = MusicPersistentID.hex(persistentID)
        _ = errors.take()
        guard let library = try librarySource(),
              let playlists = (library as MusicSourceScripting).playlists?() else {
            try check("Music’s playlists couldn’t be read")
            throw TagEditError(message: "Music’s playlists couldn’t be read.")
        }
        // `first` sends the lookup, so a timeout is reported as itself, not as a missing playlist.
        let match = playlists.filtered(using: NSPredicate(format: "persistentID == %@", hex)).first as? SBObject
        try check("Music couldn’t look up the playlist \(hex)")
        guard let playlist = match else {
            throw TagEditError(message: "Music has no playlist with this ID (\(hex)). It may have been deleted already.")
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
        guard let made = try send(make, what).paramDescriptor(forKeyword: Self.directObject) else {
            throw TagEditError(message: "\(what): Music didn’t say what it made.")
        }
        // persistent ID of <what Music made>
        let property = NSAppleEventDescriptor.record()
        property.setDescriptor(NSAppleEventDescriptor(typeCode: 0x7072_6F70), forKeyword: 0x7761_6E74)  // want: prop
        property.setDescriptor(made, forKeyword: 0x6672_6F6D)                                           // from
        property.setDescriptor(NSAppleEventDescriptor(enumCode: 0x7072_6F70), forKeyword: 0x666F_726D)  // form: prop
        property.setDescriptor(NSAppleEventDescriptor(typeCode: 0x7050_4953), forKeyword: 0x7365_6C64)  // seld: pPIS
        let get = Self.coreEvent(0x6765_7464)                                                           // getd
        get.setParam(property.coerce(toDescriptorType: 0x6F62_6A20) ?? property, forKeyword: Self.directObject)  // obj
        let hex = try send(get, "Music couldn’t read the new playlist’s ID")
            .paramDescriptor(forKeyword: Self.directObject)?.stringValue
        guard let id = hex.flatMap(MusicPersistentID.bitPattern(fromHex:)) else {
            throw TagEditError(message: "Music made “\(name)” but didn’t say which one it is. It appears in a few seconds.")
        }
        return id
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

    /// Music deletes a folder together with every playlist in it.
    func deletePlaylist(_ playlist: SBObject) throws {
        _ = errors.take()
        guard let delete = (playlist as MusicItemScripting).delete else {
            throw TagEditError(message: "Music’s scripting dictionary has no “delete” command.", code: -1708)
        }
        delete()
        try check("Music couldn’t delete the playlist")
    }

    func name(of item: SBObject, failure: String = "Music couldn’t read the song’s name") throws -> String? {
        try requireProperty("name", on: item)
        let name = item.value(forKey: "name") as? String
        try check(failure)
        return name
    }

    /// Where a file track's file is (inside Music's Media folder, if Music copied it there).
    func location(of track: SBObject) throws -> URL? {
        try requireProperty("location", on: track)
        let url = track.value(forKey: "location") as? URL
        try check("Music couldn’t read where the song’s file is")
        return url
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

    /// Throws the error ScriptingBridge reported since the last check, if any.
    private func check(_ what: String) throws {
        guard let error = errors.take() else { return }
        throw TagEditError(message: Self.describe(error, what: what, purpose: purpose), code: Self.number(of: error))
    }

    /// The Apple Event error number in a ScriptingBridge error.
    static func number(of error: Error) -> Int {
        let ns = error as NSError
        return (ns.userInfo["ErrorNumber"] as? NSNumber)?.intValue ?? ns.code
    }

    /// One sentence for the per-song failure list. The few codes a user can act on get their
    /// own wording; anything else keeps Music's own description and number.
    static func describe(_ error: Error, what: String, purpose: Purpose = .savingTags) -> String {
        let ns = error as NSError
        let number = Self.number(of: error)
        switch number {
        case -1743:   // errAEEventNotPermitted
            return purpose.deniedReason
        case -1712:   // errAETimeout
            return "\(what): Music didn’t answer in time. Try again when Music isn’t busy."
        case -1728:   // errAENoSuchObject
            return "\(what): \(purpose.missingReason)"
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
