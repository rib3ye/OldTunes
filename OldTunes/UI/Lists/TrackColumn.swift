import AppKit

/// The track list's columns. Raw values are the NSTableColumn identifiers and the keys stored in
/// UserDefaults, so never rename one.
enum TrackColumn: String, CaseIterable, Sendable {
    case indicator, name, time, artist, album, genre, dateAdded, year, plays

    var title: String {
        switch self {
        case .indicator: ""
        case .name: "Name"
        case .time: "Time"
        case .artist: "Artist"
        case .album: "Album"
        case .genre: "Genre"
        case .dateAdded: "Date Added"
        case .year: "Year"
        case .plays: "Plays"
        }
    }

    /// The seven default columns fit a ~780 pt track pane without a horizontal scroll; narrower
    /// windows scroll, as iTunes did. Name is widest; Time is just wide enough for h:mm:ss.
    var defaultWidth: CGFloat {
        switch self {
        case .indicator: Self.indicatorWidth
        case .name: 220
        case .time: 52
        case .artist: 150
        case .album: 140
        case .genre: 90
        case .dateAdded: 84
        case .year: 40
        case .plays: 42
        }
    }

    /// The NSTableColumn width that makes the indicator column take §7.2's 18 pt (x 186..203, its
    /// separator line included): NSTableView adds the 3 pt intercell spacing to every column.
    static let indicatorWidth = Theme.Metrics.indicatorColumnWidth - Theme.Metrics.intercellSpacing.width

    /// Name must keep room for its checkbox, a few letters and the cloud badge.
    var minWidth: CGFloat {
        switch self {
        case .indicator: Self.indicatorWidth
        case .name: 50
        default: 30
        }
    }

    var alignment: NSTextAlignment {
        switch self {
        case .time, .year, .plays: .right
        default: .left
        }
    }

    var sortField: TrackSortField? {
        switch self {
        case .indicator: nil
        case .name: .name
        case .time: .time
        case .artist: .artist
        case .album: .album
        case .genre: .genre
        case .dateAdded: .dateAdded
        case .year: .year
        case .plays: .playCount
        }
    }

    /// Year and Plays are offered in the header menu but start hidden.
    var hiddenByDefault: Bool { self == .year || self == .plays }
    /// The indicator and Name are always shown (Name is how you know what a row is).
    var isHideable: Bool { self != .indicator && self != .name }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    @MainActor init?(_ column: NSTableColumn) { self.init(rawValue: column.identifier.rawValue) }

    /// First click on a new column: newest/most-played first for dates and counts, A→Z otherwise.
    var defaultAscending: Bool { !(self == .dateAdded || self == .plays) }
}

/// Saves and restores column order, widths and visibility in UserDefaults.
struct TrackColumnLayout: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var width: Double
        var hidden: Bool
    }
    var entries: [Entry]

    static let defaultsKey = "OldTunes.TrackList.columns"

    static var standard: TrackColumnLayout {
        TrackColumnLayout(entries: TrackColumn.allCases.map {
            Entry(id: $0.rawValue, width: Double($0.defaultWidth), hidden: $0.hiddenByDefault)
        })
    }

    /// The saved layout, with any column added since it was saved appended in its default state
    /// and anything unknown dropped, so an old save never loses or invents a column.
    static func load(from defaults: UserDefaults = .standard) -> TrackColumnLayout {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(TrackColumnLayout.self, from: data) else { return .standard }
        var entries = saved.entries.filter { TrackColumn(rawValue: $0.id) != nil }
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.id).inserted }
        for column in TrackColumn.allCases where !seen.contains(column.rawValue) {
            entries.append(Entry(id: column.rawValue, width: Double(column.defaultWidth), hidden: column.hiddenByDefault))
        }
        // The indicator column is pinned first; Name can never be hidden.
        if let i = entries.firstIndex(where: { $0.id == TrackColumn.indicator.rawValue }), i != 0 {
            entries.insert(entries.remove(at: i), at: 0)
        }
        for i in entries.indices where !(TrackColumn(rawValue: entries[i].id)?.isHideable ?? true) {
            entries[i].hidden = false
        }
        return TrackColumnLayout(entries: entries)
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Reads the live state of a table's columns, in display order.
    @MainActor
    init(table: NSTableView) {
        entries = table.tableColumns.map {
            Entry(id: $0.identifier.rawValue, width: Double($0.width), hidden: $0.isHidden)
        }
    }

    init(entries: [Entry]) { self.entries = entries }
}
