# OldTunes

OldTunes is a music player for your Mac that looks like iTunes did in 2005 (iTunes 4.9, the
brushed-metal one). It plays your whole Apple Music library, including songs that are only in
iCloud and were never downloaded ("iCloud songs" below), plus music files on your Mac.

![OldTunes playing a song](docs/screenshot.png)

## Get OldTunes

1. Download the newest `OldTunes` zip from the
   [Releases page](https://github.com/rib3ye/OldTunes/releases/latest).
2. Double-click the zip, then drag **OldTunes** into your Applications folder.
3. Open OldTunes. The first time, macOS asks if you're sure you want to open an app from the
   internet. Click **Open**.

To update, do the same with the newer zip and replace the old app.

You need macOS 14 or later (the visualizer needs macOS 14.2). There's nothing to sign in to:
OldTunes uses the Apple Account the Music app already uses on your Mac. To play iCloud songs,
turn on Sync Library in the Music app (Music ▸ Settings ▸ General).

## What macOS asks for, and why

macOS keeps every app away from your music, your other apps and your Mac's sound until you say
yes. OldTunes asks for three things, each only the first time it needs it.

### Media & Apple Music

**When:** the first time you open OldTunes.

**Why:** to see your music library and playlists, and to play your Apple Music and iCloud songs.
Without it, OldTunes can't show your music.

**If you said no:** open System Settings ▸ Privacy & Security ▸ Media & Apple Music and turn on
OldTunes. Then quit and reopen OldTunes: macOS only applies the change after a restart.

### Control the Music app

**When:** the first time you edit a song's details, change a playlist, or add songs to the Music
app.

**Why:** OldTunes makes those changes through the Music app, so Music and your other devices
show them too. OldTunes never uses this to play anything in Music.

**If you said no:** OldTunes can't save those changes. Turn it on in System Settings ▸ Privacy &
Security ▸ Automation ▸ OldTunes ▸ Music.

### System Audio Recording

**When:** the first time you play an iCloud song. On macOS 14.2 and 14.3, also the first time you
turn on the visualizer.

**Why:** OldTunes doesn't play iCloud songs itself. A separate Apple player does, out of sight.
To set their volume and use Sound Check on them, OldTunes takes their sound from that player
and plays it out itself. The visualizer listens the same way. macOS calls listening to that
sound "recording". OldTunes listens only to its own songs, and it doesn't record or save anything.

On macOS 14.4 and later, the visualizer can also listen another way, which needs no permission. It
does that if you said no, and until OldTunes has checked the permission at your first iCloud song.
While it does, macOS counts OldTunes as sharing its own window, so you may see the screen-sharing
icon in the menu bar, and notifications may wait until you turn the visualizer off.

**If you said no:** iCloud songs still play, but at their own volume. The volume slider is
greyed out while one plays, and Sound Check can't change it. On macOS 14.2 and 14.3, the
visualizer says it can't hear the music. To turn the permission on, open System Settings ▸
Privacy & Security ▸ Screen & System Audio Recording, and under System Audio Recording Only, turn
on OldTunes. Then quit and reopen OldTunes.

### Your folders

OldTunes runs in macOS's App Sandbox, the same safety box that apps from the Mac App Store run in.
It can open your Music folder and the folders you pick with Add Folder, and nothing else on your
Mac. Picking a folder is the permission, so there's nothing else to turn on.

- **Updating from an older OldTunes?** Your settings and library come along. Folders you added
  before need picking once more: OldTunes asks when it opens and shows you each one. Click
  **Allow**. Until then their songs show as missing, but nothing is removed.
- **Songs on another drive?** If the Music app keeps your songs outside your Music folder,
  OldTunes plays them from iCloud when it can. If one won't open, add the folder it's in with
  Add Folder.

## What it does

- **Plays your whole library.** Songs on your Mac and iCloud songs play from the same list.
- **Search as you type.** It finds words even from the middle: "nderw" finds "Underworld".
- **Sort** by clicking a column title, like Name, Artist or Date Added. Click it again to reverse
  the order. OldTunes remembers your choice, and playlists keep their own order.
- **Shuffle and repeat** with the buttons under the playlists. Repeat can be off, all, or one song.
- **Dock menu.** Right-click the OldTunes icon in the Dock to see what's playing, play or pause,
  skip, and set Shuffle and Repeat.
- **Get Info** (⌘I) shows a song's details, like its name, artist and album, and lets you change
  them. Changes to songs in your Music library are saved through the Music app, so Music shows
  them too.
- **Checkboxes** work like in iTunes. When a list plays through or shuffles, unchecked songs are
  skipped. Double-click one to play it anyway. ⌘-click a box to check or uncheck every song.
- **Add Folder** (⌘O, or the + button) adds folders of music from any drive. Tick **Also add to
  the Music app** to give the songs to Music too. With Sync Library on, they then reach your other
  devices. If Music turns down some files, OldTunes keeps them and tells you which ones.
- **On This Mac**, in the list on the left, shows only the songs stored on this Mac.
- **Playlists** from the Music app show on the left, and **Browse** sorts your music by genre,
  artist and album. Right-click a playlist to make a new one or a folder, or to rename, copy or
  delete it. These changes happen in the Music app, so they reach your other devices too. Smart
  playlists can't be copied.
- **Light or dark.** In OldTunes ▸ Settings (⌘,), pick Light (the 2005 look), Dark, or Match
  System, which follows your Mac. Match System is the default.
- **Sound Check**, also in Settings, plays every song about equally loud, using the levels the
  Music app measured. It's off until you turn it on.
- **Its own volume.** The volume slider (or ⌘↑ and ⌘↓) changes only OldTunes, not your whole Mac.
  OldTunes remembers it.
- **Visualizer.** Click the flower button at the bottom right, or press ⌘T, to swap the song list
  for moving light that follows the music, as iTunes 4.9 did. ⇧⌘F fills the screen with it, and
  Esc comes back. Inside it, press H to see its keys; R picks a new look. On a screen that can
  show HDR, its brightest colours glow brighter than white, and Settings ▸ Visualizer turns that
  off. Needs macOS 14.2 or later. It's based on [Geiss HDR](https://www.geisswerks.com/geiss_hdr)
  by Ryan Geiss.

  <img src="docs/visualizer-wave.jpg" width="49%" alt="The visualizer: a red and yellow wave across dark blue">
  <img src="docs/visualizer-ring.jpg" width="49%" alt="The visualizer: a ring of green light">
  <img src="docs/visualizer-zoom.jpg" width="49%" alt="The visualizer: pink light streaming out from the middle">
  <img src="docs/visualizer-stars.jpg" width="49%" alt="The visualizer: an orange wave through blue specks">

  *Stills from the visualizer, based on Geiss HDR by Ryan Geiss.*

## Keys

| Key | What it does |
|---|---|
| Space | Play or pause (not while you're typing) |
| Return, or double-click | Play the selected song |
| ⌘→ / ⌘← | Next / previous song (⌘← first goes back to the start if the song has played for more than 3 seconds) |
| ⌘↑ / ⌘↓ | Volume up / down |
| ⌘F | Search |
| ⌘I | Get Info |
| ⌘B | Show or hide Browse |
| ⌘O | Add Folder |
| ⌘, | Settings |
| ⌘1 | Bring back the window after you close it (the music keeps playing) |
| ⌘T | Visualizer on or off |
| ⇧⌘F | Visualizer full screen (Esc comes back) |
| H | The visualizer's own keys, while it shows |
| Return, on a playlist | Rename it (Esc cancels) |
| Delete, on a playlist | Delete it (OldTunes asks first) |

## What it can't do yet

- **AirPlay.** iCloud songs can't play over AirPlay or crossfade, and the visualizer can't hear
  music that's playing over AirPlay.
- **Downloads.** OldTunes can't download iCloud songs to your Mac.
- **Editing inside playlists.** You can't add or remove single songs in a playlist yet, or change
  a smart playlist's rules. Copying a long playlist takes a while.
- **Sound Check on songs stored on your Mac** can only turn a quiet song up as far as the volume
  slider has room. The Music app can go further.
- **Keys right as an iCloud song starts.** In its first moment, pressing play/pause or next on
  your keyboard can pause the song.
- **The equalizer and eject buttons** are only for looks.

---

Building OldTunes yourself? See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
