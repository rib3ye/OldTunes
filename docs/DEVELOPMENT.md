# Developing OldTunes

How to build, test and release OldTunes, and where things are in the code. The
[README](../README.md) is for the people who use it. Paths here start at the repo root.

## Build and run

On your Mac, in the folder you cloned this repo into (the one with `project.yml`). Needs
Xcode 27 and XcodeGen (`brew install xcodegen`):

```bash
xcodegen generate && xcodebuild -project OldTunes.xcodeproj -scheme OldTunes -configuration Debug -derivedDataPath build/dd -allowProvisioningUpdates build
```

Then open the app, on your Mac, from the same directory:

```bash
open build/dd/Build/Products/Debug/OldTunes.app
```

Builds are signed as "Apple Development: Noah Tsutsui", team 92N52YB23U. Never ad-hoc sign
(`codesign -s -`): the signature changes every build and macOS forgets the library permission.

`project.yml` is the source of truth; the `.xcodeproj` is generated and not committed, and so is
`OldTunes/App/OldTunes-Debug.entitlements`, which `xcodegen generate` writes from
`OldTunes.entitlements` (`tools/debug-entitlements.sh`).

## Releases

Every push to `main` builds OldTunes and publishes it on the repo's Releases page as
`OldTunes-<version>-<build>.zip`, with notes listing the pull requests merged since the last
release. The build runs on Noah's Mac, not on GitHub's machines: the `Release` workflow
(`.github/workflows/release.yml`) hands the job to a GitHub Actions runner installed on that
Mac, which runs `tools/release.sh` in its own checkout. The app is signed with Developer ID,
and notarized once a notarytool profile exists (the script's header says how to make one). The
version is `MARKETING_VERSION` in `project.yml` and the build number is the commit count, so
the About box says, say, "Version 0.1.0 (5)".

The Mac has to be on and logged in. While it sleeps the release waits; GitHub drops it after
24 hours, and then Actions ▸ Release ▸ Run workflow starts it again.

To make a release by hand, on that Mac, from the repo root of a clean checkout of `main`:

```bash
tools/release.sh
```

`tools/release.sh --dry-run` does everything except publish.

The runner lives in `~/actions-runner-OldTunes` and starts at login as a LaunchAgent. Its logs
are in `~/actions-runner-OldTunes/_diag`. To set it up on another Mac, follow repo Settings ▸
Actions ▸ Runners ▸ New self-hosted runner into that folder, then run `./svc.sh install` there.
Before `./svc.sh start`, delete the `SessionCreate` key from the plist that `svc.sh install`
wrote in `~/Library/LaunchAgents`: it starts jobs in a separate security session that can't use
the login keychain, so signing fails with `errSecInternalComponent`. Before this repo goes
public, remove the runner: on a public repo, a stranger's pull request can add a workflow that
runs on it.

## The sandbox

OldTunes runs in macOS's App Sandbox, the security container every Mac App Store app runs in.
It can open your Music folder (`~/Music`) and the folders you add with Add Folder, and nothing
else on your Mac. What that means:

- **Your settings and library come along.** The first time a sandboxed OldTunes opens, macOS
  moves its settings and library index from `~/Library` into OldTunes's own folder,
  `~/Library/Containers/com.noahtsutsui.oldtunes`. It does this once. An older, unsandboxed
  OldTunes opened after that starts without them.
- **Folders you added before the sandbox need choosing once more.** OldTunes asks at launch
  and opens a panel at each folder: click Allow. Until then their songs show as missing. They
  aren't removed.
- **Music songs stored outside `~/Music`**, for example a Music Media folder on another drive,
  play from iCloud when they're in your iCloud Music Library. Otherwise OldTunes says it isn't
  allowed to open the file. Add the folder they're in with Add Folder, and they play from it:
  the songs still show once, as Music songs.

## Limits that come from Apple's frameworks

- **Cloud songs come out 25 ms late.** Apple's MusicKit has no volume control on macOS, so
  OldTunes takes each cloud song's sound from Apple's player process and plays it out itself at
  the right level. Without the System Audio Recording permission it can't: cloud songs then play
  at their own level, and the volume slider is greyed out while one plays.
- **Catalog fallback** (playing a song by its Apple Music catalog id when the library copy
  can't be found) needs the MusicKit App Service enabled for `com.noahtsutsui.oldtunes` at
  developer.apple.com ▸ Identifiers. Library playback works without it.

## Where things are

- `docs/RESEARCH.md` — the spec: every API decision, measured on this Mac, plus the
  pixel-sampled iTunes 4.9 colors and metrics.
- `docs/LICENSES.md` — the open-source libraries inside OldTunes, their licences, where the
  licence texts in the app come from, and what to update when a package version changes.
- `tools/make-app-icon.swift` — draws the app icon (the iTunes 7–9 disc and note, 2006–2010,
  on a dark grey tile) into `OldTunes/App/Assets.xcassets`. The tile keeps macOS 26 and later
  from shrinking the icon onto a light gray one. After changing it, run
  `swift tools/make-app-icon.swift` on your Mac from the repo root.
- `OldTunes/Model/Contracts.swift` — the protocols between modules. Only
  `OldTunes/App/AppController.swift` wires concrete types together.
- `Vendor/CXXMonkeysAudio` — the Monkey's Audio package SFBAudioEngine uses, with a permissively
  licensed MD5 in place of a GPL one. `Vendor/README.md` says why and when to remove it.
- `docs/RESEARCH.md` §7.7 — the dark ("Graphite") colors and how the switch works.

## Test benches

Launch with `open -n --env OLDTUNES_HARNESS=<name> …/OldTunes.app` where
`<name>` is `smoke` (end to end), `library`, `playback`, `metadata`, `chrome`, `lists`,
`appearance` (light and dark, with an invented library), `visualizer` (pick a part with
`OLDTUNES_VIS_MODE`; see `docs/VISUALIZER.md`), `authcheck`, or `musicaccess` (which ways of
naming songs and playlists Music answers inside the sandbox; read-only, changes nothing).
`OLDTUNES_SNAPSHOT=/path.png` renders the window to a PNG; `OLDTUNES_DB_PATH` points the
index somewhere else. Test benches run in Light; `OLDTUNES_APPEARANCE=dark` runs one in the
dark without changing the saved setting.

Only Debug and Bench builds have the benches and read these variables. Release builds, the
ones that ship, leave the bench files out (`project.yml` lists them) and ignore the variables.
For a bench that must run on a release build, such as `musicaccess` and the live checks,
build with `-configuration Bench`: Release's optimizer and entitlements, plus the benches.

OldTunes runs in the App Sandbox, so a bench can read and write only its container and, in a
Debug build, `/private/tmp` (`/tmp` is the same folder) and `~/Library/Logs/OldTunes`
(`tools/debug-entitlements.sh`). Put every path you pass a bench, such as the index,
snapshots and evidence folders, under `/private/tmp`. Without a path, a bench writes inside
the container, where nothing outside the app can read it. `open --stdout <file>` captures a
run's log lines too. The settings and index a bench uses without `OLDTUNES_DB_PATH` are the
container's, shared with any other sandboxed OldTunes, not those in `~/Library`.

The `library` bench runs only when `OLDTUNES_DB_PATH` contains `/scratchpad/evidence/library/`
or `/scratchpad/fixes/library/`, and it adds a folder of invented audio files that must
already sit next to that index. `tools/make-library-fixtures.sh` makes them; run it before the
first library run in each new evidence folder (it needs `brew install ffmpeg flac lame`). On
your Mac, from the repo root (the folder you built in):

```bash
tools/make-library-fixtures.sh /tmp/scratchpad/evidence/library
open -n -W --env OLDTUNES_HARNESS=library --env OLDTUNES_DB_PATH=/tmp/scratchpad/evidence/library/index.sqlite build/dd/Build/Products/Debug/OldTunes.app
```

The bench quits by itself; its last log line is `library harness: SUMMARY …`.

`OLDTUNES_LISTS_MODE=playlists` runs only the `lists` bench's playlist-command checks (the
right-click menu, renaming in place, Delete, and the index edits behind them). It uses an
invented library in a scratch index, never Music.

Three live checks change the real Music library, so they run only with the library owner's
go-ahead: `musictag` (saves one comment through Music, then puts it back), `musicadd`
(adds an invented test tone through Add Folder's Music option; `OLDTUNES_MUSICADD_REMOVE`
takes it back out) and `musicplaylists` (makes, renames, duplicates and deletes “OldTunes
Test” playlists, then checks they're all gone). The headers of
`OldTunes/App/MusicTagLiveTest.swift`, `OldTunes/App/MusicAddLiveTest.swift` and
`OldTunes/App/MusicPlaylistLiveTest.swift` say how to run them.

## Logs

Logs are in Pacific time. A Debug build's full log is `~/Library/Logs/OldTunes/oldtunes.log`. A
release build may write only inside its sandbox container, so its file is
`~/Library/Containers/com.noahtsutsui.oldtunes/Data/Library/Logs/OldTunes/oldtunes.log`, which
Finder can open but Terminal can't read. A release build also sends every line to macOS's own
log, which keeps it on disk. To read the last hour of it, on your Mac, from any directory:

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "com.noahtsutsui.oldtunes"'
```
