# Download and playlist validation — November 1, 2026

These checks ran on Noah's Mac, on macOS 27.0.1 (26A434).
The app used the Bench configuration, the Release optimizer, App Sandbox, and the shipping Music scripting access group.
The build used the Developer ID Application certificate for team `92N52YB23U`.
No broad Apple Events exception was present.

## Results

| Check | Observed result |
| --- | --- |
| Uploaded-song download | Acceptance at 0.3 s. First file observation at 5.3 s. Stable size at 9.1 s. |
| Downloaded file | Readable, unprotected MP3, 117,195 bytes. Persistent ID unchanged. File-backed songs increased from 5 to 6. |
| Download notifications | Two notices, at +3.9 and +7.1 s from the request. |
| Repeat download | Music returned `-1708` in 0.1 s for the now-local song. The downloader treated it as a per-song refusal. |
| Scripted playlist additions | One call added `a`. A second call added `[b, a]`. Local and cloud reads retained `[a, b, a]`. |
| Cloud persistence | The cloud sequence matched the original persistent IDs before and after a 40-second wait. |
| Playlist cleanup | All disposable playlists disappeared. The source playlist remained unchanged. No library-song copies remained. |
| Offline regression bench | 247 playlist/download checks passed. The layout-restoration check brought the total to 248, with zero failures. |

The offline bench also passed all 248 checks on the final validation build at 10:29 PM PST.
The initial live playlist run passed all 11 checks at 10:16 PM PST.
The first add took 0.11 s. The second took 0.15 s, or 0.08 s per song.
Their observation intervals received zero and one library-change notices respectively.
The strengthened playlist rerun passed all 11 checks at 10:29 PM PST.
It explicitly rejected missing library songs after the second add, an assertion absent from the earlier harness.
Both calls preserved all 15,903 library song IDs, with zero new or missing songs.
The rerun measured 0.14 s for one song and 0.20 s for two songs.
Cloud readback and local readback retained the sequence again after the 40-second wait.
Music stayed hidden and inactive during both live harnesses.

The test song was a 4.44-second uploaded track with persistent ID `6FC98CDFE5FCF3E5`.
After validation, Music's **Remove Download** action removed its local file.
A readback returned the same persistent ID, `shared track`, `uploaded`, and five file tracks in the library.
The song remained in the library. The Music view was unfiltered again after cleanup.

The retained [log excerpts](evidence/reliability-2026-11-01.txt) include the measured times and regression results.

## Refresh correction

The previous edit counter protected changes made during a refresh.
A refresh started just after an edit could still replace it with iTunesLibrary's older snapshot.

Each edit now stores its timestamp in the same transaction as the counter.
Ingest records the snapshot start time before it reads Music.
A changed counter or a snapshot started within ten seconds of the latest edit defers playlist replacement.
The retry waits until the window ends, with the existing back-off for successive stale passes.
Song updates still proceed, so a completed download can enter the index during playlist settling.

The regression checks cover:

- A snapshot started before an edit, and one started just after it with the current counter.
- A slow snapshot that finishes after the window but started inside it.
- Reopening the index with pending additions, renames, removals, and deleted folders.
- A completed download during the settling window.
- Reconciliation at the exact boundary, including a snapshot that rolls back the local edit.

Ten seconds is a bounded settling allowance. Music remains authoritative after that window.
The tests prove the guard's behavior, not a universal maximum for iTunesLibrary lag.

## Repeat the checks

The live checks need the library owner's authorization. The download uses disk until removed in Music.
The playlist check creates disposable playlists and deletes them through the real scripting editor.
The cloud-read flag uses the private web client only to read the test playlist.
It does not send cloud writes.

Build from the repository root:

```sh
xcodebuild -project oldTunes.xcodeproj -scheme oldTunes -configuration Bench \
  -derivedDataPath build/reliability -clonedSourcePackagesDirPath build/dd/SourcePackages \
  -disableAutomaticPackageResolution CODE_SIGN_STYLE=Manual \
  'CODE_SIGN_IDENTITY=Developer ID Application: Noah Tsutsui (92N52YB23U)' \
  DEVELOPMENT_TEAM=92N52YB23U build
```

Run the scratch-index checks:

```sh
open -n -W --stdout /private/tmp/oldtunes-reliability-lists.log \
  --env OLDTUNES_HARNESS=lists --env OLDTUNES_LISTS_MODE=playlists \
  build/reliability/Build/Products/Bench/oldTunes.app
```

Run the download check with an uploaded song that has no local file:

```sh
open -n -W --stdout /private/tmp/oldtunes-reliability-download.log \
  --env OLDTUNES_HARNESS=musicdownload --env OLDTUNES_DOWNLOAD_PID=6FC98CDFE5FCF3E5 \
  build/reliability/Build/Products/Bench/oldTunes.app
```

Run the playlist check with a plain source playlist containing two distinct songs:

```sh
open -n -W --stdout /private/tmp/oldtunes-reliability-playlists.log \
  --env OLDTUNES_HARNESS=musicplaylists --env OLDTUNES_PLAYLIST_SOURCE=AF6A3AC76ED023A6 \
  --env OLDTUNES_PLAYLIST_CHECK_CLOUD=1 \
  build/reliability/Build/Products/Bench/oldTunes.app
```

Without the cloud-read flag, the playlist harness checks local persistence only.
The flag identifies the new UUID-named playlist against a complete pre-run cloud-ID baseline.
Native MusicKit lookups join remote song IDs to persistent IDs before the sequence comparison.

## Limits and retained behavior

The asynchronous download reply supports retaining the 30-second reply timeout.
The `-1708` result supports retaining per-song refusal handling.
The three-minute refresh remains a fallback for missed notifications, although this run received them.

These results cover one uploaded download and an uploaded/matched playlist pair on this account and OS version.
They do not establish bulk-download timing, sleep recovery, offline conflict behavior, indefinite cloud retention, or behavior on every supported macOS version.
