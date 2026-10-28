import Foundation

/// Which added folders OldTunes may open. In the App Sandbox a path alone opens nothing outside
/// ~/Music: the right to read and write a folder comes with the URL the Add Folder panel hands
/// back, and lasts only until OldTunes quits. Kept as a security-scoped bookmark, it is opened
/// again at every launch (RESEARCH.md §3.1).
///
/// A folder added before OldTunes was sandboxed has no bookmark. Outside ~/Music its songs show
/// as missing, and inside ~/Music they play but Get Info can't save their tags, until the user
/// chooses the folder once more (AppController.askForFolderAccess).
@MainActor
enum FolderAccess {
    /// Bookmark data by folder path, the path AppController remembers the folder under.
    static let bookmarksKey = "OldTunes.folderBookmarks"

    /// The folders open this run. Never closed: OldTunes plays and edits their songs until it quits.
    private static var opened: [String: URL] = [:]

    /// Keeps a folder the user just chose, under `path` (the folder itself, or one inside it that
    /// the user chose again by picking a folder around it). `url` must be the panel's URL, which
    /// carries the grant.
    static func remember(_ url: URL, as path: String? = nil) {
        let path = path ?? url.path
        do {
            // A read-write bookmark can't be made on a read-only volume (a disc, a locked share).
            let data = try (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
                ?? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = saved
            bookmarks[path] = data
            UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
            opened[path] = url
        } catch {
            Log.error("folder access: \(path) will need choosing again next launch, no bookmark: \(error)")
        }
    }

    /// Opens every kept folder. Await it at launch, before anything reads an added folder.
    /// Finding a folder on its volume can take a while, so that happens off the main thread.
    static func openKept() async {
        let kept = saved.filter { opened[$0.key] == nil }
        guard !kept.isEmpty else { return }
        var bookmarks = saved
        for folder in await resolve(kept) {
            opened[folder.path] = folder.url
            if let fresh = folder.freshBookmark { bookmarks[folder.path] = fresh }
        }
        UserDefaults.standard.set(bookmarks, forKey: bookmarksKey)
        Log.info("folder access: \(opened.count) of \(bookmarks.count) kept folders open")
    }

    private struct Resolved: Sendable {
        var path: String
        var url: URL
        /// A replacement for a stale bookmark.
        var freshBookmark: Data?
    }

    @concurrent
    nonisolated private static func resolve(_ kept: [String: Data]) async -> [Resolved] {
        var resolved: [Resolved] = []
        for (path, data) in kept {
            var stale = false
            let url: URL
            do {
                // Never a dialog or a network mount at launch: a folder on a drive that isn't
                // there just stays shut, and its songs show as missing until the next launch.
                url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                Log.error("folder access: \(path)'s bookmark no longer opens it: \(error)")
                continue
            }
            guard url.startAccessingSecurityScopedResource() else {
                Log.error("folder access: macOS refused \(path)'s bookmark")
                continue
            }
            // A folder chosen again by picking one around it keeps that folder's bookmark.
            let inside = url.path == path || path.hasPrefix(url.path.hasSuffix("/") ? url.path : url.path + "/")
            if !inside { Log.info("folder access: \(path) has moved to \(url.path)") }
            // A bookmark goes stale when the folder moves or its volume changes; macOS says to
            // replace it while the folder is open.
            let fresh = stale ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                       relativeTo: nil) : nil
            resolved.append(Resolved(path: path, url: url, freshBookmark: fresh))
        }
        return resolved
    }

    /// Added folders OldTunes can't fully use: added before it was sandboxed, or their bookmark
    /// stopped working.
    struct Shut: Sendable {
        /// Can't be read: their songs show as missing.
        var unreadable: [String] = []
        /// Can be read but not written: their songs play, but Get Info can't save their tags.
        /// A folder in ~/Music added before the sandbox is one, since OldTunes may only read ~/Music.
        var readOnly: [String] = []
        var all: [String] { unreadable + readOnly }
    }

    /// Which of `paths` OldTunes can't fully use. The checks wait on each folder's volume, so they
    /// run off the main thread.
    static func shut(among paths: [String]) async -> Shut {
        await sort(paths.filter { opened[$0] == nil })
    }

    @concurrent
    nonisolated private static func sort(_ paths: [String]) async -> Shut {
        let fm = FileManager.default
        var shut = Shut()
        for path in paths where isThere(path) {
            if !fm.isReadableFile(atPath: path) {
                shut.unreadable.append(path)
            } else if !fm.isWritableFile(atPath: path) {
                shut.readOnly.append(path)
            }
        }
        return shut
    }

    /// False only when the folder is gone (an unplugged drive), since there is nothing to choose
    /// then. The sandbox may refuse even a look at a folder it hasn't been given, and that folder
    /// is there.
    nonisolated private static func isThere(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 || errno != ENOENT
    }

    private static var saved: [String: Data] {
        UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
    }
}
