import Foundation

/// Turns search-field text into FTS5 MATCH strings (RESEARCH.md §4.4).
///
/// Routing is per token, which for one-word input is exactly §4.4's length routing: a token of
/// 3+ characters goes to the trigram table (matches mid-word), a shorter one to the prefix table
/// (trigram cannot match under 3 characters). Tokens are AND-ed, across both tables.
///
/// Every token is wrapped in double quotes with internal quotes doubled, which turns all FTS5
/// syntax (`*`, `-`, `:`, `NEAR`, `AND`, parentheses) into literal text. Prefix tokens are further
/// split on non-alphanumerics, because the prefix table's `detail=column` rejects multi-token
/// phrases with an error, and unicode61 would split `ac/dc` into two tokens inside one phrase.
struct SearchPattern: Equatable {
    /// For `song_tri`; nil when no token is 3+ characters.
    var trigram: String?
    /// For `song_fts`; nil when no token is short.
    var prefix: String?

    /// True when the text was blank: no filtering at all.
    var isBlank: Bool
    /// True when the text was not blank but nothing in it is searchable (for example a lone
    /// "*"): the result is empty, not the whole library.
    var matchesNothing: Bool { !isBlank && trigram == nil && prefix == nil }

    init(_ text: String) {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        isBlank = tokens.isEmpty
        var long: [String] = []
        var short: [String] = []
        for token in tokens {
            if token.count >= 3 {
                long.append(Self.quoted(token))
            } else {
                let runs = token.split { !($0.isLetter || $0.isNumber) }
                short.append(contentsOf: runs.map { Self.quoted(String($0)) + "*" })
            }
        }
        trigram = long.isEmpty ? nil : long.joined(separator: " ")
        prefix = short.isEmpty ? nil : short.joined(separator: " ")
    }

    private static func quoted(_ token: String) -> String {
        "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
