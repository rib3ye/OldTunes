import Foundation
import MusicKit

/// What one transport can play. Chosen per track at play time by the §1 fallback chain
/// (docs/RESEARCH.md §1), never stored, because a file can disappear between two plays.
enum Playable: Sendable {
    case local(URL)
    /// A MusicKit library or catalog song. `Song` is Sendable, so this crosses actors freely.
    case cloud(Song)
}

enum TransportError: LocalizedError {
    /// The coordinator handed a transport the other transport's kind of `Playable`.
    case unsupported
    /// The audio could not be opened or prepared.
    case notPlayable
    /// The file is a protected (FairPlay) download: Apple Music songs come down that way, and
    /// so can others the Music app downloads at Lossless. AVFoundation can't play one; the Music
    /// app can.
    case protected

    var errorDescription: String? {
        switch self {
        case .unsupported: "This song can't be played by this player."
        case .notPlayable: "This song could not be opened."
        case .protected: "This song is a protected download, which only the Music app can play."
        }
    }
}

/// One audio engine. The coordinator owns two (AVFoundation for files, MusicKit for the cloud)
/// and drives whichever is active; transports never decide what plays next.
///
/// Main-actor confined because `ApplicationMusicPlayer` is not Sendable and carries no isolation
/// annotations at all, so the compiler cannot catch a background touch (RESEARCH.md §5.1).
@MainActor
protocol Transport: AnyObject {
    func load(_ what: Playable) async throws
    func play() async throws
    func pause()
    /// Silences and releases the loaded item. Must be called on the inactive transport before
    /// the active one loads, or two streams play at once.
    func stop()
    func seek(to seconds: TimeInterval)

    /// Polled by `PlaybackClock` at 10 Hz. Neither engine offers a usable observer for it.
    var position: TimeInterval { get }
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    /// 0...1
    var volume: Float { get set }

    /// Fired once when the loaded item plays to its natural end. Not fired by stop() or load().
    var onFinish: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    /// Called by the coordinator on every clock tick while this transport is active. MusicKit
    /// has no end-of-item callback, so the cloud transport detects the end here.
    func clockDidTick()
}

extension Transport {
    func clockDidTick() {}
}
