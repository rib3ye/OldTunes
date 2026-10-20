import Foundation
import GRDB

/// The index's tables, indexes and triggers: RESEARCH.md §4.2 plus what the merged library needs.
///
/// Departures from the §4.2 DDL, each for a reason:
/// - `id` is AUTOINCREMENT. Without it SQLite reuses the largest freed rowid, so deleting the
///   newest folder file and adding another would hand the UI a stale id pointing at a new song.
/// - `origin` separates Music-library rows from added-folder rows; each ingest touches only its own.
/// - `ix_added` is ascending. The contract's default "Date Added ascending" is oldest-first and the
///   UI reverses it; a DESC index would force a temp b-tree for the ascending query.
/// - `sk_genre` plus indexes for the four extra sortable columns, so every sort is index-driven.
/// - `content_hash` lets a re-ingest write only the rows that changed. Music.app rewrites its
///   library on every play-count bump, and each rewrite triggers a re-ingest.
/// - The FTS triggers are hand-written instead of GRDB's `synchronize(withTable:)`, whose update
///   trigger rewrites both FTS tables for every upserted row on every re-ingest. These fire only
///   when a searchable column actually changed.
///
/// Added in v2:
/// - The per-song checkbox in two columns. `is_checked` is what the source says (Music's
///   `!isUserDisabled`; a folder file has no checkbox, so 1) and is rewritten by every ingest like
///   any other ingested value. `checked_override` is OldTunes' own choice (NULL until the box is
///   toggled here), written only by `setChecked` and named by neither upsert, so no re-ingest or
///   rescan can touch it. The checkbox shown is `COALESCE(checked_override, is_checked)`.
/// - `ix_playlist_item_member`, so ordering a playlist by its own positions is one index probe
///   per song.
///
/// Added in v3:
/// - `music_handoff`: every file File ▸ Add Folder handed to the Music app ("Also add to the
///   Music app"). Folder scans skip these paths, because the song reaches the index through the
///   Music library instead. Music may have copied the file into its own Media folder, and then its
///   row has a different path from the original a scan finds, so the path alone can't tell.
///   AppController keeps a copy of the paths outside the database, like the folder roots, so a
///   rebuilt index gets them back.
enum LibrarySchema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try createSongTable(db)
            try createSearchTables(db)
            try createPlaylistTables(db)
        }
        // Indexes already on disk were made by v1, so every later change is a new migration, never
        // an edit above.
        migrator.registerMigration("v2-checkbox-playlist-order") { db in
            try db.execute(sql: """
                ALTER TABLE song ADD COLUMN is_checked INTEGER NOT NULL DEFAULT 1;
                ALTER TABLE song ADD COLUMN checked_override INTEGER;
                CREATE INDEX ix_playlist_item_member ON playlist_item(playlist_id, song_id, position);
                """)
        }
        migrator.registerMigration("v3-music-handoff") { db in
            try db.execute(sql: """
                CREATE TABLE music_handoff (
                  path           TEXT PRIMARY KEY,   -- the file as the folder walk spells it
                  persistent_id  INTEGER,            -- the Music song it became, when Music said
                  handed_at      INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
        return migrator
    }

    private static func createSongTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE song (
              id               INTEGER PRIMARY KEY AUTOINCREMENT,
              origin           INTEGER NOT NULL DEFAULT 0,
              persistent_id    INTEGER UNIQUE,
              cloud_id         TEXT,
              store_item_id    INTEGER NOT NULL DEFAULT 0,

              title            TEXT NOT NULL DEFAULT '',
              artist           TEXT NOT NULL DEFAULT '',
              album            TEXT NOT NULL DEFAULT '',
              album_artist     TEXT NOT NULL DEFAULT '',
              composer         TEXT NOT NULL DEFAULT '',
              genre            TEXT NOT NULL DEFAULT '',
              comments         TEXT NOT NULL DEFAULT '',
              grouping         TEXT NOT NULL DEFAULT '',

              total_time_ms    INTEGER NOT NULL DEFAULT 0,
              track_number     INTEGER NOT NULL DEFAULT 0,
              track_count      INTEGER NOT NULL DEFAULT 0,
              disc_number      INTEGER NOT NULL DEFAULT 0,
              disc_count       INTEGER NOT NULL DEFAULT 0,
              year             INTEGER NOT NULL DEFAULT 0,
              bpm              INTEGER NOT NULL DEFAULT 0,
              added_at         INTEGER NOT NULL DEFAULT 0,
              play_count       INTEGER NOT NULL DEFAULT 0,
              rating           INTEGER NOT NULL DEFAULT 0,
              is_compilation   INTEGER NOT NULL DEFAULT 0,

              bucket           INTEGER NOT NULL DEFAULT 1,
              is_cloud         INTEGER NOT NULL DEFAULT 0,
              location_type    INTEGER NOT NULL DEFAULT 0,
              location_path    TEXT,
              has_artwork      INTEGER NOT NULL DEFAULT 0,
              album_pid        INTEGER NOT NULL DEFAULT 0,
              kind             TEXT NOT NULL DEFAULT '',
              bit_rate         INTEGER NOT NULL DEFAULT 0,
              sample_rate      INTEGER NOT NULL DEFAULT 0,
              file_size        INTEGER NOT NULL DEFAULT 0,
              file_mtime       INTEGER NOT NULL DEFAULT 0,

              sk_title         TEXT NOT NULL DEFAULT '',
              sk_artist        TEXT NOT NULL DEFAULT '',
              sk_album         TEXT NOT NULL DEFAULT '',
              sk_album_artist  TEXT NOT NULL DEFAULT '',
              sk_genre         TEXT NOT NULL DEFAULT '',
              -- StableHasher over every ingested value; equal means a re-ingest can skip the row.
              content_hash     INTEGER NOT NULL DEFAULT 0
            );

            CREATE INDEX ix_title  ON song(sk_title, sk_artist, id);
            CREATE INDEX ix_artist ON song(sk_artist, sk_album, disc_number, track_number, id);
            CREATE INDEX ix_album  ON song(sk_album, disc_number, track_number, id);
            CREATE INDEX ix_added  ON song(added_at, id);
            CREATE INDEX ix_bucket ON song(bucket, location_type);
            CREATE INDEX ix_time   ON song(total_time_ms, id);
            CREATE INDEX ix_genre  ON song(sk_genre, sk_artist, sk_album, disc_number, track_number, id);
            CREATE INDEX ix_year   ON song(year, sk_artist, sk_album, disc_number, track_number, id);
            CREATE INDEX ix_plays  ON song(play_count, id);
            CREATE UNIQUE INDEX ux_folder_path ON song(location_path) WHERE origin = 1;
            """)
    }

    /// The six searchable columns, in FTS column order.
    static let searchColumns = ["title", "artist", "album", "album_artist", "composer", "genre"]

    private static func createSearchTables(_ db: Database) throws {
        // 1-2 character tokens: prefix index (§4.2).
        try db.create(virtualTable: "song_fts", using: FTS5()) { t in
            t.tokenizer = .unicode61(diacritics: .remove)
            t.content = "song"
            t.contentRowID = "id"
            t.prefixes = [1, 2, 3]
            t.detail = "column"
            for column in searchColumns { t.column(column) }
        }
        // 3+ character tokens, mid-word. Trigram is not in GRDB's tokenizer enum.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE song_tri USING fts5(
              \(searchColumns.joined(separator: ", ")),
              content='song', content_rowid='id',
              tokenize="trigram remove_diacritics 1")
            """)

        let cols = searchColumns.joined(separator: ", ")
        let new = searchColumns.map { "new.\($0)" }.joined(separator: ", ")
        let old = searchColumns.map { "old.\($0)" }.joined(separator: ", ")
        let changed = searchColumns.map { "old.\($0) IS NOT new.\($0)" }.joined(separator: " OR ")
        try db.execute(sql: """
            CREATE TRIGGER song_fts_ai AFTER INSERT ON song BEGIN
              INSERT INTO song_fts(rowid, \(cols)) VALUES (new.id, \(new));
              INSERT INTO song_tri(rowid, \(cols)) VALUES (new.id, \(new));
            END;
            CREATE TRIGGER song_fts_ad AFTER DELETE ON song BEGIN
              INSERT INTO song_fts(song_fts, rowid, \(cols)) VALUES ('delete', old.id, \(old));
              INSERT INTO song_tri(song_tri, rowid, \(cols)) VALUES ('delete', old.id, \(old));
            END;
            CREATE TRIGGER song_fts_au AFTER UPDATE OF \(cols) ON song WHEN \(changed) BEGIN
              INSERT INTO song_fts(song_fts, rowid, \(cols)) VALUES ('delete', old.id, \(old));
              INSERT INTO song_tri(song_tri, rowid, \(cols)) VALUES ('delete', old.id, \(old));
              INSERT INTO song_fts(rowid, \(cols)) VALUES (new.id, \(new));
              INSERT INTO song_tri(rowid, \(cols)) VALUES (new.id, \(new));
            END;
            """)
    }

    private static func createPlaylistTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE playlist (
              id           INTEGER PRIMARY KEY,   -- persistent id bit pattern
              name         TEXT NOT NULL,
              kind         INTEGER NOT NULL,      -- PlaylistInfo.Kind.storedValue
              parent_id    INTEGER,
              track_count  INTEGER NOT NULL DEFAULT 0,
              sort_index   INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE playlist_item (
              playlist_id  INTEGER NOT NULL REFERENCES playlist(id) ON DELETE CASCADE,
              song_id      INTEGER NOT NULL REFERENCES song(id) ON DELETE CASCADE,
              position     INTEGER NOT NULL
            );
            CREATE INDEX ix_playlist_item ON playlist_item(playlist_id, position);
            CREATE INDEX ix_playlist_item_song ON playlist_item(song_id);
            CREATE TABLE folder_root (path TEXT PRIMARY KEY);
            CREATE TABLE meta (key TEXT PRIMARY KEY, value) WITHOUT ROWID;
            """)
    }
}
