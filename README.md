# OldTunes

A Mac music player that looks like iTunes 4.9 (2005, brushed metal) and plays your whole
Apple Music / iCloud Music Library — including songs that were never downloaded — plus music
files on this Mac.

![OldTunes playing a cloud song](docs/screenshot.png)

## What it does

- **Plays everything in your library.** Cloud-only songs stream through MusicKit; files on
  this Mac play through AVFoundation. One queue covers both.
- **Instant search** over every song, cloud or local, including the middle of words
  ("nderw" finds "Underworld").
- **Sort** by clicking a column header: Name, Artist, Album, Date Added, Time, Genre. Click
  again to reverse. OldTunes keeps the last sort you clicked, even after you quit. Playlists
  still open in their own order, and the list goes back to your sort when you leave one.
- **Shuffle** and **repeat** (off / all / one) from the buttons under the source list.
- **Dock menu.** Right-click OldTunes's Dock icon to see the song playing and to play or pause,
  skip to the next or previous song, and set Shuffle and Repeat, as in iTunes. Its Previous
  Song always goes back a song; the back button and ⌘← restart the song first if it's more than
  3 s in.
- **Get Info** (⌘I) reads and edits tags. Songs in your Music library are saved through the
  Music app, which also updates the song's file if it has one, so Music and OldTunes always
  agree. Songs from added folders are rewritten in place safely (temp copy, then an atomic swap).
- **Checkboxes** next to each song work like iTunes: unchecked songs are skipped when playing
  through a list or shuffling, but still play if you double-click them. ⌘-click checks or
  unchecks every song in the list.
- **Add Folder to Library** (⌘O or the + button) adds folders of music from any drive.
  Tick **Also add to the Music app** in the panel to give the songs to Music too. With Sync
  Library on, Music then matches or uploads them to your iCloud Music Library, so they reach
  your other devices. Each song still shows once in OldTunes. Music doesn't take every kind of
  audio file; OldTunes keeps the ones it turns down and lists them when it's done. The box
  stays the way you left it.
- **On This Mac** in the source list shows only songs with a file on this Mac.
- Your Music playlists appear in the source list. The **Browse** button opens the
  Genre / Artist / Album browser.
- **Right-click a playlist** for New Playlist, New Playlist Folder, Rename, Duplicate and
  Delete. A new playlist goes inside the folder you clicked (or beside the playlist), and its
  name opens for typing, like iTunes. Return renames the selected playlist; Delete deletes it
  after asking. Each change is made in the Music app, so Sync Library carries it to your other
  devices. Duplicate is for plain playlists only: a copy of a smart playlist's songs would
  lose its rules.
- **Light or dark.** OldTunes ▸ Settings… (⌘,) picks Light (the 2005 look), Dark, or Match
  System, which follows System Settings ▸ Appearance and switches when your Mac does. Dark is
  "Graphite": smoked brushed metal, and the LCD in its night mode, dark glass with lit sage
  letters. Match System is the default.
- **Sound Check**, in the same Settings window, plays each song at the level the Music app
  measured for it, so OldTunes and Music play it equally loud, cloud songs included. It's off
  until you turn it on, as in Music.
- **Its own volume.** The volume slider (and ⌘↑ / ⌘↓) sets OldTunes's volume for every song,
  cloud songs too, and leaves the Mac's volume alone. OldTunes remembers it when you quit.
- **Visualizer.** The flower button at the bottom right, or ⌘T, swaps the song list for a
  visualizer that moves with the music, cloud songs included, as iTunes 4.9 did. ⇧⌘F fills the
  screen with it; Esc comes back. Inside it, H lists its keys (R for something new, P M W for a new
  palette, motion or wave, and more). It is based on [Geiss HDR](https://www.geisswerks.com/geiss_hdr)
  by Ryan Geiss. On a screen that can show HDR its brightest colours go past white; Settings ▸
  Visualizer turns that off. Needs macOS 14.2 or later.

## Signing in

OldTunes uses the Apple Account already signed in on this Mac (the one the Music app uses).
The first launch asks for **Media & Apple Music** access; click Allow. If you said no, turn
OldTunes on in System Settings ▸ Privacy & Security ▸ Media & Apple Music, then quit and
reopen OldTunes. macOS only applies the change after a relaunch.

The first time you save tags for a song in your Music library, add a folder with **Also
add to the Music app** ticked, or change a playlist, macOS asks whether OldTunes may control
Music. OldTunes uses that permission only to save tags, add songs and change playlists; it
never tells Music to play.

The first time OldTunes plays a cloud song, macOS asks whether OldTunes may record system audio.
Allow it: cloud songs play in a separate Apple process, and OldTunes takes their sound from there
so its volume slider and Sound Check can set their level, and so the visualizer can hear them.
OldTunes listens only to its own songs and records or saves nothing. If you said no, cloud songs
play at their own level, the volume slider is greyed out during them, and the visualizer says it
can't hear the music; turn OldTunes on in System Settings ▸ Privacy & Security ▸ Screen &
System Audio Recording, under System Audio Recording Only, then quit and reopen OldTunes.

## The sandbox

OldTunes runs in macOS's App Sandbox, the security container every Mac App Store app runs in.
It can open your Music folder (`~/Music`) and the folders you add with Add Folder, and nothing
else on your Mac. What that means for you:

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

## Keyboard

| Key | Does |
|---|---|
| Space | Play / pause (except while typing) |
| Return / double-click | Play the selected song |
| Return (source list) | Rename the selected playlist; Escape cancels |
| Delete (source list) | Delete the selected playlist (asks first) |
| ⌘→ / ⌘← | Next / previous song (previous restarts the song if more than 3 s in) |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⌘F | Search |
| ⌘I | Get Info |
| ⌘B | Show / hide the browser |
| ⌘O | Add Folder to Library |
| ⌘, | Settings (appearance, Sound Check, visualizer HDR) |
| ⌘1 | Bring back the main window after closing it (music keeps playing) |
| ⌘T | Visualizer on / off |
| ⇧⌘F | Visualizer full screen (Esc to come back) |
| H | The visualizer's own keys, while it shows |

## Known limits

- **Cloud songs come out 25 ms late.** Apple's MusicKit has no volume control on macOS, so
  OldTunes takes each cloud song's sound from Apple's player process and plays it out itself at
  the right level. Without the System Audio Recording permission it can't: cloud songs then play
  at their own level, and the volume slider is greyed out while one plays.
- **Sound Check on files.** For a song with a file on this Mac, Sound Check can only make it
  louder as far as the volume slider leaves room (Music can go further).
- **Media keys right as a cloud song starts.** For about 0.15 s after a cloud song starts,
  a play/pause or next key can reach MusicKit's own player and pause the song.
- **No AirPlay or crossfade** for cloud songs (MusicKit doesn't offer them on macOS).
- **No downloading** cloud songs to this Mac; MusicKit on macOS can't add or download.
- **Equalizer and eject** buttons are drawn for looks and do nothing.
- **Playlists can't be edited song by song yet**, and smart playlists' rules can't be
  changed: the source list makes, renames, duplicates and deletes whole playlists only.
  Duplicate copies a playlist one song at a time through Music, so a long one takes a while.
- **Catalog fallback** (playing a song by its Apple Music catalog id when the library copy
  can't be found) needs the MusicKit App Service enabled for `com.noahtsutsui.oldtunes` at
  developer.apple.com ▸ Identifiers. Library playback works without it.

## For developers

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
- Test benches: launch with `open -n --env OLDTUNES_HARNESS=<name> …/OldTunes.app` where
  `<name>` is `smoke` (end to end), `library`, `playback`, `metadata`, `chrome`, `lists`,
  `appearance` (light and dark, with an invented library), `visualizer` (pick a part with
  `OLDTUNES_VIS_MODE`; see `docs/VISUALIZER.md`), `authcheck`, or `musicaccess` (which ways of
  naming songs and playlists Music answers inside the sandbox; read-only, changes nothing).
  `OLDTUNES_SNAPSHOT=/path.png` renders the window to a PNG; `OLDTUNES_DB_PATH` points the
  index somewhere else. Test benches run in Light; `OLDTUNES_APPEARANCE=dark` runs one in the
  dark without changing the saved setting.

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
- `OLDTUNES_LISTS_MODE=playlists` runs only the `lists` bench's playlist-command checks (the
  right-click menu, renaming in place, Delete, and the index edits behind them). It uses an
  invented library in a scratch index, never Music.
- Three live checks change the real Music library, so they run only with the library owner's
  go-ahead: `musictag` (saves one comment through Music, then puts it back), `musicadd`
  (adds an invented test tone through Add Folder's Music option; `OLDTUNES_MUSICADD_REMOVE`
  takes it back out) and `musicplaylists` (makes, renames, duplicates and deletes “OldTunes
  Test” playlists, then checks they're all gone). The headers of
  `OldTunes/App/MusicTagLiveTest.swift`, `OldTunes/App/MusicAddLiveTest.swift` and
  `OldTunes/App/MusicPlaylistLiveTest.swift` say how to run them.
- `docs/RESEARCH.md` §7.7 — the dark ("Graphite") colors and how the switch works.
- Logs, in Pacific time. A Debug build's full log is `~/Library/Logs/OldTunes/oldtunes.log`. A
  release build may write only inside its sandbox container, so its file is
  `~/Library/Containers/com.noahtsutsui.oldtunes/Data/Library/Logs/OldTunes/oldtunes.log`, which
  Finder can open but Terminal can't read. A release build also sends every line to macOS's own
  log, which keeps it on disk. To read the last hour of it, on your Mac, from any directory:

  ```bash
  /usr/bin/log show --last 1h --predicate 'subsystem == "com.noahtsutsui.oldtunes"'
  ```
