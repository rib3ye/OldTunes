import Foundation

/// Music's Sound Check: every song played at the level Music measured for it, so a quiet song
/// and a loud one come out about equally loud.
///
/// Music keeps its measurement per song, and the iTunes Library framework hands it over as
/// `volumeNormalizationEnergy` (0 when Music has none). The gain Music applies is
/// −20·log10(energy / 1000) dB. That was measured on October 20, 2026 with a process tap on Music's
/// own output: it matched the gap between Music and OldTunes to 0.01 dB on a file and on an iCloud
/// song (−7.64 and −7.34 dB). The −10·log10 that iTunes' iTunNORM tags use predicts half the gap,
/// so this value is not an iTunNORM number. As a factor, −20·log10(energy / 1000) dB is just
/// 1000 / energy.
///
/// A file gets it through an audio processing tap before AVPlayer's volume (LocalSoundCheck).
/// An iCloud song plays in Apple's RemotePlayerService process, which applies no Sound Check and
/// MusicKit gives no volume for, so CloudVolume sets that process's level to OldTunes's volume
/// times the gain. That level goes no higher than full, so there a boost is capped.
enum SoundCheck {
    /// The gain for a song as a factor on its samples; 1 when Music has no measurement.
    static func gain(energy: Int) -> Float {
        energy > 0 ? Float(1000 / Double(energy)) : 1
    }

    /// The same gain in dB, for logs.
    static func decibels(energy: Int) -> Double {
        energy > 0 ? -20 * log10(Double(energy) / 1000) : 0
    }
}
