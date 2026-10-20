import Foundation

/// Builds the strings we sort on, so sorting 50,000 rows is a plain indexed byte compare.
///
/// Matches how iTunes ordered things:
/// - ignores case, accents, and full-width forms ("Björk" sorts with "Bjork")
/// - ignores a leading "The ", "A ", or "An " ("The Beatles" sorts under B)
/// - ignores leading punctuation ("'Round Midnight" sorts under R)
/// - compares digit runs as numbers ("Track 2" before "Track 10")
/// - puts blank values last
enum SortKey {
    private static let articles = ["the ", "a ", "an "]
    /// Digit runs are left-padded to this width. Eight digits covers years, track numbers, catalog numbers.
    private static let digitWidth = 8
    /// Sorts after every real key under a binary compare.
    static let blank = "\u{10FFFF}"

    static func make(_ raw: String) -> String {
        var s = raw.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return blank }

        for article in articles where s.hasPrefix(article) && s.count > article.count {
            s.removeFirst(article.count)
            break
        }

        let stripped = s.drop(while: { !$0.isLetter && !$0.isNumber })
        if !stripped.isEmpty { s = String(stripped) }

        return padDigitRuns(s)
    }

    private static func padDigitRuns(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            if run.count < digitWidth { out += String(repeating: "0", count: digitWidth - run.count) }
            out += run
            run = ""
        }
        for ch in s {
            if ch.isASCII && ch.isNumber { run.append(ch) } else { flush(); out.append(ch) }
        }
        flush()
        return out
    }
}
