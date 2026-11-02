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
- `docs/RESEARCH.md` §6.9 and §6.10 — how Download and adding songs to playlists work through
  the Music app, their measured live results, and the remaining edge cases.
  `docs/RELIABILITY.md` records the November 1 download and cloud-persistence checks.

## Test benches

Launch with `open -n --env OLDTUNES_HARNESS=<name> …/OldTunes.app` where
`<name>` is `smoke` (end to end), `library`, `playback`, `metadata`, `chrome`, `lists`,
`appearance` (light and dark, with an invented library), `visualizer` (pick a part with
`OLDTUNES_VIS_MODE`; see `docs/VISUALIZER.md`), `authcheck`, or `musicaccess` (which ways of
naming songs and playlists Music answers inside the sandbox; read-only, changes nothing).
`OLDTUNES_SNAPSHOT=/path.png` renders the window to a PNG; `OLDTUNES_DB_PATH` points the
index somewhere else. Test benches run in Light; `OLDTUNES_APPEARANCE=dark` runs one in the
dark without changing the saved setting. `OLDTUNES_SIMULATE_NO_SYSTEM_AUDIO=1` runs the app as if
System Audio Recording were off, and `OLDTUNES_VIS_EARS=tap` or `self-capture` picks how the
visualizer hears in a normal Debug launch; benches always tap (`docs/VISUALIZER.md` ▸ Without the
permission).

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

The bench quits by itself; its last log line is `library harness: SUMMARY …`. Its change
checks post the system-wide library-changed notice that Music posts, 18 times in all, so an
OldTunes that is open at the same time re-reads its own library four or five times during the
run. Nothing else in that app changes, and the bench never writes to the Music library. Music
posts that notice by itself too (iCloud Library syncing, a play count), and each one starts a
re-read. So the checks that count re-reads exactly also count Music's notices, from 25 s before
a check begins (a re-read one started can still be running then) until it ends. One that fails
while Music posted says `BLOCKED … Music posted N notices of its own during the check; run
again` instead of FAIL, and counts among the SUMMARY's blocked checks. The check that one more
re-read follows by itself after a playlist edit says so even if it would have passed, since a
notice of Music's can do that re-read's job. Run the bench again.

`OLDTUNES_LISTS_MODE=playlists` runs only the `lists` bench's playlist checks: the right-click
menus, renaming in place (and waiting while a name is being typed, as the alerts after an add or
a Download do), Delete and the index edits behind them, songs dragged onto playlists and
the drop outline, Add to Playlist ▸, the blue cloud on songs being downloaded, and the rules and
alert texts behind adding and downloading (the download watch runs on a made-up clock).
It also checks playlist song removal through Delete and Clear, text-field focus, event structure,
and preservation of library songs and other playlists. It uses
an invented library in scratch indexes, never Music.

### Playback regression checks

`OLDTUNES_PLAYBACK_MODE=soundcheck` uses generated tones and a muted tap on OldTunes's output.
It measures amplification, attenuation, the volume slider, mute, pause, seek, and the gain of a preloaded song.
It changes no library data or saved settings. System Audio Recording permission is necessary for this measurement.
Normal local-file Sound Check needs no recording permission.

`OLDTUNES_PLAYBACK_MODE=startup` checks media commands during cloud starts, resumes, and transitions from local and cloud songs.
The reclaim timer stays disabled. An external driver sends commands only when macOS identifies the bench process as the current player.
The driver uses private MediaRemote calls. Each bench uses the `playback` harness and quits after its checks.

From the repository root, after a Debug build with the installed app's Developer ID signature:

```bash
swiftc tools/media-key-driver.swift -o /private/tmp/oldtunes-media-key-driver
run_dir=$(mktemp -d /private/tmp/oldtunes-media-keys.XXXXXX)
/private/tmp/oldtunes-media-key-driver "$run_dir/startup.log" > "$run_dir/driver.log" 2>&1 &
driver_pid=$!
open -n -W --stdout "$run_dir/startup.log" --stderr "$run_dir/startup.err" --env OLDTUNES_HARNESS=playback --env OLDTUNES_PLAYBACK_MODE=startup build/dd/Build/Products/Debug/OldTunes.app
wait "$driver_pid"
open -n -W --stdout "$run_dir/soundcheck.log" --stderr "$run_dir/soundcheck.err" --env OLDTUNES_HARNESS=playback --env OLDTUNES_PLAYBACK_MODE=soundcheck build/dd/Build/Products/Debug/OldTunes.app
```

`CloudMediaControls` uses a guarded private macOS setting to prevent MusicKit from taking control of media commands.
This change targets Developer ID distribution. A Mac App Store build needs a public replacement.
If the setting is unavailable, OldTunes retains its earlier reclaim behavior, including the brief startup limitation.
`LocalSoundCheck` uses public MediaToolbox audio processing taps. Each queued item keeps its own gain, before AVPlayer applies the volume slider.

Measured November 1, 2026 on macOS 27.0.1: all 24 startup checks and 11 audio checks passed.
Debug and Release builds passed in an isolated source copy because unrelated playlist work was in progress in the shared checkout.

### Private web playlist prototype

`OLDTUNES_HARNESS=musicwebchecks` runs the private web client's offline checks. It uses fake
HTTP responses and needs no Apple account.

`OLDTUNES_HARNESS=musicwebplaylists` runs the live prototype. Its default mode only reads
playlists and songs. It also compares native and cloud playlist identities. Music must be
closed before the run. The prototype never starts Music or sends it Apple Events.

The client obtains Apple's current web developer token from the public website. Native
MusicKit supplies the user token. Both tokens stay in memory. Logs exclude tokens, response
bodies, and personal playlist names. The client leaves the global MusicKit token provider alone.

With the library owner's go-ahead, `OLDTUNES_WEBPLAYLIST_MODE=write` also runs the mutation
check. It creates one uniquely named `OldTunes Web Test` playlist. It renames that playlist,
adds an existing library song, removes the song, and deletes the playlist. Each step reads the
result back from the cloud. Cleanup only targets the playlist created by that run.

The bench observes Music process launches throughout the run. If Music starts, the bench stops
the test and cleans up its playlist. A failed cleanup reports the fixture ID for recovery.
The prototype does not change the playlist commands in the normal OldTunes window.

Use the installed app's Developer ID signature for live checks. An Apple Development signature
can cause macOS to request the Music permission again. From the repository root:

```bash
xcodegen generate
xcodebuild -project OldTunes.xcodeproj -scheme OldTunes -configuration Debug -derivedDataPath build/dd CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application: Noah Tsutsui (92N52YB23U)" DEVELOPMENT_TEAM=92N52YB23U build
open -n -W --stdout /private/tmp/oldtunes-musicweb-read.log --stderr /private/tmp/oldtunes-musicweb-read.err --env OLDTUNES_HARNESS=musicwebplaylists build/dd/Build/Products/Debug/OldTunes.app
```

For the approved mutation check, add `--env OLDTUNES_WEBPLAYLIST_MODE=write` to the launch command.
For the offline checks, change the harness name to `musicwebchecks`.
`OLDTUNES_WEBPLAYLIST_MODE=auth` only checks native authorization and cloud reads. Music can
already be running in this mode. It does not establish that Music stays closed.
In read mode, `OLDTUNES_WEBPLAYLIST_INSPECT_ID=p.…` reports membership and metadata presence
for one cloud playlist. It does not print names or change the library.

Measured on November 1, 2026: the full live check passed in 13.28 seconds. Native authorization
required no browser sign-in. Create, rename, append, remove, delete, and cleanup all passed.
The source song remained in the library; its name and play parameters matched the initial read.
Music stayed closed according to launch observation and an independent process monitor.
All 48 offline checks passed.

The first live run revealed two API behaviors. An empty playlist's standalone `/tracks`
endpoint can return 404. Read the parent with `include=tracks` and require an explicit track
relationship. After deletion, direct lookup can return a nameless, uneditable placeholder.
Confirm deletion through the complete playlist listing and the placeholder's metadata.

This result covers one cloud-created regular playlist and one existing library song.
Existing Music-created playlists, duplicate song removal, and batch edits still need live checks.
The identity diagnostic found 17 native playlists and 11 cloud playlists, with no direct ID
matches. Native play parameters contained persistent IDs but no matching cloud playlist IDs.
The normal UI needs a reliable identity mapping before it can use this backend.

### Music scripting checks

Four scripting checks change the real Music library, so they run only with the library owner's
go-ahead: `musictag` (saves one comment through Music, then puts it back), `musicadd`
(adds an invented test tone through Add Folder's Music option; `OLDTUNES_MUSICADD_REMOVE`
takes it back out), `musicplaylists` (makes, renames, duplicates, fills and deletes “OldTunes
Test” playlists in 9 steps, then checks they're all gone and that Music made no copy of a song)
and `musicdownload` (asks Music to download one iCloud song, named by its persistent ID in
`OLDTUNES_DOWNLOAD_PID`, and times how it comes down). The headers of
`OldTunes/App/MusicTagLiveTest.swift`, `OldTunes/App/MusicAddLiveTest.swift`,
`OldTunes/App/MusicPlaylistLiveTest.swift` and `OldTunes/App/MusicDownloadLiveTest.swift` say
how to run them.

The November 1, 2026 runs passed the real download and playlist cloud-persistence checks.
See [the validation record](RELIABILITY.md) for commands, timings, and retained log excerpts.
Set `OLDTUNES_PLAYLIST_CHECK_CLOUD=1` for independent cloud readback in `musicplaylists`.
The harness identifies its UUID-named playlist from the pre-run cloud IDs.
It joins remote song IDs to native persistent IDs and compares the order before and after a 40-second wait.
These web-client calls only read data. The real scripting editor still makes every playlist change.
Without this flag, the harness checks local persistence only.

`musicdownload` is the only one that always leaves something behind. Music has no scripting
command to remove a download, so the downloaded file stays on the Mac, using disk space, until
someone removes it by hand in the Music app (right-click the song ▸ Remove Download). Pick a
short song. Until it's removed, the `library` bench's checks that count on exactly 5 local
files fail as well, such as `5 local files`, `.onThisMac = 5 library files + folder tracks` and
the R1 check that the 5 local Music files are readable.

`musicplaylists` deletes every playlist it makes, but it can't take back a copy of a song, the
failure its add step is there to catch. If Music answers the add by putting a new song in the
library instead of only an entry in the test playlist, the run stops, the log names the new
song by its persistent ID ("a copy Music made; remove it by hand in Music"), and the last step,
`nothing left behind`, fails until it's gone. It names a song only when both reads of the
library around that add call worked and no more songs are new than the call sent: a read that
comes back empty or short stops the run with "couldn’t read the library", and more new songs
than that are counted, never named. Either way `nothing left behind` then fails too, naming no
song, since whether Music made a copy can't be told. A song from another device that arrives
during the call could still be taken for a copy, so look the ID up in Music before removing
anything. The script never deletes a library song. A `delete` addressed to the library removes the song
from every playlist, and Sync Library removes it from every device. For
each add call it also logs how long the call took a song and the library-changed notices Music
posted around it, the numbers `docs/RESEARCH.md` §6.10 says are still to be measured.

## Logs

Logs are in Pacific time. A Debug build's full log is `~/Library/Logs/OldTunes/oldtunes.log`. A
release build may write only inside its sandbox container, so its file is
`~/Library/Containers/com.noahtsutsui.oldtunes/Data/Library/Logs/OldTunes/oldtunes.log`, which
Finder can open but Terminal can't read. A release build also sends every line to macOS's own
log, which keeps it on disk. To read the last hour of it, on your Mac, from any directory:

```bash
/usr/bin/log show --last 1h --predicate 'subsystem == "com.noahtsutsui.oldtunes"'
```
