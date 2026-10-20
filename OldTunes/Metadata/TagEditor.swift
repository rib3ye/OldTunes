import Foundation

/// Reads and writes song information along the two paths of RESEARCH.md §6, chosen by where the
/// song came from (`route(for:)`):
///
/// - A song in Music's library is saved through Music.app — also when it has a file on this
///   Mac. Music owns that song's information: it updates its own database and writes the tags
///   into the file itself, so the next ingest reads the edit back. Writing the file directly
///   would leave Music's database on the old values, and the next ingest (every launch, and 5 s
///   after any Music change) would put them back in the list.
/// - A song added from a folder is OldTunes' own, so its file is written through SFBAudioEngine
///   with an atomic swap; the folder rescan reads the new tags back.
///
/// An actor because SFBAudioEngine's objects are not Sendable and file writes to the same song
/// must not interleave; one edit at a time is also what a Get Info sheet produces.
actor TagEditor: TagEditing {
    /// Where one song's edits are saved.
    enum Route: Sendable, Equatable {
        /// An added-folder song whose file is on this Mac: written directly.
        case file(URL)
        /// A Music-library song, with or without a file here: saved through Music by persistent ID.
        case music(Int64)
        /// Nowhere it can be saved; the reason is shown to the user.
        case unavailable(String)
    }

    private let cloud: any CloudTagWriting

    init() {
        self.cloud = MusicAppTagWriter()
    }

    /// For the harness: routes Music-library edits somewhere other than Music.app.
    init(cloud: any CloudTagWriting) {
        self.cloud = cloud
    }

    /// The one routing rule, shared by `apply`, `readFields` and the Get Info prompts.
    static func route(for track: Track) -> Route {
        switch track.origin {
        case .musicLibrary:
            if let pid = track.persistentID { return .music(pid) }
            return .unavailable("This song isn’t linked to a song in your Music library, so its information can’t be saved.")
        case .folder:
            if let url = existingFile(of: track) { return .file(url) }
            if let url = track.fileURL {
                return .unavailable("The file “\(url.lastPathComponent)” could not be found.")
            }
            return .unavailable("This song has no file on this Mac and isn’t in your Music library, so its information can’t be changed.")
        }
    }

    func readFields(of track: Track) async throws -> TagFields {
        if case .file(let url) = Self.route(for: track) {
            return try FileTagIO.readFields(at: url)
        }
        // A Music-library song: the index holds what Music's library holds, which is what the
        // list shows and what a save through Music changes. The file's own tags can differ from
        // Music's, and asking Music would cost an Apple Event (and possibly a permission prompt)
        // just to open the sheet.
        return TagFields(track: track)
    }

    func apply(_ patch: TagPatch, to tracks: [Track]) async -> TagApplyResult {
        var result = TagApplyResult()
        guard !patch.isEmpty else {
            result.succeeded = tracks.map(\.id)
            return result
        }

        // Asked once per batch, and only if a Music-library song is actually in it.
        var cloudStatus: MusicAutomationStatus?

        for track in tracks {
            let pid: Int64
            switch Self.route(for: track) {
            case .file(let url):
                do {
                    try FileTagIO.write(patch, to: url)
                    result.succeeded.append(track.id)
                    Log.info("metadata: wrote \(patch.changedFieldNames.joined(separator: ",")) to file id=\(track.id)")
                } catch {
                    let reason = FileTagIO.reason(for: error, url: url)
                    result.failed.append(.init(id: track.id, reason: reason))
                    Log.error("metadata: file write failed id=\(track.id): \(reason)")
                }
                continue
            case .unavailable(let reason):
                result.failed.append(.init(id: track.id, reason: reason))
                Log.error("metadata: nowhere to save id=\(track.id): \(reason)")
                continue
            case .music(let id):
                pid = id
            }

            if cloudStatus == nil { cloudStatus = await resolveCloudPermission() }
            switch cloudStatus {
            case .granted:
                do {
                    try await cloud.apply(patch, persistentID: pid)
                    result.succeeded.append(track.id)
                    Log.info("metadata: Music saved \(patch.changedFieldNames.joined(separator: ",")) for id=\(track.id)")
                } catch {
                    result.failed.append(.init(id: track.id, reason: error.localizedDescription))
                    Log.error("metadata: Music write failed id=\(track.id): \(error.localizedDescription)")
                }
            case .denied, .undetermined:
                result.failed.append(.init(id: track.id, reason: MusicAutomation.deniedReason))
            case .musicUnavailable:
                result.failed.append(.init(id: track.id, reason: MusicAutomation.unavailableReason))
            case .failed(let status):
                result.failed.append(.init(id: track.id,
                    reason: "OldTunes couldn’t check its permission to control Music (error \(status))."))
            case nil:
                break
            }
        }
        return result
    }

    /// The Get Info window explains the prompt before this runs (§6.5), so asking here is the
    /// "then ask" half. A caller without a UI still gets the system prompt, which carries the
    /// Info.plist's NSAppleEventsUsageDescription.
    private func resolveCloudPermission() async -> MusicAutomationStatus {
        let status = await cloud.permission(askIfNeeded: false)
        guard status == .undetermined else { return status }
        return await cloud.permission(askIfNeeded: true)
    }

    /// The track's file, if it is on disk right now.
    static func existingFile(of track: Track) -> URL? {
        guard let url = track.fileURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
