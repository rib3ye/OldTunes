import AppKit
import iTunesLibrary
import MusicKit

/// OLDTUNES_HARNESS=authcheck — proves the app can see the library, and asks for permission if
/// it has never been asked. Logs the numbers RESEARCH.md §9 milestone 1 expects, then quits.
@MainActor
enum AuthCheck {
    static func run() async {
        let plistKey = Bundle.main.object(forInfoDictionaryKey: "NSAppleMusicUsageDescription") != nil
        Log.info("authcheck: bundle=\(Bundle.main.bundleIdentifier ?? "?") usageKeyInBuiltPlist=\(plistKey)")

        var status = MusicAuthorization.currentStatus
        Log.info("authcheck: MusicAuthorization before=\(status)")
        if status == .notDetermined {
            status = await MusicAuthorization.request()
            Log.info("authcheck: MusicAuthorization after request=\(status)")
        }

        let lib = await Task.detached { () -> String in
            do {
                let library = try ITLibrary(apiVersion: "1.0", options: .lazyLoadData)
                let start = Date()
                let items = library.allMediaItems
                let songs = items.filter { $0.mediaKind == .kindSong }
                let files = songs.filter { $0.locationType == .file }.count
                let remote = songs.filter { $0.locationType == .remote }.count
                let cloud = songs.filter { $0.isCloud }.count
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                return "items=\(items.count) songs=\(songs.count) file=\(files) remote=\(remote) isCloud=\(cloud) " +
                       "mediaFolder=\(library.mediaFolderLocation?.path ?? "nil") loadMs=\(ms)"
            } catch {
                return "ITLibrary error: \(error)"
            }
        }.value
        Log.info("authcheck: iTunesLibrary \(lib)")

        guard status == .authorized else {
            Log.error("authcheck: MusicKit not authorized (\(status)); skipping MusicKit checks")
            return
        }
        do {
            let sub = try await withTimeout(5) { try await MusicSubscription.current }
            Log.info("authcheck: subscription canPlayCatalog=\(sub.canPlayCatalogContent) " +
                     "cloudLibrary=\(sub.hasCloudLibraryEnabled) canBecomeSubscriber=\(sub.canBecomeSubscriber)")
        } catch {
            Log.error("authcheck: subscription \(error)")
        }
        do {
            let start = Date()
            let count = try await withTimeout(30) { () -> Int in
                var request = MusicLibraryRequest<Song>()
                request.limit = 50_000
                return try await request.response().items.count
            }
            Log.info("authcheck: MusicLibraryRequest<Song> count=\(count) ms=\(Int(Date().timeIntervalSince(start) * 1000))")
        } catch {
            Log.error("authcheck: MusicLibraryRequest \(error)")
        }
    }
}
