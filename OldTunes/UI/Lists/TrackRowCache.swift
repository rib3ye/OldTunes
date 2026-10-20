import Foundation

/// The rows the track list has fetched, by id, bounded so memory never grows with the library.
///
/// The table only ever draws a screenful plus a margin, so a few thousand rows covers scrolling
/// back and forth without refetching. Eviction is "least recently touched": every hit stamps the
/// entry, and when the cache runs a quarter over capacity the oldest stamps are dropped in one
/// pass. That keeps a hit O(1) with no linked list to maintain.
struct TrackRowCache {
    let capacity: Int
    private var entries: [Track.ID: (track: Track, stamp: UInt64)] = [:]
    private var clock: UInt64 = 0
    private(set) var evictions = 0

    init(capacity: Int = 3_000) {
        self.capacity = max(capacity, 1)
        entries.reserveCapacity(capacity + capacity / 4 + 1)
    }

    var count: Int { entries.count }

    func contains(_ id: Track.ID) -> Bool { entries[id] != nil }

    /// A hit counts as a use.
    mutating func track(_ id: Track.ID) -> Track? {
        guard var entry = entries[id] else { return nil }
        clock &+= 1
        entry.stamp = clock
        entries[id] = entry
        return entry.track
    }

    /// Looks without counting as a use (context menus, logging).
    func peek(_ id: Track.ID) -> Track? { entries[id]?.track }

    mutating func insert(_ tracks: [Track]) {
        for track in tracks {
            clock &+= 1
            entries[track.id] = (track, clock)
        }
        if entries.count > capacity + capacity / 4 { evict() }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    mutating func remove(_ ids: some Sequence<Track.ID>) {
        for id in ids { entries[id] = nil }
    }

    /// Changes the cached copies of `ids` in place; ids not cached are skipped. Not a use.
    mutating func modify(_ ids: some Sequence<Track.ID>, _ change: (inout Track) -> Void) {
        for id in ids {
            guard var entry = entries[id] else { continue }
            change(&entry.track)
            entries[id] = entry
        }
    }

    /// Every cached row, oldest use first, so inserting them elsewhere keeps their recency order.
    var tracks: [Track] {
        entries.values.sorted { $0.stamp < $1.stamp }.map(\.track)
    }

    private mutating func evict() {
        let excess = entries.count - capacity
        guard excess > 0 else { return }
        let oldest = entries.sorted { $0.value.stamp < $1.value.stamp }.prefix(excess).map(\.key)
        for id in oldest { entries[id] = nil }
        evictions += oldest.count
    }
}
