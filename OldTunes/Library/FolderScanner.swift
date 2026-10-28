import Darwin
import Foundation

/// Finds the audio files under an added folder and turns them into records (File ▸ Add Folder).
enum FolderScanner {
    /// What AVFoundation can play. `.m4p` (FairPlay) and `.m4b` (audiobooks) are left out on purpose.
    static let playableExtensions: Set<String> = ["mp3", "m4a", "aac", "aif", "aiff", "aifc", "wav", "caf", "flac"]

    struct FileInfo: Sendable, Hashable {
        var path: String
        var size: Int64
        /// Unix seconds.
        var mtime: Int64
    }

    /// The one spelling of a folder the index stores. `realpath` rather than
    /// `URL.resolvingSymlinksInPath`, which strips `/private` and so disagrees with the paths a
    /// directory walk reports: /tmp/x and /private/tmp/x would become two roots and every rescan
    /// would see every file as new.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Whether OldTunes may open `root` (a folder, or a file added on its own). In the sandbox a
    /// folder can be there and still shut to OldTunes (FolderAccess); a walk of it would find
    /// nothing, which a rescan must not read as every file deleted.
    static func canOpen(_ root: String) -> Bool {
        if let directory = opendir(root) {
            closedir(directory)
            return true
        }
        guard errno == ENOTDIR else { return false }
        let fd = open(root, O_RDONLY)
        if fd >= 0 { close(fd) }
        return fd >= 0
    }

    /// What a walk found under a root.
    struct Walk: Sendable {
        var files: [FileInfo] = []
        /// Folders under the root that OldTunes may not open. In the sandbox a folder can be shut
        /// while the one around it opens (inside ~/Music/iTunes/iTunes Media only the Music
        /// folder opens without a grant), and a walk lists nothing under it, with no error.
        var shut: [String] = []
    }

    /// Every playable file under `root` (or `root` itself when it is a file). Paths are built
    /// from `root` plus the walk's relative paths, so they always share the root's spelling.
    /// Synchronous because a directory walk cannot be iterated from an async context.
    static func audioFiles(under root: String) -> Walk {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDirectory) else { return Walk() }
        guard isDirectory.boolValue else {
            let attributes = (try? fm.attributesOfItem(atPath: root)) ?? [:]
            return Walk(files: fileInfo(root, attributes).map { [$0] } ?? [])
        }
        guard let walker = fm.enumerator(atPath: root) else { return Walk() }
        var walk = Walk()
        while let relative = walker.nextObject() as? String {
            let path = (root as NSString).appendingPathComponent(relative)
            let attributes = walker.fileAttributes ?? [:]
            let type = attributes[.type] as? FileAttributeType
            if type == .typeDirectory {
                if (relative as NSString).lastPathComponent.hasPrefix(".") || isPackage(path) {
                    walker.skipDescendants()
                } else if !canOpen(path) {
                    walk.shut.append(path)
                    walker.skipDescendants()
                }
                continue
            }
            guard !(relative as NSString).lastPathComponent.hasPrefix(".") else { continue }
            if let info = fileInfo(path, attributes) { walk.files.append(info) }
        }
        return walk
    }

    private static func fileInfo(_ path: String, _ attributes: [FileAttributeKey: Any]) -> FileInfo? {
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              playableExtensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attributes[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) } ?? 0
        return FileInfo(path: path, size: size, mtime: mtime)
    }

    /// Bundles (an .app, a .logicx project) are opaque to the user, so their insides are skipped.
    private static func isPackage(_ path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
    }

    /// The directory walk, moved off the caller's actor.
    @concurrent
    static func scan(_ root: String) async -> Walk {
        audioFiles(under: root)
    }

    /// Reads tags for many files, a few at a time. AVFoundation's loads are I/O-bound, so a small
    /// amount of parallelism helps without flooding the disk.
    @concurrent
    static func records(for files: [FileInfo], addedAt: Int64) async -> [SongRecord] {
        let width = 8
        return await withTaskGroup(of: SongRecord.self) { group in
            var results: [SongRecord] = []
            results.reserveCapacity(files.count)
            var next = files.makeIterator()
            for _ in 0..<width {
                guard let file = next.next() else { break }
                group.addTask { await AudioFileReader.record(for: file, addedAt: addedAt) }
            }
            while let record = await group.next() {
                results.append(record)
                if let file = next.next() {
                    group.addTask { await AudioFileReader.record(for: file, addedAt: addedAt) }
                }
            }
            return results
        }
    }
}
