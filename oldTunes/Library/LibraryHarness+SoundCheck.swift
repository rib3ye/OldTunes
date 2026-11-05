import Foundation
import GRDB

/// Sound Check values (schema v4): the index holds Music's value for every song, and an index
/// written before v4 gets them on its next ingest.
extension LibraryHarnessBench {
    func checkSoundCheck() async throws {
        let music = try await ingest.itlib.musicSoundCheckEnergies()
        let stored = try await soundCheckColumn()
        let differ = music.filter { stored[$0.key] != $0.value }
        let measured = music.values.filter { $0 > 0 }
        let gains = measured.map { SoundCheck.decibels(energy: $0) }
        check("sound_check_energy holds Music's Sound Check value for every song",
              !music.isEmpty && stored.count == music.count && differ.isEmpty && !measured.isEmpty,
              "\(stored.count) rows, \(music.count) songs in Music, \(differ.count) differ; \(measured.count) measured, " +
              "\(measured.filter { $0 < 1000 }.count) made louder; gains from \(fmt(gains.min() ?? 0)) to \(fmt(gains.max() ?? 0)) dB")

        // What a v3 index looks like once v4 has added the column: every value 0, and every stored
        // hash made without it (0 stands in for "a different hash").
        try await index.pool.write { db in
            try db.execute(sql: "UPDATE song SET sound_check_energy = 0, content_hash = 0 WHERE origin = 0")
        }
        let report = await ingest.refresh()
        let after = try await soundCheckColumn()
        let still = music.filter { after[$0.key] != $0.value }
        check("an index from before v4 gets every Sound Check value on the next ingest",
              report.status == .ok && after.count == music.count && still.isEmpty,
              "\(still.count) of \(after.count) rows still differ after the re-ingest")
    }

    private func soundCheckColumn() async throws -> [Int64: Int] {
        try await index.pool.read { db in
            var out: [Int64: Int] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT persistent_id, sound_check_energy FROM song WHERE origin = 0") {
                out[row[0]] = row[1]
            }
            return out
        }
    }
}
