import Foundation

/// The 80 standard ID3v1 genres. Older MP3s store genre as "(17)" and iTunes-encoded AAC files
/// store standard genres as a numeric `gnre` atom, so both need this table to show a name.
enum ID3Genres {
    private static let names = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge", "Hip-Hop", "Jazz", "Metal",
        "New Age", "Oldies", "Other", "Pop", "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial",
        "Alternative", "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient", "Trip-Hop",
        "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical", "Instrumental", "Acid", "House", "Game",
        "Sound Clip", "Gospel", "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic", "Darkwave", "Techno-Industrial",
        "Electronic", "Pop-Folk", "Eurodance", "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta",
        "Top 40", "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret", "New Wave",
        "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi", "Tribal", "Acid Punk", "Acid Jazz",
        "Polka", "Retro", "Musical", "Rock & Roll", "Hard Rock",
    ]

    static func name(at index: Int) -> String? {
        names.indices.contains(index) ? names[index] : nil
    }

    /// "(17)" → "Rock", "(17)Rock" → "Rock", "17" → "Rock", anything else unchanged.
    static func resolve(_ text: String) -> String {
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            let rest = text[text.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
            let number = text[text.index(after: text.startIndex)..<close]
            return Int(number).flatMap(name(at:)) ?? text
        }
        return Int(text).flatMap(name(at:)) ?? text
    }
}
