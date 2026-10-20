/// The shuffle order for a queue. Done in Swift rather than with MusicKit's shuffle because the
/// queue spans both engines and MusicKit only ever sees one song (RESEARCH.md §5.4).
enum Shuffle {
    static func permutation<T: Equatable>(of items: [T], first: T?) -> [T] {
        var rng = SystemRandomNumberGenerator()
        return permutation(of: items, first: first, using: &rng)
    }

    /// A uniform Fisher–Yates permutation. When `first` is in `items` it is pinned to the front,
    /// so turning shuffle on (or double-clicking a song) never interrupts the song that's playing.
    static func permutation<T: Equatable, G: RandomNumberGenerator>(of items: [T], first: T?,
                                                                     using rng: inout G) -> [T] {
        var result = items
        var start = 0
        if let first, let k = result.firstIndex(of: first) {
            result.swapAt(0, k)
            start = 1
        }
        var i = result.count - 1
        while i > start {
            let j = Int.random(in: start...i, using: &rng)
            result.swapAt(i, j)
            i -= 1
        }
        return result
    }
}
