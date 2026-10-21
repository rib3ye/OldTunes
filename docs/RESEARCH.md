# Implementation Spec

**App:** OldTunes — a 2005-iTunes music player for macOS 27.
**Target machine:** macOS 27.0.1 (26A434), arm64, Xcode 27.1, Swift 6.4, MacOSX27.sdk.
**Scaffold that already exists:** `/Users/noah/Projects/iJustWantToListenToMyOldMusic` with `project.yml` (xcodegen), target `OldTunes`, bundle id `com.noahtsutsui.oldtunes`, `DEVELOPMENT_TEAM = 92N52YB23U`, deployment target macOS 14.0, `OldTunes/App/{AppDelegate.swift,Info.plist,OldTunes.entitlements}`, `OldTunes/Model/{Track.swift,SortKey.swift}`.
**All times in this document are America/Los_Angeles (PT).** Every command block says which machine and which directory it runs in.

This document is the only spec. Where the research disagreed, a decision is stated with its reason and its fallback. Where something is genuinely unknown it is in §10 with a named experiment, not guessed at.

---

## Errata — corrected during the build (October 19, 2026)

Each line overrides the section it names. All were measured on this Mac while building and
reviewing OldTunes; the code follows these, not the original text.

| § | Original said | Measured truth |
|---|---|---|
| 2, 8.5 | Library changes arrive as `ITLibraryDidChangeNotification` | The distributed notification that fires is `com.apple.AMPLibraryAgent.libraryChanged`. |
| 2 | Join MusicKit to iTunesLibrary on the persistent id | `Song.id` is a library id like `i.AbCdEfGhIjK`. The join key is `musicKit_persistentID` inside `playParameters`' JSON, equal to `Int64(bitPattern:)` of the ITLib persistent id (15,900/15,900). |
| 3.2 | `NSAppleEventsUsageDescription` says Music saves tag changes for songs with no file on this Mac | October 20, 2026: it now reads "OldTunes asks Music to save tag changes to songs in your Music library, to add songs to Music when you turn on “Also add to the Music app”, and to make, rename and delete the playlists you change in OldTunes." Tag saves go through Music for every Music-library song (the 6.5, 6.6 row), Add Folder can now add songs (§6.7), and the source list changes playlists (§6.8). `project.yml` generates the plist. |
| 3.6, 5.6 | Wrap MusicKit calls in a task-group timeout | A task group waits for every child, so a hung body still hangs the caller (0.3 s timeout returned after 2.1 s). `Support/Timeout.swift` races a continuation instead and abandons the body. |
| 5.3, 10-R3 | Cloud end-of-track: status leaves `.playing` while position ≥ duration − 1 | Never fires. Observed: `playbackTime` resets to 0.00 and status goes `.playing` → `.paused` in the same 100 ms tick, `currentEntry` still set. |
| 5 | Volume slider | MusicKit has no volume on macOS. During cloud songs the slider drives the default output device's volume via CoreAudio; during files, the AVPlayer's. |
| 6.2 | Write the year as `YYYY-01-01T00:00:00Z` | Midnight UTC saves year − 1 in MP3/AIFF/WAV here. Write `YYYY-01-01T12:00:00Z`. |
| 6.5, 6.6 | File-tag path for songs with a local file, Music.app only for cloud-only songs | Writing a Music-library song's file directly is undone by the next ingest (Music's database still has the old tags). Every Music-library song saves through Music.app; only added-folder files are written directly. |
| 7.2 | LCD 313 × 48 and search capsule 103 × 22, fixed widths | Noah's call, October 19, 2026: both grow with the window in the proportions of his iTunes 4 reference screenshot, measured on their middle rows (943 px window: LCD 414 px, search 133 px). So the LCD is 414/943 (43.9%) of the window width, still centred, and the search capsule 133/943 (14.1%), its right end still 79 pt from the window's. Neither gets narrower than 313 / 103, so windows up to 714 pt wide are unchanged. At 756: LCD 332, search 107. |
| 7.4 | LCD line 2 is "Artist — Album"; 4.9 shows no times | Both 4.9 references show `Elapsed Time: 0:45` / `Remaining Time: 26:32` on line 2. Default is elapsed; clicks cycle elapsed → remaining → artist — album. Scrubber interior unfilled. |
| 7.4, 8.3 | Scrollbars always visible (`autohidesScrollers = false`) | Noah's call, October 20, 2026: a scroller shows only when there is something to scroll. `RetroScrollView` sets `autohidesScrollers = true` for the track list, the browser panes and the source list, so a list that fits has no empty trough beside it, and the track list's horizontal scroller shows only while the columns are wider than the pane. A scroller that shows is unchanged: legacy, 15 pt, arrows at the bottom. When the vertical one hides, AppKit hides the header's corner square and the header runs to the pane's edge. The clip view's right and bottom insets are 15 only while both scrollers show; `unobscuredDocumentRect` is right in every case. |
| 7.5 | Title Lucida Grande Bold 12; pane headers Bold 11 | Pixel-checked: title is regular 13 (inks 40×10 px like the reference), pane headers regular 11. |
| 8.1, 8.4 | `NSTableView.style = .fullWidth` | `.fullWidth` pads the first and last columns (indicator 26 pt, not 18). Use `.plain`. |
| 8.1, 8.3 | (new) | macOS 27 runs the clip view under the header and legacy scrollers (contentInsets top 16, right 15, bottom 15); visibility math must subtract them. |
| 9 | Build checks grep `warning: .*OldTunes/` | xcodebuild prints the path before `warning:`; grep `OldTunes/.*warning:`. The original pattern hid real warnings. |
| 10-R4 | Music.app scripting writes are untested on this library | Resolved October 19, 2026, 10:45 PM PT, with Noah's approval: `OLDTUNES_HARNESS=musictag` saved a comment to a cloud-only song through the real TagEditor; Music's database showed it 1.4 s later via iTunesLibrary, and the restore landed 1.4 s after that. |

---

## 0. The three numbers that drive every decision

Measured on Noah's real library by signed probe apps, and re-counted here from the preserved dump at `/Users/noah/Library/Caches/songs.tsv`:

| Fact | Number | Consequence |
|---|---|---|
| Songs in the library | 15,900 (of 16,178 media items) | Everything fits in memory. |
| Songs that are a local file on this disk | **5** | The "local hard drive" half of the request is 5 songs. Do not architect around local files. |
| Songs that are cloud-only (no local file) | **15,895** | MusicKit `ApplicationMusicPlayer` is the player for 99.97% of the library. |
| Cloud songs with an Apple Music catalog id (`StoreItemID`) | **6,742** | So 9,153 cloud songs have **no** catalog id. A catalog-id-based playback design loses 58% of the library. |
| Songs with a MusicKit `playParameters` | **15,900 / 15,900** | This is the universal playback key. |
| `UInt64(bitPattern:)` join rate, MusicKit ↔ iTunesLibrary | **15,900 / 15,900 (100%)** | `persistentID` is the join key. Never match on title+artist+album. |
| Songs with artwork available | 10,277 | Artwork comes from iTunesLibrary, not the catalog. |
| `addedDate` span | 2006-06-19 10:26 PM PT → 2026-07-31 11:36 PM PT | A genuine 20-year library. |

Noah has an **Apple Music subscription**, not iTunes Match only: `MusicSubscription.current` reports `canPlayCatalogContent = true`, `canBecomeSubscriber = false`, `hasCloudLibraryEnabled = true`. The 9,153 songs with no catalog id are his own 2010–2011 rips, uploaded by Sync Library. Do not build an iTunes-Match-specific code path and do not tell him to buy iTunes Match.

---

## 1. Verdict on the hard requirement

**Yes. Playing a non-downloaded cloud track is proven, not theorized.** A signed probe app on this Mac played a cloud-only library song that had *no* catalog id at all: `prepareToPlay()` returned, `play()` returned no error, `playbackStatus == .playing`, and `playbackTime` advanced 0.34 → 1.07 → 1.81 → 2.53 s. Only 5 of 15,900 songs are on disk, so the audio was streaming. A matched track (one with a catalog id) played identically.

### Primary mechanism

```swift
// macOS 14.0+. The Song comes from MusicLibraryRequest<Song>, which returns
// cloud-only, non-downloaded songs by default.
let player = ApplicationMusicPlayer.shared
player.queue = ApplicationMusicPlayer.Queue(for: [song])
try await player.prepareToPlay()
try await player.play()
```

`Song.playParameters` is what makes this work. It is non-nil for all 15,900 songs and carries `{kind, id, isLibrary: true, musicKit_libraryID, musicKit_persistentID, musicKit_databaseID, catalogId?}`. The track that played had no `catalogId`, and `isLibrary` was true — so catalog entitlement is not what served the audio. Library playback does not go through the catalog.

### Fallback chain, with the exact condition for each step

Resolve a row to something playable in this order. The condition is evaluated per row at play time, not once at launch.

| Step | Condition to enter | Mechanism | If it fails |
|---|---|---|---|
| **1. Local file** | `song.fileURL != nil` **and** `FileManager.default.fileExists(atPath:)` | `AVQueuePlayer` with `AVPlayerItem(asset: AVURLAsset(url:))` | Go to step 2. Mark the row MISSING in the index. |
| **2. MusicKit library item** | `cloudSongs[persistentID] != nil` (the in-memory `[Int64: Song]` map built from `MusicLibraryRequest<Song>`) | `ApplicationMusicPlayer.shared` as above | Go to step 3. |
| **3. MusicKit catalog item** | `store_item_id != 0` **and** `MusicSubscription.current.canPlayCatalogContent == true` | `MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(String(storeItemID)))`, then queue the returned Song | Go to step 4. |
| **4. Unplayable** | everything above failed | Do not play. Advance the queue. Draw the row dimmed (`#999999`) with a slashed-cloud badge, and put the reason in Get Info. | — |

Step 1 is first, not step 2, because a local file cannot stall on the network and costs nothing. Step 3 exists only to cover rows that iTunesLibrary knows about but a `MusicLibraryRequest` did not return; measured, that set is currently empty (15,900 = 15,900), so step 3 is insurance, and it only helps the 6,742 songs that have a catalog id anyway.

### Where the subscription actually matters

Read `MusicSubscription.current` once at launch, behind a timeout (see §5.6 — it hung in a probe when unauthorized). Three cases, and the app behaves differently in each:

| State | What it means | What the app does |
|---|---|---|
| `hasCloudLibraryEnabled == true` (Noah today, with `canPlayCatalogContent == true`) | Sync Library is on. Full library, cloud playback works. | Normal operation. All four steps available. |
| `hasCloudLibraryEnabled == true`, `canPlayCatalogContent == false` | iTunes-Match-only subscriber. | **Run steps 1, 2, 4. Skip step 3** — a catalog fetch will not be playable. Library playback via `playParameters` is *expected* to work (the proven track had no catalog id and `isLibrary = true`), but this is not proven for a non-catalog subscriber; see §10-R2. Do not show a paywall. |
| `hasCloudLibraryEnabled == false` | Sync Library is off, or the subscription lapsed. | Cloud rows are unplayable. Show a one-time sheet: "Your iCloud Music Library is turned off, so OldTunes can only play the songs stored on this Mac. Turn on Sync Library in Music ▸ Settings ▸ General." Keep the 5 local songs playable. Do not offer to buy anything. |

### What we cannot do

**There is no download API.** `MusicLibrary.add(_:)`, `add(_:to:)`, `createPlaylist(...)` and both `edit(...)` overloads are every one of them `@available(macOS, unavailable)` in the macOS swiftinterface. On macOS, MusicKit is read-and-play only. The only on-demand download route is Music.app's AppleScript `download` command (code `hookDwnl`, access group `com.apple.Music.library.read-write`). Ship v1 **without** download. It is not in the requirement, it launches Music.app, and `hookDwnl` has never been invoked against this library (§10-R7).

---

## 2. Architecture

```
                    ┌──────────────────────────────────────────────┐
                    │  LibraryIngest  (actor, background)          │
                    │                                              │
  ITLibrary ───────▶│  ITLibSource      ─┐                         │
  (metadata,        │                    ├─▶ merge on              │
   artwork,         │  MusicKitSource   ─┘   persistent_id         │
   5 local paths)   │  (MusicLibraryRequest<Song>)                 │
  MusicKit ────────▶│                        │                     │
                    └────────────────────────┼─────────────────────┘
                                             │ 15,900 SongRow (Sendable)
                                             ▼
                    ┌──────────────────────────────────────────────┐
                    │  LibraryIndex  (final class, Sendable)       │
                    │  GRDB DatabasePool → index.sqlite (WAL)      │
                    │  song + song_fts (prefix) + song_tri         │
                    │  5 B-tree indexes on precomputed fold keys   │
                    └────────────────┬─────────────────────────────┘
                                     │ [Int64] id order, SongRow by id
                                     ▼
                    ┌──────────────────────────────────────────────┐
  cloudSongs ──────▶│  PlaybackCoordinator  (@MainActor)           │
  [Int64: Song]     │  order / shuffleOrder / cursor               │
  (in memory)       │        │                    │                │
                    │        ▼                    ▼                │
                    │  LocalTransport       CloudTransport         │
                    │  (AVQueuePlayer)      (ApplicationMusicPlayer)│
                    │        └──── PlaybackClock, 10 Hz ───┘       │
                    └────────────────┬─────────────────────────────┘
                                     │
                    ┌────────────────▼─────────────────────────────┐
                    │  AppKit UI  (@MainActor)                     │
                    │  MetalWindow → MetalContentView              │
                    │   ├ TitleBarView (own traffic lights)        │
                    │   ├ ControlBarView (transport, LCD, search)  │
                    │   ├ SourceListView  (NSTableView, 18pt rows) │
                    │   ├ TrackListView   (NSTableView, 17pt rows) │
                    │   └ BottomBarView                            │
                    └────────────────┬─────────────────────────────┘
                                     │ edit sheet
                    ┌────────────────▼─────────────────────────────┐
                    │  TagEditor  (actor)                          │
                    │  local file  → SFBAudioEngine + atomic swap  │
                    │  cloud only  → Music.app ScriptingBridge     │
                    └──────────────────────────────────────────────┘
```

**LibraryIngest (actor).** Owns the one and only `ITLibrary` instance and runs the whole ingest off the main thread. Opens with `ITLibrary(apiVersion: "1.0", options: .lazyLoadData)` (13 ms), then touches `allMediaItems` once on its own executor to absorb the 1.3–1.5 s parse, filters to `mediaKind == .kindSong` (4.3 ms), reads the typed properties (140 ms for all fields across 15,900 songs), computes the fold keys in Swift, and emits `[SongRow]`. In parallel it issues one `MusicLibraryRequest<Song>` and builds `[Int64: Song]`. Then it calls `unloadData()` to give back the 242 MB the loaded library holds, and re-inits on change notification. Must live in an `.app` bundle: `ITLibrary` talks to the `com.apple.amp.library.framework` XPC service and fails with `NSCocoaErrorDomain 4097` from a bare command-line binary even when correctly Developer-ID-signed.

**ITLibSource.** The metadata authority. iTunesLibrary exposes everything MusicKit does not: `bitrate`, `sampleRate`, `fileSize`, `kind` (the file-format string iTunes showed in Get Info), `comments`, `grouping`, `beatsPerMinute`, `skipCount`, `volumeAdjustment`, `location`, `locationType`, `isCloud`, and artwork. Read through the **typed** properties, never `valueForProperty` — typed is faster (6.7 ms vs 11.8 ms per 15.9k), more reliable, and the two disagree on some fields. The only exceptions are the undocumented keys with no typed property: `"StoreItemID"`, `"StorePlaylistID"`, `"AlbumPersistentID"`.

**MusicKitSource.** The *playability* authority. One `MusicLibraryRequest<Song>` with `limit` set above the library size returns everything (verified: `limit = 16000` → 15,900 items; `limit = 25000` → 15,900; there is no 10,000 ceiling). Each `Song` carries the `playParameters` that `ApplicationMusicPlayer` consumes. `Song` is `Sendable`, so the map crosses actor boundaries freely. Never call `includeOnlyDownloadedContent = true` as a "downloaded" filter — it changes which items come back, not just how many (it returns 12 items, 7 of which are podcast episodes absent from the default song set).

**LibraryIndex.** GRDB `DatabasePool` over `~/Library/Application Support/OldTunes/index.sqlite`. It exists for three jobs: as-you-type search, the four sorts, and surviving relaunch so the window shows rows before ingest finishes. It is a `final class … : Sendable` holding the pool rather than an `actor`, because `DatabasePool` is already concurrency-correct and gives parallel reads; an actor would serialize them for no benefit. Fallback: if Swift 6 complains about the `Sendable` conformance, wrap it in an `actor` and accept serialized reads — every measured query is under 8 ms, so it does not matter.

**PlaybackCoordinator (@MainActor).** Owns the queue as `[Int64]` of song ids plus a cursor, owns the shuffle permutation, and owns both transports. It decides per track which transport to use by running the §1 fallback chain, pauses the other transport before starting one, and is the single place that knows what "now playing" means. MusicKit's own `shuffleMode` and `repeatMode` are forced off so the cloud player can never advance behind its back.

**TagEditor (actor).** Two write paths, because 15,895 songs have no file to write to. For the 5 local files: SFBAudioEngine, into a sibling temp copy, swapped in with `FileManager.replaceItem`. For cloud-only songs: ScriptingBridge against Music.app's `track` class, which is read-write for every tag Noah asked about. SFBAudioEngine's classes are Objective-C and non-`Sendable`, so they never escape this actor.

**AppKit UI (@MainActor).** One `NSWindow` with `.fullSizeContentView` and a transparent titlebar, whose content view draws all of the 2005 chrome itself. Two `NSTableView`s with different row heights (18 pt source, 17 pt track) and *different selection treatments* — that difference is the single most common tell in retro-iTunes mockups. Nothing stock: `NSButton`, `NSSearchField`, `NSSegmentedControl` and `NSToolbar` all render as 2026 Liquid Glass controls no matter what appearance is forced, and there is no opt-out (`UIDesignRequiresCompatibility` and `NSRequiresAquaSystemAppearance` appear nowhere in Xcode 27 or the SDK).

---

## 3. Project configuration

### 3.1 Sandbox decision: **non-sandboxed, hardened runtime, Developer ID.**

Both frameworks work sandboxed — `/System/Library/Sandbox/Profiles/frameworks.sb` lines 324–341 auto-grant `mach-lookup` to `com.apple.amp.library.framework` and `com.apple.amp.artworkd` to any app that merely links iTunesLibrary or MusicKit, and `com.apple.security.assets.music.read-only` grants recursive read of `~/Music`. Sandboxing is *possible*. We are not doing it, for one reason that actually bites:

**Tag writing needs write access to arbitrary file locations.** Songs outside `~/Music` (an external drive, a custom folder) are not covered by the music-assets entitlement at all; each one needs a user-selected open-panel grant and a persisted security-scoped bookmark, and symlinked or aliased library folders on other volumes have historically failed with `OSStatus -54`. This is a personal Developer-ID app, not a Mac App Store submission, so there is no review requirement to sandbox.

Two arguments *against* sandboxing that the research raised do **not** hold and should not be repeated: Music.app's sdef does declare access groups (92 of them; `track` at line 410 carries `com.apple.Music.library.read-write`), so a sandboxed app could script it through `com.apple.security.scripting-targets` without a temporary exception. And `com.apple.security.assets.music.read-only` does cover the real media tree. Sandboxing stays off because of the file-write reach, nothing else.

If we ever do sandbox, the entitlements are: `app-sandbox`, `network.client`, `assets.music.read-write`, `files.user-selected.read-write`, and `scripting-targets = {"com.apple.Music": ["com.apple.Music.library.read-write", "com.apple.Music.playback"]}`. Do **not** add a `temporary-exception.mach-lookup`; `frameworks.sb` already covers it.

### 3.2 Info.plist — `/Users/noah/Projects/iJustWantToListenToMyOldMusic/OldTunes/App/Info.plist`

Exactly **one** privacy key unlocks both MusicKit and iTunesLibrary. `kTCCServiceMediaLibrary` maps to `NSAppleMusicUsageDescription` and to no entitlement at all — unlike Camera and Microphone, which each pair with a hardened-runtime entitlement. The prompt text on macOS 27 is: *Allow "OldTunes" to access your music, video activity, and media library in Apple Music?* and the Settings pane is **Privacy & Security ▸ Media & Apple Music**.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>          <string>$(DEVELOPMENT_LANGUAGE)</string>
	<key>CFBundleDisplayName</key>                <string>OldTunes</string>
	<key>CFBundleExecutable</key>                 <string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key>                 <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
	<key>CFBundleName</key>                       <string>OldTunes</string>
	<key>CFBundlePackageType</key>                <string>APPL</string>
	<key>CFBundleShortVersionString</key>         <string>1.0</string>
	<key>CFBundleVersion</key>                    <string>1</string>
	<key>LSApplicationCategoryType</key>          <string>public.app-category.music</string>
	<key>LSMinimumSystemVersion</key>             <string>$(MACOSX_DEPLOYMENT_TARGET)</string>
	<key>NSHighResolutionCapable</key>            <true/>
	<key>NSPrincipalClass</key>                   <string>NSApplication</string>

	<key>NSAppleMusicUsageDescription</key>
	<string>OldTunes reads your music library so it can list, search and play your songs, including the ones stored in iCloud.</string>

	<key>NSAppleEventsUsageDescription</key>
	<string>OldTunes asks Music to save tag changes for songs that live in iCloud and have no file on this Mac.</string>
</dict>
</plist>
```

`NSAppleEventsUsageDescription` is required because the tag editor scripts Music.app. It triggers a **second, separate TCC prompt (Automation)**, which is why the editor asks for it lazily on the first cloud-track edit, not at launch (§6.4).

**Do not use `INFOPLIST_KEY_NSAppleMusicUsageDescription`.** That build setting only does anything when `GENERATE_INFOPLIST_FILE = YES`; the xcspec text is explicit about the condition. This project has a hand-written `INFOPLIST_FILE`, so the build setting would be silently ignored — and the failure mode is the worst one available: `ITLibrary` still returns a live object, `mediaFolderLocation` is nil, `allMediaItems.count` is 0, and nothing errors.

Caveat on the existing `project.yml`: it declares `info: path: … properties: {…}`, which makes xcodegen **generate** that file and overwrite the hand-written one. Keep the two in sync, or (preferred) delete the `properties:` block from `project.yml` and let the checked-in plist be the source of truth.

### 3.3 Entitlements — `/Users/noah/Projects/iJustWantToListenToMyOldMusic/OldTunes/App/OldTunes.entitlements`

There is **no entitlement for MusicKit and no entitlement for media-library access.** A grep for `com.apple.developer.musickit*` across Xcode 27 and MacOSX27.sdk returns nothing, and MusicKit is absent from Xcode's cached portal capability list. The only hardened-runtime resource entitlements tccd knows about are camera, audio-input, addressbook, calendars, photos-library and automation.apple-events. So the whole file is two keys:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>              <false/>
	<key>com.apple.security.automation.apple-events</key>  <true/>
</dict>
</plist>
```

`project.yml` currently has `entitlements: properties: {}`, which regenerates an empty dict. Change it to:

```yaml
    entitlements:
      path: OldTunes/App/OldTunes.entitlements
      properties:
        com.apple.security.app-sandbox: false
        com.apple.security.automation.apple-events: true
```

Hardened runtime is already on (`ENABLE_HARDENED_RUNTIME: YES`). Keep it: TCC keys a grant to the bundle id **plus the code's designated requirement**, and a stable signature is what makes the grant survive rebuilds.

### 3.4 Developer portal — the only steps a human must do by hand

On Noah's Mac, in Safari, at <https://developer.apple.com/account/resources/identifiers/list>:

1. **+** → App IDs → App → Description `OldTunes`, Bundle ID **Explicit** = `com.noahtsutsui.oldtunes` (must equal `PRODUCT_BUNDLE_IDENTIFIER` exactly; a wildcard App ID will not do).
2. Open that App ID → **App Services** tab → tick **MusicKit** → Save → Register.
3. Nothing else. No provisioning profile edit, no Xcode capability to add.

**Do not create** a MusicKit identifier, a Media ID, a Media Services key, or a `.p8` file. Those are only for MusicKit JS, Android, and raw Apple Music REST. Native Swift MusicKit mints and injects the developer token itself: *"a runtime service that automatically associates with your app's bundle identifier."* The `.gitignore` already excludes `*.p8`; there will never be one.

Honest note: a probe worked with plain Developer ID signing and **no** MusicKit App Service for *library* requests and library playback. The App Service may only be needed for catalog requests (fallback step 3, and catalog artwork). Do the portal step anyway — it is five minutes, costs nothing, and removes the question. If it somehow cannot be done, library playback still works and only fallback step 3 is lost.

### 3.5 Signing — Team 92N52YB23U

There are **three** identities on this machine, not two, and two of them begin "Apple Development", so `codesign --sign "Apple Development"` fails with *ambiguous* and then silently leaves an ad-hoc linker-signed bundle that gets no TCC consent:

```
Apple Development: <Apple ID email> (EK65SK5S25)
Apple Development: Noah Tsutsui (H3ZP723CJJ)
Developer ID Application: Noah Tsutsui (92N52YB23U)
```

Always pass the full identity string. Dev loop — on Noah's Mac, from `/Users/noah/Projects/iJustWantToListenToMyOldMusic`:

```bash
cd /Users/noah/Projects/iJustWantToListenToMyOldMusic
xcodegen generate
xcodebuild -project OldTunes.xcodeproj -scheme OldTunes -configuration Debug \
  -derivedDataPath build/dd build
codesign --force --options runtime --timestamp \
  --entitlements OldTunes/App/OldTunes.entitlements \
  --sign "Apple Development: Noah Tsutsui (H3ZP723CJJ)" \
  build/dd/Build/Products/Debug/OldTunes.app
codesign -dvv build/dd/Build/Products/Debug/OldTunes.app 2>&1 | grep TeamIdentifier
open build/dd/Build/Products/Debug/OldTunes.app
```

That `grep` must print `TeamIdentifier=92N52YB23U` before you trust a test run. Shipping build: same command with `--sign "Developer ID Application: Noah Tsutsui (92N52YB23U)"`, then `--deep` verify and notarize. When SFBAudioEngine is added, its 10 `@rpath` frameworks in `Contents/Frameworks` must each be signed with the same identity before notarization, or the app will not launch on a clean machine.

**Never ad-hoc sign during development.** `codesign --sign -` falls back to the cdhash, which changes every build, so the Media & Apple Music grant is destroyed on every rebuild and the app silently reports `.denied` all day.

### 3.6 Permission handling — the single most expensive bug available

Three distinct lies the system tells, all of which must be handled before any UI work:

1. **`ITLibrary` init succeeds when it has no permission.** It returns a non-nil object with `applicationVersion = 13.7.0.163`, `apiMajorVersion = 1`, `mediaFolderLocation = nil`, `allMediaItems.count = 0`, and quietly sets the error out-parameter to `NSCocoaErrorDomain 4097 "connection to service named com.apple.amp.library.framework"`. Apple's docs claim the system terminates the app here; on macOS 27 it does not. Treat ingest as FAILED if *any* of: error non-nil, `mediaFolderLocation == nil`, or `allMediaItems.count == 0`.
2. **`MusicAuthorization.currentStatus` returns `.denied`, not `.notDetermined`, when the Info.plist key is missing.** So a misconfigured app looks exactly like one the user refused, and no prompt will ever appear however often you call `request()`. Verify the key is in the **built** `Info.plist`, not just in the project file.
3. **`MusicLibrarySearchRequest.response()` hangs forever when unauthorized** (killed at 30 s). `MusicLibraryRequest.response()` throws `.permissionDenied` promptly. `MusicSubscription.current` also hung. Every MusicKit call gets a timeout (§5.6).

Re-prompting after denial is impossible — TCC never asks twice — and **the grant does not take effect until the app is relaunched**. macOS's own Settings wording is that the app *"will have access … until it is quit."* So the denial sheet says *quit and reopen*, never *retry*:

```swift
// Button action. The legacy anchor is unconfirmed on macOS 27 (§10-R8), so fall back.
let anchored = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media")!
if !NSWorkspace.shared.open(anchored) {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
}
```

Do not ask for Full Disk Access. It is a much larger ask and it is not what unblocks this.

### 3.7 Swift Package dependencies — `project.yml`

```yaml
packages:
  GRDB:
    url: https://github.com/groue/GRDB.swift
    from: 7.11.1
  SFBAudioEngine:
    url: https://github.com/sbooth/SFBAudioEngine
    from: 0.14.0

targets:
  OldTunes:
    dependencies:
      - package: GRDB
        product: GRDB
      - package: SFBAudioEngine
        product: SFBAudioEngine
```

Both versions were resolved and built on this machine: GRDB 7.11.1 built clean in 31.85 s against Swift 6.4 / arm64-apple-macosx27.0.0 and reports `sqlite_version 3.54.0`; SFBAudioEngine 0.14.0 built in 26.74 s. These are the only versions confirmed to exist and work — do not float them upward without rebuilding.

---

## 4. Data model and search

### 4.1 System SQLite, and what it can and cannot do

3.54.0, both the CLI and the library an app links. Compile options include `ENABLE_FTS5` and the **trigram** tokenizer is available (it accepts `remove_diacritics 0/1/2` and `case_sensitive 0/1`). **ICU is not** — `no such tokenizer: icu`, and no `icu_load_collation`. That single absence is why all collation keys are computed in Swift and stored: `COLLATE NOCASE` is ASCII-only and would mis-sort all 263 artists with diacritics.

### 4.2 DDL, verbatim

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous  = NORMAL;
PRAGMA cache_size   = -65536;      -- 64 MiB
PRAGMA temp_store   = MEMORY;
PRAGMA mmap_size    = 268435456;   -- 256 MiB

CREATE TABLE song (
  id               INTEGER PRIMARY KEY,
  -- Int64 bit pattern of the UInt64 persistent id. This is the join key between
  -- iTunesLibrary and MusicKit; 100% match rate on 15,900 songs. UInt64 values here
  -- exceed 2^63 (e.g. 12345678901234567890), so the bit pattern is stored, not the value.
  persistent_id    INTEGER UNIQUE,
  -- MusicKit Song.id.rawValue, for rebuilding the play map and for debugging.
  cloud_id         TEXT,
  -- Apple Music catalog adamID from valueForProperty("StoreItemID"). 0 = none (9,158 rows).
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
  -- Unix seconds. 0 means "unknown" (52 songs). NOT NULL keeps ix_added a clean
  -- integer index; 0 sorts last under DESC, which is what "recently added" wants.
  added_at         INTEGER NOT NULL DEFAULT 0,
  play_count       INTEGER NOT NULL DEFAULT 0,
  rating           INTEGER NOT NULL DEFAULT 0,

  -- 0 LOCAL, 1 CLOUD, 2 MISSING. Classified once at ingest.
  bucket           INTEGER NOT NULL DEFAULT 1,
  is_cloud         INTEGER NOT NULL DEFAULT 0,
  location_type    INTEGER NOT NULL DEFAULT 0,   -- ITLibMediaItemLocationType raw
  location_path    TEXT,                          -- NULL for 15,895 of 15,900 rows
  has_artwork      INTEGER NOT NULL DEFAULT 0,
  album_pid        INTEGER NOT NULL DEFAULT 0,    -- artwork dedupe key
  kind             TEXT NOT NULL DEFAULT '',      -- "MPEG audio file", for Get Info
  bit_rate         INTEGER NOT NULL DEFAULT 0,
  sample_rate      INTEGER NOT NULL DEFAULT 0,
  file_size        INTEGER NOT NULL DEFAULT 0,

  -- Fold keys. BINARY collation (the default) is exactly the byte compare these want.
  -- Never declare COLLATE NOCASE on these columns.
  -- Blank values are stored as U+10FFFF (SortKey.blank), never '', so they sort last.
  sk_title         TEXT NOT NULL DEFAULT '',
  sk_artist        TEXT NOT NULL DEFAULT '',
  sk_album         TEXT NOT NULL DEFAULT '',
  sk_album_artist  TEXT NOT NULL DEFAULT ''
);

CREATE INDEX ix_title  ON song(sk_title, sk_artist, id);
CREATE INDEX ix_artist ON song(sk_artist, sk_album, disc_number, track_number, id);
CREATE INDEX ix_album  ON song(sk_album, disc_number, track_number, id);
CREATE INDEX ix_added  ON song(added_at DESC, id);
CREATE INDEX ix_bucket ON song(bucket, location_type);

-- 1-2 character queries. External content: stores no duplicate text.
CREATE VIRTUAL TABLE song_fts USING fts5(
  title, artist, album, album_artist, composer, genre,
  content='song', content_rowid='id',
  tokenize="unicode61 remove_diacritics 2",
  prefix='1 2 3',
  detail=column);

-- 3+ character queries, including mid-word.
CREATE VIRTUAL TABLE song_tri USING fts5(
  title, artist, album, album_artist, composer, genre,
  content='song', content_rowid='id',
  tokenize="trigram remove_diacritics 1");
```

After the first ingest, on the same connection: `INSERT INTO song_fts(song_fts) VALUES('rebuild'); INSERT INTO song_tri(song_tri) VALUES('rebuild'); ANALYZE;` — `ANALYZE` is what makes the planner choose `ix_title` instead of building a temp b-tree.

Create `song_fts` through GRDB's typed API (`FTS5()`, `.unicode61(diacritics: .remove)`, `t.prefixes = [1,2,3]`) and `song_tri` with raw `db.execute(sql:)`, because trigram is not in GRDB's tokenizer enum.

**Why both FTS tables, and not a choice between them.** Proven on 47,700 real rows: a prefix index cannot match mid-word at all (`'nderw*'` → **0** rows; trigram `'nderw'` → 249 rows; `'asis*'` → 0, trigram `'asis'` → 24). And trigram requires 3 characters (`MATCH 'lo'` → 0 rows). Ship only the prefix index and typing the middle of a word looks broken; ship only trigram and the first two keystrokes show nothing. Both costs +12.9 MB and keeps every path under 1 ms. Measured on-disk footprint at 47.7k rows: `song` 9,836 KB, `song_fts` 11,256 KB, `song_tri` 12,880 KB, the five B-trees 7,460 KB — 47 MB total. At Noah's 15,900 that is roughly 16 MB.

`detail=column` is chosen deliberately: 14.6 MB vs 19.4 MB for `detail=full` and 8.4 MB for `detail=none`. It keeps field-scoped search (`artist:stevie*`) and bm25 ranking and gives up phrase queries, which a music search box does not need — multi-word input becomes AND-ed prefix tokens instead. Decide now: changing `detail=` later means a full FTS rebuild. `detail=none` is the trap, because `artist:stevie*` silently returns nothing rather than erroring.

Index build cost at 47.7k rows: 166 ms insert + 116 ms B-trees + 356 ms prefix FTS + 382 ms trigram FTS ≈ 1.0 s. At 15,900 expect ~340 ms, so a full re-ingest is cheap enough to do unconditionally rather than writing a diff.

### 4.3 Sort-key strategy

Keys are computed in Swift at ingest and stored. The already-written `/Users/noah/Projects/iJustWantToListenToMyOldMusic/OldTunes/Model/SortKey.swift` is correct and is the implementation: it folds case/diacritics/width, trims, strips a leading `the `/`a `/`an `, strips leading punctuation, zero-pads digit runs to 8 characters, and returns `U+10FFFF` for blank. That padding is what gives natural ordering ("Track 2" before "Track 10") **without** `localizedStandardCompare`, which costs 227 ms on 50k rows — 26× a plain `String <` and 177× an `Int64` key. Never put it in a comparator.

Two changes to make to the file's use, not the file:

- Prefer the library's own sort field when it exists, and fall back to the computed key. The library's fields are mostly nil, so this is a small but real fidelity win: `sortTitle` is non-nil on 1,036 of 15,900 songs (6.5%), `artist?.sortName` on 1,602 (10%), `album?.sortTitle` on 2,103 (13%).
  ```swift
  sk_title        = SortKey.make(item.sortTitle ?? item.title)
  sk_artist       = SortKey.make(item.artist?.sortName ?? item.artist?.name ?? "")
  sk_album        = SortKey.make(item.album?.sortTitle ?? item.album?.title ?? "")
  sk_album_artist = SortKey.make(item.album?.sortAlbumArtist ?? item.album?.albumArtist ?? "")
  ```
  Note the shapes: **`sortArtist` and `sortAlbum` do not exist on `ITLibMediaItem`** and will not compile. The item has only `sortTitle` and `sortComposer`; the rest live on the related objects — `ITLibArtist.sortName`, `ITLibAlbum.sortTitle`, `ITLibAlbum.sortAlbumArtist`. Likewise `albumArtist`, `discNumber`, `discCount`, `trackCount` and `isCompilation` are on `ITLibAlbum`, not on the item. And `ITLibAlbum.artist` is `DEPRECATED_ATTRIBUTE` — use `item.artist`.
- The DDL's `DEFAULT ''` must never be the value actually written for a blank. Write `SortKey.blank` (`U+10FFFF`), or blanks sort first instead of last. 320 songs have no artist and 1,076 have no album, so this is visible immediately.

Sorting the raw column instead costs 150–250× for the same first page: `ORDER BY title COLLATE NOCASE` = 3.135 ms and `ORDER BY lower(title)` = 5.462 ms, against 0.021 ms off `ix_title`. Any function in `ORDER BY` defeats the index entirely.

### 4.4 Exact query shapes

**(a) As-you-type search.** Route by trimmed input length. Measured medians over 47,700 rows joined and sorted with `LIMIT 100`: `'o*'` 2.537 ms, `'oa*'` 0.151 ms, `'oas*'` 0.023 ms, `'oasis*'` 0.024 ms, `artist:'stevie*'` 0.019 ms; trigram `'nderw'` 0.194 ms, `'oasis'` 0.049 ms, `'wonder'` 0.191 ms.

```sql
-- 1-2 characters: prefix table
SELECT s.id FROM song_fts f JOIN song s ON s.id = f.rowid
 WHERE song_fts MATCH :q          -- '"o"*'   or   '"st"* "wo"*'
 ORDER BY s.sk_title, s.id
 LIMIT 500;

-- 3+ characters: trigram table (matches mid-word)
SELECT s.id FROM song_tri f JOIN song s ON s.id = f.rowid
 WHERE song_tri MATCH :q          -- '"oasis"'   or   '"wonder" "wall"'
 ORDER BY s.sk_title, s.id
 LIMIT 500;
```

Build `:q` by splitting the input on whitespace, wrapping each token in double quotes with any internal `"` doubled (this neutralises every FTS5 syntax character), and joining with a space (= AND). Append `*` to each quoted token for the prefix table only; `*` is meaningless on trigram. Keep the `ORDER BY` column in step with whatever sort the header shows.

Search+sort always needs `USE TEMP B-TREE FOR ORDER BY`, because FTS5 yields rowid order. That is fine — worst realistic case, prefix `'a*'` matching 20,712 rows fully sorted with no limit, is 7.632 ms median / 8.464 ms p95 — but it means latency scales with **match count, not with `LIMIT`**. Keep a `LIMIT` on the interactive path and only materialize everything when the user actually scrolls to the end.

Debounce 140 ms, and only the 1-character case genuinely needs it: `'o*'` is the one query over 1 ms. Cancel the in-flight task on each keystroke (§8.4).

**(b) The four sorts.** Each is one statement returning the whole id order; at 47.7k rows materializing the full list costs 1.2–1.5 ms, so there is no paging logic and no cache to invalidate.

```sql
-- Name           (ix_title)
SELECT id FROM song ORDER BY sk_title, sk_artist, id;
-- Artist         (ix_artist)  -- within an artist, album then disc then track, like iTunes
SELECT id FROM song ORDER BY sk_artist, sk_album, disc_number, track_number, id;
-- Album          (ix_album)
SELECT id FROM song ORDER BY sk_album, disc_number, track_number, id;
-- Date Added     (ix_added)   -- newest first; added_at = 0 (unknown, 52 songs) sorts last
SELECT id FROM song ORDER BY added_at DESC, id;
```

The trailing `id` makes every order total, so paging can never duplicate or skip a row. Descending is `Array.reverse()` in Swift — 0.02 ms, measured — not a second query. Do **not** cache 8 order arrays per (column, direction): the first sort of a column is 1–9 ms, comfortably inside one 16.7 ms frame, so the cache solves a sub-frame problem.

Add `WHERE` to any of these to scope to a playlist or the search result; the index still drives the `ORDER BY`.

**(c) Shuffle.** In Swift, over the already-materialized id array:

```swift
var shuffleOrder = order
shuffleOrder.shuffle()                  // Fisher-Yates, microseconds
if let nowPlaying, let i = shuffleOrder.firstIndex(of: nowPlaying) {
    shuffleOrder.swapAt(0, i)           // keep the current song playing, like iTunes
}
```

Never `ORDER BY random()`. It measured 12.255 ms median / 13.007 ms p95 on 47.7k rows — the single slowest query in the whole benchmark, with nothing to spare inside a frame, and it gives no stable queue to show the user. Shuffling in Swift is free and the permutation can be displayed and re-entered.

---

## 5. Playback

### 5.1 The abstraction

```swift
enum Playable: Sendable {
    case local(URL)
    case cloud(Song)            // MusicKit Song; Sendable
}

enum TransportError: Error { case unsupported, notPlayable }

@MainActor
protocol Transport: AnyObject {
    func load(_ what: Playable) async throws
    func play() async throws
    func pause()
    func stop()                             // releases the resource
    func seek(to seconds: TimeInterval)

    var position: TimeInterval { get }      // polled at 10 Hz, never KVO'd
    var duration: TimeInterval { get }
    var isPlaying: Bool { get }
    var volume: Float { get set }           // 0...1

    var onFinish: (() -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
}
```

Both transports are `@MainActor`-confined by convention. That is not decoration: `AVPlayer` is `NS_SWIFT_UI_ACTOR` at class level, and `ApplicationMusicPlayer` is **not** `Sendable` and carries **zero** `@MainActor` annotations anywhere in the macOS swiftinterface — Swift 6 will happily let you touch `.shared` from a background actor with no diagnostic. The compiler will not protect you here. One rule: every `ApplicationMusicPlayer` access is on the main actor.

### 5.2 LocalTransport — `AVQueuePlayer`

Handles ALAC/AAC/MP3/AIFF/WAV natively. Construct items as `AVPlayerItem(asset: AVURLAsset(url:))` — `AVURLAsset` is `Sendable`, `AVAsset` is not, so this is the shape that builds off the main actor if you ever need it to.

- `actionAtItemEnd = .none` and observe `AVPlayerItem.didPlayToEndTimeNotification` → `onFinish()`. The coordinator, not the player, decides what comes next.
- When the *next* queue entry is also local, `insertItem(_:after:)` it so decoding of track N+1 overlaps playback of N. That is the closest thing to gapless available without a custom decode path. With 5 local songs this almost never fires; keep the code, it is six lines.
- `volume`, `rate`, `currentTime()`, `insertItem`, `advanceToNextItem`, `removeAllItems` are all `NS_SWIFT_NONISOLATED`, so they are callable from anywhere — which is exactly why the one-rule discipline matters.

### 5.3 CloudTransport — `ApplicationMusicPlayer`

```swift
func load(_ what: Playable) async throws {
    guard case .cloud(let song) = what else { throw TransportError.unsupported }
    let p = ApplicationMusicPlayer.shared
    p.state.shuffleMode = .off
    p.state.repeatMode  = MusicPlayer.RepeatMode.none   // fully qualified, see below
    p.queue = ApplicationMusicPlayer.Queue(for: [song]) // ONE entry, always
    try await p.prepareToPlay()
}
```

Three hard-won details:

1. **`shuffleMode` and `repeatMode` live on `.state`, not on the player.** `ApplicationMusicPlayer.shared.shuffleMode` does not compile.
2. **`state.repeatMode = .none` is a bug that compiles.** The property is `MusicPlayer.RepeatMode?` and `RepeatMode` itself has a case named `none`, so a bare `.none` resolves to `Optional.none` and writes nil — not "don't repeat". swiftc emits only a warning. Write `MusicPlayer.RepeatMode.none`, fully qualified, and treat that warning as an error in this file.
3. **`SystemMusicPlayer` does not exist on macOS.** It is `@available(macOS, unavailable)` and will not compile, despite a plausible-looking stub in the swiftinterface. Only `ApplicationMusicPlayer`, and only macOS 14+.

A **one-entry queue** is deliberate. Combined with shuffle/repeat off, the cloud player can never advance on its own, so "now playing" can never desync from what is audible.

End-of-track detection is the weak spot: MusicKit gives no finish callback. The 10 Hz clock watches for `state.playbackStatus` leaving `.playing` while `position >= duration - 1.0` and fires `onFinish()` once, guarded by a flag so it cannot double-fire. This is the least-proven piece of the playback design — see §10-R3.

Also known and not worth fighting: `ApplicationMusicPlayer.transition` (crossfade) is `@available(macOS, unavailable)`, and the player ignores `AVRoutePickerView` / AirPlay route selection and keeps playing through the Mac's speakers (FB13521393, unresolved). Do not promise crossfade or AirPlay.

### 5.4 The unified queue and shuffle

`PlaybackCoordinator` is `@MainActor` and owns:

```swift
private var order: [Int64]          // the visible, sorted, filtered id list
private var shuffleOrder: [Int64]   // Fisher-Yates permutation of `order`
private var isShuffling = false
private var cursor = 0              // index into whichever array is live
private var active: Transport?      // LocalTransport or CloudTransport
```

`advance(by: Int)`:

1. Move the cursor; stop at the ends unless repeat-all is on.
2. Fetch the `SongRow` for that id from `LibraryIndex`.
3. Run the §1 fallback chain to get a `Playable`, or nothing.
4. If nothing: mark the row unplayable and recurse with the same direction (with a guard so a run of unplayable rows cannot loop forever).
5. `inactive.stop()` **before** `active.load()`. Two live transports means two audio streams; this is the one ordering that must not be got wrong.
6. `try await active.load(playable)` then `play()`.

Shuffle spans both engines for free, because the queue is ids and the transport is chosen per track. Gapless across a local→cloud boundary is **not** achievable — there is no shared queue abstraction and MusicKit has no transition control on macOS. State that in the UI only by not promising it.

When the user re-sorts or searches, `order` is replaced and `cursor` is re-found by id, so the currently playing song keeps playing and the queue simply re-reads around it.

### 5.5 Time and scrubbing

**One 10 Hz `MainActor` timer drives both transports.** `PlaybackClock` ticks every 0.1 s while `active?.isPlaying == true`, reads `active.position`, and updates the LCD text and the scrubber thumb. Two reasons for one path instead of two: the scrubber is 240 pt wide, so for a 3-minute song one pixel is 0.75 s and 10 Hz is six times more resolution than the widget can show; and a single code path cannot drift between engines.

- `LocalTransport.position` = `player.currentTime().seconds`. `AVPlayer.currentTime()` is explicitly documented as not key-value observable.
- `CloudTransport.position` = `ApplicationMusicPlayer.shared.playbackTime`, which is a plain settable `TimeInterval` — there is no observer at all, which is the other reason to poll.

Dragging the scrubber: suspend clock-driven updates on `mouseDown`, track the thumb against the local value, and commit on `mouseUp`:

- local → `player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)`
- cloud → `ApplicationMusicPlayer.shared.playbackTime = t`

Fallback if 10 Hz looks steppy on local files: add `addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main)` for the local path only and let the clock keep driving cloud. Do not do this first; one path is worth more than 30 Hz.

### 5.6 Timeouts on every MusicKit call

`MusicLibrarySearchRequest.response()` and `MusicSubscription.current` both hang indefinitely when unauthorized. Route every MusicKit await through:

```swift
func withTimeout<T: Sendable>(_ seconds: Double,
                              _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TransportError.notPlayable }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}
```

5 s for subscription and search, 20 s for the one big `MusicLibraryRequest`. Without this, a permission problem is a permanent beachball on first run — and instant search over the whole library is the headline feature.

Do not use `MusicLibrarySearchRequest` for the search box at all. Load all 15,900 songs once and search the SQLite index; that is the only way to get keystroke latency, and it covers non-downloaded cloud tracks for free.

---

## 6. Metadata editing

### 6.1 The shape of the problem

Neither reading framework can write. Every one of `ITLibMediaItem`'s 49 properties is `readonly`, and Apple states iTunes library access *"is read-only"*. MusicKit is worse than read-only on macOS: `MusicLibrary`'s `shared` exists but **every** method — `add(_:)`, `add(_:to:)`, both `createPlaylist` overloads, both `edit` overloads — is `@available(macOS, unavailable)`. So there is no MusicKit write path for tags and no MusicKit path to add songs or build playlists either.

And for Noah's library specifically, **the file-tag path serves 5 songs.** Music.app scripting is the primary editor here, not the fallback. Build it first.

### 6.2 Local files — SFBAudioEngine 0.14.0

```
.package(url: "https://github.com/sbooth/SFBAudioEngine", from: "0.14.0")
// product: .product(name: "SFBAudioEngine", package: "SFBAudioEngine")
// Pin exactly for reproducibility: .package(url: …, exact: "0.14.0")
```

MIT, released 2026-09-14, built clean here in 26.74 s. Its taglib dependency pins to CXXTagLib 2.3.2 (= taglib 2.3.2). taglib is dual LGPL-2.1-or-later / MPL-1.1 and CXXTagLib ships the MPL 1.1 text — elect MPL-1.1 and there is no copyleft-on-linking obligation. The LGPL pieces (lame, mpg123, sndfile, the Musepack encoder) are dynamically linked as separate frameworks, which is already the compliant arrangement.

```swift
let f = try AudioFile(readingPropertiesAndMetadataFrom: url)
f.metadata.title = "…"                       // .artist .albumTitle .albumArtist .composer
f.metadata.genre = "…"                       // .comment .grouping .lyrics
f.metadata.trackNumber = 3                   // Swift overlay: Int?, not NSNumber
f.metadata.isCompilation = false             // Swift overlay: Bool?, not `compilation`
f.metadata.releaseDate = "2005-01-01T00:00:00Z"   // see the trap below
f.metadata.removeAllAttachedPictures()
f.metadata.attachPicture(AttachedPicture(imageData: png, type: .frontCover, description: "cover"))
try f.writeMetadata()
```

Use the Swift overlay names — `isCompilation`, `trackNumber`, `trackTotal`, `discNumber`, `discTotal`, `bpm`, `rating` as `Int?`/`Bool?`. The Objective-C `compilation`/NSNumber names are hidden behind double underscores.

**The year trap, and it causes silent data loss.** `SFBAudioMetadata+TagLibID3v2Tag.mm:337` calls `tag->removeFrames("TDRC")` unconditionally and only re-adds the frame inside `if (date != nil)`, where `date` comes from a bare `NSISO8601DateFormatter` that returns nil for anything short of a full timestamp. So `releaseDate = "2005"` removes the year and writes nothing, with no error. Measured: MP3 and AIFF drop `"2005"`, `"2005-06"` and `"2005-06-01"` entirely; WAV keeps `"2005"` only because it also writes the RIFF INFO tag when the file has one; M4A/ALAC/FLAC keep partial strings verbatim. **Always write a full ISO-8601 timestamp.** Show a plain 4-digit Year box in the UI and save `"\(year)-01-01T00:00:00Z"`. With that, all six formats round-trip all 15 fields plus artwork — the AIFF/WAV exception the research first reported does not exist.

Worth a 3-line upstream PR to accept bare `YYYY` and `YYYY-MM-DD`; not a blocker.

### 6.3 Per-format support

| Format | Read | Write | Notes |
|---|---|---|---|
| MP3 (ID3v2) | yes | yes | Year needs the full timestamp. `.mp3` is the one local file here. |
| M4A / AAC | yes | yes | Full round-trip including partial dates. |
| M4A / ALAC | yes | yes | Same. |
| AIFF | yes | yes | ID3v2 only, so the year trap applies. |
| WAV | yes | yes | Year survives a partial date when a RIFF INFO chunk exists. |
| FLAC | yes | yes | Vorbis comments; dates verbatim. |
| **.m4p** (FairPlay) | **no** | **no** | Not in SFBAudioEngine's extension list; AVFoundation will not decrypt. Detect and say so plainly. |
| **.m4b** (audiobook) | **no** | **no** | Not supported. |
| Cloud-only (no file) | via ITLibrary | **Music.app only** | 15,895 rows. §6.4. |

Supported extensions, read from the built binary: `aif aiff ape dff dsf flac it m4a m4r mod mp3 mp4 mpc oga ogg opus s3m shn spx tta wav wave wv xm`.

Do not use AVFoundation for writing. `AVAssetWriter` cannot output MP3 at all — `initWithURL:fileType:AVFileTypeMPEGLayer3` throws `NSInvalidArgumentException` and kills the process rather than returning an error, because MP3 is a read-only type. `AVAssetExportSession` with Passthrough never lists MP3 or FLAC in `supportedFileTypes` regardless of the source, and it writes the `metadata` array verbatim with no dedupe — appending an edited title produces a single `©nam` atom with two `data` payloads, which readers then join into `"Old Title, New Title"`. And `AudioToolbox`'s `kAudioFilePropertyInfoDictionary` measured `isWritable == 0` on all six formats and has no album-artist, disc-number, compilation, grouping or artwork key at all.

### 6.4 Safe-write procedure

taglib saves **in place** by shifting the whole file — a measured write grew a file from 33,017 to 38,258 bytes on the same inode (74026656), with no temp file and no atomic rename. A crash, a force-quit or a full disk mid-save corrupts the song. So never write the original:

```swift
// 1. Sibling temp, same directory == same volume.
let tmp = orig.deletingLastPathComponent()
             .appendingPathComponent(".\(orig.lastPathComponent).tagtmp")
// 2. copyItem carries xattrs and the resource fork; Data.write would not.
try FileManager.default.copyItem(at: orig, to: tmp)
do {
    // 3. Mutate and save the copy.
    let f = try AudioFile(readingPropertiesAndMetadataFrom: tmp)
    …
    try f.writeMetadata()
    // 4. Atomic swap. Verified to preserve creation date, POSIX mode (640),
    //    extended attributes and the resource fork. Changes inode and mtime.
    var out: NSURL?
    try FileManager.default.replaceItem(at: orig, withItemAt: tmp,
                                        backupItemName: nil, options: [],
                                        resultingItemURL: &out)
} catch {
    try? FileManager.default.removeItem(at: tmp)
    throw error
}
```

Do not restore the old mtime afterwards. A changed modification date is the honest signal that the file was edited.

### 6.5 Cloud-only tracks — Music.app scripting

Music.app's sdef gives `track` read-write access to exactly the fields Noah asked for: `album`, `album artist`, `artist`, `bpm`, `comment`, `compilation`, `composer`, `disc number`, `disc count`, `genre`, `grouping`, `lyrics`, `sort album`, `sort artist`, `sort album artist`, `sort name`, `sort composer`, `track number`, `track count`, `work`, `year`, plus `name` inherited from `item`. Artwork is read-write via `data` / `raw data` on the `artwork` class. Match a row to a Music.app track by **`persistent ID`**, which `ITLibMediaItem` also carries.

Use ScriptingBridge against a generated header, not `NSAppleScript` string-building. Keep it strictly to **non-playback** operations:

> Driving Music.app launches Music.app if it is not running, and Music.app then takes over the Now Playing system controls and can fight for audio output. For a replacement player that is actively hostile. Never send a `play`, `pause` or `next track` command. Only property writes, and (later, if ever) `download`.

Lazy permission: the first cloud-track edit triggers the Automation TCC prompt. Ask for it in context with a sheet that says what it is for, and if the user declines, disable the editor for cloud rows with an explanation rather than failing silently.

### 6.6 Desync, and what to tell the user

Music.app caches title/artist/album in `Music Library.musiclibrary` and does not watch files for changes. A direct file-tag edit leaves Music.app showing the old values until it re-reads, and for a matched or uploaded cloud track the cloud copy can later overwrite the local change — direction depends on cloud status. Show a one-time sheet before the first *file* edit, with a "Don't show again" box:

> Editing this song's tags changes the file on this Mac. Music keeps its own copy of this information, so what Music shows may not update until it re-reads the file.

Edits made through Music.app scripting do not have this problem, which is a second reason that path is primary.

Two smaller things: taglib writes warnings to stderr (`TagLib: MP4: Ignoring duplicate atom "©nam"`) and SFBAudioEngine exposes no hook to turn them off, so keep them out of the user-facing log. And `kTCCServiceMediaLibrary`-class failures and the 4097 error are "not granted yet" states, not crashes — never report them to an error tracker, or they will drown real defects.

### 6.7 Adding songs to Music — Add Folder's "Also add to the Music app" (October 20, 2026)

MusicKit can't add songs on macOS (§6.1), so nothing OldTunes indexed ever reached iCloud Music Library. Music's own scripting `add` command can do it (`hookAdd`, access group `com.apple.Music.library.read-write`; ScriptingBridge selector `add:to:`, called with a nil `to` so the files land in the library itself). Music's Sync Library then matches or uploads what it took. File ▸ Add Folder offers this as a checkbox in its panel, off until the user ticks it, remembered after that. With it off nothing changes.

- **One file per event.** `add` takes a list, but one answer per file names each file Music turns down. Music's Info.plist declares MP3, MP2, AIFF, WAV, MPEG and M4A/M4P; FolderScanner also accepts FLAC, CAF and ADTS AAC, so those are the refusals to expect. A refused file becomes an OldTunes folder song and is listed in one alert. No permission, a timeout (60 s per add) or Music quitting stops the hand-off, and the files not yet sent stay OldTunes-only too.
- **Each song shows once.** With "Copy files to Music Media folder when adding to Library" on, Music's row has a different path from the original, which the folder scan would index a second time. So the index records every file Music took (`music_handoff`) the moment Music takes it, and folder scans skip those paths as they skip the paths Music lists. The song arrives through the next re-ingest, about 5 s after Music's change notification. AppController keeps a copy of the record in UserDefaults for a rebuilt index, as it does the folder roots.
- **The folder is still added.** Its root is stored as with the box off, so refused files and files added to the folder later behave like any added folder's. Adding the folder again offers Music only what it doesn't have yet.
- **Seen live October 20, 2026, 1:50 AM PT, with Noah's go-ahead:** `OLDTUNES_HARNESS=musicadd` handed an invented 10-second test tone to Music (already running) in 2.6 s. The nil `to` put it in the library, and Music answered with the new track, whose persistent ID read back. Music's database listed it 1.6 s later at a copy in Music's Media folder, so Music copies added files on this Mac, and the hand-off record is what keeps the original out. A re-ingest showed it once, as a Music-library song with a local file; iTunesLibrary did not call it a cloud song yet at that moment. Taking it back out with scripting `delete` (`OLDTUNES_MUSICADD_REMOVE`, 1:51 AM PT) also took Music's copy and its folders out of the Media folder. Still unseen: what `add` answers for a file Music refuses (nothing, or an error; both count as refused). The library bench covers OldTunes' side of that against a stand-in for Music.

### 6.8 Playlist commands — the source list's right-click menu (October 20, 2026)

MusicKit can't make, rename or delete playlists on macOS (§6.1), so the source list's New Playlist, New Playlist Folder, Rename, Duplicate and Delete go through Music's scripting too, on the same ScriptingBridge session and queue as tag saves (§6.5) and song adds (§6.7). Music's sdef (`sdef /System/Applications/Music.app`) has everything needed, and still nothing that plays.

- **Found by persistent ID.** Every playlist is looked up `whose persistent ID is "…"` (16 hex digits, as for songs), never by name: two playlists can share one.
- **New Playlist / New Playlist Folder:** `make new user playlist` (or `folder playlist`) `with properties {name: …}`, named "untitled playlist" / "untitled folder" (numbered if taken), whose name then opens for typing, as in iTunes. Sent as a plain Apple Event (`core/crel`), and the new playlist's persistent ID read from Music's reply (`core/getd` of `pPIS` of it), because ScriptingBridge can't make objects on macOS 27 (seen October 20, 2026): `classForScriptingClass:` answers with an `SBPseudoClass_<code>`, its `alloc` returns a message builder, and `initWithProperties:` on that makes an `SBProxyByCode`, an `NSProxy` that crashes a Swift `as? SBObject`. Objects ScriptingBridge hands back from Music (element arrays, command results) are still plain `SBObject`s, so the new playlist is looked up by that ID like any other, and its name read back before anything moves or fills it. A folder playlist has no playlist elements to make one in, so a playlist meant for a folder is made at the top level and then `move`d into it (the sdef's `move` is for playlists only). If the move fails it stays at the top level, which is logged.
- **Rename:** the `name` property, read-write on every playlist.
- **Duplicate:** a new user playlist beside the original, then a `duplicate` of each of the original's tracks `to` it, one Apple Event per song, because a one-event `duplicate every track …` has no ScriptingBridge form. Plain playlists only: copying a smart playlist's songs would lose its rules.
- **Delete:** `delete`, after asking. The Music app deletes a folder with everything in it, so the question counts what goes with it, and says Sync Library takes it off the other devices too unless Sync Library is known to be off.
- **The index follows at once.** Music's change notification brings a re-ingest about 7 s later (the 5 s debounce, §8.5, plus the read), so once Music has answered, `LibraryIndex.apply(_:)` writes the same change into the playlist tables and the source list shows it straight away: a new playlist among its siblings (folders, then smart playlists, then plain ones, each by name, which is the order iTunesLibrary reports here), a duplicate with the original's song rows, a deleted folder with everything in it. It also clears `playlists_hash`, so the re-ingest rewrites the playlists from Music's own database even when they hash the same as last time. Nothing reaches the index that Music didn't accept.
- **Not seen live yet.** None of these commands has run against Noah's library. `OLDTUNES_HARNESS=musicplaylists` (`App/MusicPlaylistLiveTest.swift`) runs each one on invented "OldTunes Test" playlists and checks it through iTunesLibrary, with his go-ahead. It settles three unknowns: whether `move` into a folder works through ScriptingBridge, how fast the per-song duplicate is, and whether a scripted `delete` of a folder takes its playlists along as the Music app's own Delete does. The `lists` bench (`OLDTUNES_LISTS_MODE=playlists`) covers OldTunes' side on an invented library.

---

## 7. Visual specification

### 7.0 Which 2005

**Target iTunes 4.9 — brushed metal.** iTunes 5 (Sept 2005) and 6 (Oct 2005) dropped metal for a flat gray vertical gradient, so "2005 iTunes" is two different looks that share almost no chrome values. 4.9 is the iconic one and the more distinctive, and it is what "looks like iTunes from 2005" means to anyone who was there. The iTunes 5/6 values are in §7.9 as a one-line theme swap if Noah wants the other.

Every value below is measured from a 781×526 1× screenshot of iTunes 4.9 by a pixel sampler, not recalled. **All coordinates are window-relative** in points, origin at the window's **top-left**, for the reference window of **756 × 500 pt**. (The raw measurements were in screenshot space with the window frame at x=12..767, y=1..500; every x here has had 12 subtracted and every y 1, and the layout has been normalised so the horizontal decomposition sums exactly to 756.)

JPEG caveat: single-pixel readings carry about ±2 levels of compression error. Region averages and gradient endpoints are reliable. The near-cyan `#B9FBFB` originally read at the bottom of the sorted-column header is ringing; `#B4EDFA` is the value to use.

### 7.1 Color table

| Token | Hex | Where |
|---|---|---|
| `metalEdge` | `#A4A4A4` | Brushed metal, left and right window edges |
| `metalCenter` | `#CECECE` | Brushed metal, window horizontal centre |
| `winBorderLeft` | `#959595` | 1 px window frame, left |
| `winBorderRight` | `#999999` | 1 px window frame, right |
| `winTopHighlight` | `#F3F3F3` | 1 px highlight at y=1 |
| `rule` | `#666666` | Header/footer/pane 1 px rules |
| `tlRed` | `#D4594A` | Close |
| `tlYellow` | `#F7AB3C` | Minimise |
| `tlGreen` | `#61A029` | Zoom |
| `btnRing` | `#6C6C6C` | Transport button 1 px ring |
| `btnPlayTop` | `#E6E6E6` | Play/pause interior, top |
| `btnPlayBottom` | `#F3F3F3` | Play/pause interior, bottom |
| `btnStepTop` | `#E5E5E5` | Back/forward interior, top |
| `btnStepBottom` | `#F6F6F6` | Back/forward interior, bottom |
| `btnGlyph` | `#3B3B3B` | Triangles, pause bars |
| `volGlyph` | `#3F3F3F` | Speaker glyphs |
| `volGrooveTop` | `#616161` | Volume groove, inset top |
| `volGrooveBottom` | `#E4E4E4` | Volume groove, bottom |
| `volKnobDimple` | `#4D4D4D` | Knob centre |
| `volKnobRim` | `#626262` | Knob rim |
| `volKnobTop` | `#DADADA` | Knob body, top |
| `volKnobBottom` | `#ECECEC` | Knob body, bottom |
| `lcdBG` | `#D7DBC0` | LCD panel, pale sage |
| `lcdBorderTop` | `#7F8173` | LCD recess, top (darkest) |
| `lcdBorderSide` | `#999C8B` | LCD recess, sides |
| `lcdInnerHighlight` | `#E6E8DA` | LCD inner bottom highlight |
| `lcdOuterBottom` | `#BDBCC1` | LCD outer bottom |
| `lcdScrubOutline` | `#161810` | Scrubber 1 px outline |
| `searchFill` | `#FFFFFF` | Search capsule interior |
| `searchBorderTop` | `#686868` | Search capsule, top (inset shadow) |
| `searchBorderBottom` | `#ADADAD` | Search capsule, bottom |
| `searchInnerTop` | `#E4E4E4` | Row just below the top border |
| `searchInnerBottom` | `#E3E3E3` | Row just above the bottom border |
| `listBG` | `#FFFFFF` | Source list background, odd track rows |
| `rowStripe` | `#ECF3FE` | Even track rows |
| `srcSelTop` | `#69A7EE` | Source selection gradient, top |
| `srcSelBottom` | `#2972D8` | Source selection gradient, bottom |
| `srcSelEdgeTop` | `#5D8DC6` | Source selection, 1 px top edge |
| `srcSelEdgeBottom` | `#3A6EBD` | Source selection, 1 px bottom edge |
| `srcSelOffTop` | `#989898` | Unfocused source selection, top |
| `srcSelOffBottom` | `#666666` | Unfocused source selection, bottom |
| `trkSel` | `#3C80DF` | Track selection, **flat** |
| `trkSelEdge` | `#7CADE7` | Track selection, 1 px bottom edge |
| `trkSelOff` | `#8E8E8E` | Unfocused track selection — **chosen, not measured** (§10-R9) |
| `trkSelOffEdge` | `#A8A8A8` | Unfocused track selection, bottom edge — chosen |
| `colSep` | `#C0C0C0` | Column header separators |
| `paneBorderSrcL` | `#666666` | Source pane left border |
| `paneBorderSrcR` | `#646464` | Source pane right border |
| `paneBorderTrkL` | `#65666A` | Track pane left border |
| `paneBorderTrkR` | `#686868` | Track pane right border |
| `splitterCore` | `#AFB0B4` | Splitter core |
| `scrollTroughEdge` | `#BFBFBD` | Scrollbar trough, edges |
| `scrollTroughCenter` | `#FCFCFC` | Scrollbar trough, centre |
| `scrollKnobRim` | `#2462B5` | Aqua knob rim |
| `scrollKnobMid` | `#2976DE` | Aqua knob mid |
| `scrollKnobHi` | `#72B7FF` | Aqua knob highlight |
| `footHighlight` | `#F0F0F0` | 1 px highlight at the top of the bottom bar |
| `bevelBorder` | `#666666` | Bottom-bar button border |
| `bevelFill` | `#CCCCCC` | Bottom-bar button interior |
| `textPrimary` | `#1A1A1A` | All list and chrome text |
| `textOnSelection` | `#FFFFFF` | Text over any selection |
| `textDimmed` | `#999999` | Unplayable rows, placeholder text |

**Pane header gradient**, 15 rows top→bottom (the corrected list; the originally reported tail had a duplicated value and a 19-level cliff that renders as visible banding):
`#E9E9E9 #E4E4E4 #DFDFDF #D8D8D8 #D1D1D1 #CBCBCB #C1C1C1 #BABABA #B3B3B3 #ABABAB #A3A3A3 #9C9C9C #959595 #909090 #8C8C8C` — or simply a linear `#E9E9E9 → #8C8C8C`.

**Track column header, normal** (bright–dipped–bright): `#FFFFFF` 0%, `#F5F5F5`, `#F1F1F1`, `#EFEFEF`, `#E9E9E9` 50% (darkest), `#F2F2F2`, `#FDFDFD`, `#FEFEFE` 100%.

**Track column header, sorted** (same shape in blue): `#CFE1F5` 0%, `#97C1E5`, `#8FB9E9`, `#86B9E6`, `#6FA6E6` 50% (darkest), `#7DBBF4`, `#86C7FF`, `#9DD7FF`, `#B4EDFA` 100%.

### 7.2 Metrics table (points)

| Metric | Value |
|---|---|
| Reference window | 756 × 500 |
| Minimum window | 640 × 400 |
| Window corner radius | 5 |
| Window border | 1 px each side |
| Title bar | y 1..27 (27 tall) |
| Control bar | y 28..91 (64 tall) |
| Header total | y 0..91 (92 tall), 1 px `rule` at y 92 |
| Traffic light diameter | 14 |
| Traffic light pitch | 21 |
| Traffic light centres | x 16.5 / 37.5 / 58.5, y 12.5 |
| Transport button centre y | 47 |
| Back button | 29 diameter, centre x 42 |
| Play/pause button | 37 diameter, centre x 79 |
| Forward button | 29 diameter, centre x 116 |
| Transport gap | 4 (37 centre-to-centre) |
| Pause bar | 6 wide, 3 gap |
| Volume centre y | 75 |
| Volume groove | x 39..116 (78 long), y 73..78 (6 tall) |
| Volume knob | 12 diameter |
| Volume glyphs | x 26..38 and x 117..132 |
| LCD panel | 313 × 48 at x 222..534, y 28..75 — **centred: centre x = W/2** |
| LCD corner radius | 24 (= height/2) |
| LCD line 1 baseline | y 43 |
| LCD line 2 baseline | y 57 |
| LCD end buttons | 13 diameter, inset at both ends |
| Scrubber | 240 × 9 at x 258..497, y 60..68 |
| Scrubber thumb | 7 diamond |
| Search field | 103 × 22 at x 574..676, y 38..59 |
| Search corner radius | 11 |
| Search magnifier + triangle | x 579..596 |
| "Search" label baseline | y 78 |
| Browse button | 37 diameter, centre (711, 47) |
| Left metal gutter | 15 (x 1..15) |
| Source pane border | 1 px at x 16 |
| Source pane content | x 17..174 (158 wide; resizable 120..400) |
| Source pane border | 1 px at x 175 |
| Splitter | 9 (x 176..184) |
| Track pane border | 1 px at x 185 |
| Track pane content | x 186..739 (554 wide) |
| Track pane border | 1 px at x 740 |
| Right metal gutter | 14 (x 741..754) |
| Column header row | 15 tall, y 93..107, 1 px rules at y 92 and y 108 |
| List content | y 109..463 |
| Source list row height | **18** |
| Track list row height | **17** |
| Intercell spacing | 3 × 0 |
| Source icon | 16 × 16, left edge x 31 (14 indent) |
| Source text left | x 50 |
| Track indicator column | 18 wide (x 186..203) |
| Track column separators | x 203, 479, 538, 663, 739 |
| Scrollbar width | **15** |
| Scroll arrow pair | 32 total, at the **bottom** |
| Bottom bar | y 465..498 (34), 1 px `rule` at y 464, `footHighlight` at y 465 |
| Bottom bar button | 31 × 22 at y 472..493 |
| Bottom bar button pitch | 39 |
| Bottom bar left group | 4 buttons at x 22 / 61 / 100 / 139, ending x 170 |
| Bottom bar right group | 3 buttons, ending x 725 |
| Summary text baseline | y 488, centred |
| Resize grip | x 728..754, y 474..499 |

### 7.3 Brushed metal

The one thing everyone gets wrong: **the gradient is horizontal, not vertical.** Measured across the title bar: x=71 `#ACACAC`, x=151 `#B5B5B5`, x=231 `#BFBFBF`, x=311 `#C8C8C8`, x=401 `#CECECE` (peak), x=481 `#C5C5C5`, x=561 `#BABABA`, x=641 `#B2B2B2`, x=721 `#A8A8A8`, x=751 `#A5A5A5`. It is symmetric about the window centre and **identical at every y** — sampling the 10 pt left gutter at y=29, 49, 74, 99, 199, 429, 469 and 484 gives `#A4A4A4`–`#A6A6A6` every time. There is no vertical ramp anywhere in the chrome. A vertical gradient will look wrong in a way that is very hard to diagnose later.

```
metal = horizontal NSGradient over the view's full bounds width:
  #A4A4A4 at 0.0, #CECECE at 0.5, #A4A4A4 at 1.0
```

Fill the **entire** window with it in one pass — title bar, control bar, both gutters, bottom bar.

The grain is **1 px horizontal scanline streaks**, not per-pixel noise. In the gutters the standard deviation of per-column means is 0.41–0.81 levels (negligible) while per-row means is 2.3–3.2; overall patch stdev ≈ 3.3, range `#9E`–`#B0`. So: one random brightness offset per device pixel row, stdev ≈ 3 levels, clamped to ±7, **constant across the whole scanline**.

The gradient is keyed to window width, so it must be redrawn against `bounds` on every resize — a tiled `NSColor(patternImage:)` would leave the centre highlight stationary while the window moved. Cache the grain as a `CGImage` sized to the window and regenerate only on resize, with a **fixed seed** so the texture is stable across launches (the original was a fixed asset).

On Retina, draw the 1 px rules and the grain at **1 device pixel**, not 1 point, or the hairlines look fat and the grain turns into visible banding.

### 7.4 Per-component layout notes

**Window.** `.titled + .closable + .miniaturizable + .resizable + .fullSizeContentView`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `titlebarSeparatorStyle = .none`, `isMovableByWindowBackground = true`. Title text drawn by `TitleBarView`, centred, Lucida Grande Bold 12. The real titlebar is 32 pt on macOS 27 against iTunes 5's ~22 pt and cannot be shrunk — which is why the chrome is drawn under a transparent one.

**Traffic lights.** Hide all three real buttons (`window.standardWindowButton(.closeButton)?.isHidden = true`, and the other two) while keeping `.closable`/`.miniaturizable`/`.resizable` in the style mask so ⌘W and ⌘M still work. Draw 14 pt Aqua orbs at the metrics above and wire them to `performClose(_:)`, `performMiniaturize(_:)`, `zoom(_:)`. Period behaviour: glyphs appear only on mouse-over **anywhere in the group**, so one `NSTrackingArea` covering all three. Hiding is chosen over repositioning because repositioned real buttons snap back on every window resize (measured: moved to 8/28/48, one `setFrame` restored 9/32/55) and need re-applying from `windowDidResize`, `windowDidEnterFullScreen`, `windowDidExitFullScreen` and `windowDidBecomeKey`.

**Transport cluster.** Three circles at the metrics above, all centred at y 47; the interiors are **darker at the top** with the gloss sweeping down, which is the opposite of the modern convention. Glyphs `btnGlyph`.

**LCD.** Capsule with radius = height/2, recessed: `lcdBorderTop` across the top, `lcdBorderSide` down the sides, `lcdInnerHighlight` as the inner bottom row, `lcdOuterBottom` below. Two lines of centred Lucida Grande 11, baselines y 43 and 57 — line 1 the title, line 2 artist — album, alternating on click like iTunes did. The scrubber interior is the same `lcdBG` as the panel, with only a 1 px `lcdScrubOutline` and a small black diamond thumb. Elapsed/remaining times are an iTunes 5 feature; 4.9 does not show them.

**Search field.** 103 × 22 capsule, radius 11. The magnifier is a **plain black glyph plus a small dropdown triangle** — there is no depressed circle around it; that detail belongs to a different era. A "Search" label sits centred beneath it.

**Source list.** Background is `listBG` **white**. The blue-gray `#E7EDF6` sidebar is iTunes 5, not 4.9 — do not use it. 18 pt rows, first row at y 109, 16 × 16 icons with their left edge at x 31, text at x 50. Order: Library, Podcasts, Party Shuffle, Radio, Music Store, then devices (disclosure triangle at the left, eject glyph right-aligned), then playlists. Selection is a **vertical gradient** with white text.

**Track list.** 17 pt rows, first row at y 109, `listBG` / `rowStripe` alternating **by display row, not by model id** — compute the stripe from the row index the table asks for, or the stripes scramble the moment the user sorts or filters. Selection is **flat** `trkSel` with a 1 px `trkSelEdge` bottom edge. Columns left to right: an 18 pt indicator column holding the now-playing speaker glyph, then Name (with a 12 × 12 blue checkbox at its left), Time (right-aligned), Artist, Album. A cloud-only row gets a small cloud badge at the right edge of Name; an unplayable row draws its text in `textDimmed`.

`usesAlternatingRowBackgroundColors` must be **off** — it paints the system's alternating colors, not these.

**Column headers.** 15 pt, rules above and below, the bright-dipped-bright gradient per column, 1 px `colSep` separators, and a small sort-direction triangle at the right edge of the sorted column, whose gradient turns blue.

**Scrollbars.** 15 pt wide, always visible, inset trough, Aqua blue capsule knob, and the arrow pair together at the **bottom** (Mac OS X "together" placement). All hand-drawn; see §8.3.

**Bottom bar.** 34 pt of the same horizontal metal. Left group of **four** rounded-rect bevel buttons — new playlist (+), shuffle, repeat, show/hide artwork — ending at x 170, just inside the source pane's right border, which is how iTunes aligned that cluster under the source list. Right group of **three** — equalizer, visualizer, eject. The visualizer belongs to the right group only; a five-button left group would straddle the splitter. Centred summary text, e.g. `15,900 songs, 46.2 days, 102.4 GB`.

**Column browser** (deferred to milestone 10). Three equal-width panes above the track list spanning the full track-pane width, default ~40% of the content height, each with its own centred `#E9E9E9 → #8C8C8C` header ("Genre" / "Artist" / "Album"), its own 15 pt scrollbar, and a first row reading `All (N Genres)` in bold. Same 17 pt rows and the same `listBG` / `rowStripe` alternation as the track list. An ~11 pt horizontal splitter with a small centred grab handle separates it from the list. Only the Windows build's column browser could be found in reference, so take **layout** from it and **colors** from the Mac track list — never the Windows skin's `#C0C2C2` rows, 20 pt height or Tahoma.

### 7.5 Typography

Verified on this machine by instantiating each font:

| Role | PostScript name | Size | Metrics |
|---|---|---|---|
| Track rows, source rows, column headers, control labels, LCD, bottom summary | `LucidaGrande` | 11 | cap 7.95, x-height 5.83, asc 10.63, desc −2.32, line height 13.0 |
| Pane headers: Source / Genre / Artist / Album; `All (N …)` rows | `LucidaGrande-Bold` | 11 | cap 7.95, x-height 5.90, line height 13.0 |
| Window title | `LucidaGrande-Bold` | 12 | advance for "iTunes" 41.76 pt vs measured ink 40 |
| Monospaced debug / Get Info technical block | `Monaco` | 11 | cap 8.34, line height 15.0 |

`NSFont(name: "Lucida Grande", size: 11)` and `NSFont(name: "Lucida Grande Bold", size: 11)` both resolve (to `LucidaGrande` and `LucidaGrande-Bold`); either spelling works. Files: `/System/Library/Fonts/LucidaGrande.ttc`, `/System/Library/Fonts/Geneva.ttf`, `/System/Library/Fonts/Monaco.ttf`. `Helvetica Neue` → `HelveticaNeue` and `Helvetica` are also present.

**There is no Lucida Grande italic or oblique face.** `Lucida Grande Italic`, `LucidaGrande-Italic` and `Lucida Grande Oblique` all return nil. Never request italic Lucida Grande; use `HelveticaNeue-Italic` or simply do not italicise.

Width checks against the reference ink extents, all at 11 pt regular: `Name` 30.60 vs 28 ink; `3293 songs, 9.3 days, 18.59 GB` 171.17 vs 169 ink; `Source` 35.77 regular / 37.83 bold vs 35 ink (within measurement error either way — bold is chosen because it reads as a header and matched visual inspection of the 5× crop).

Fallback chain if Lucida Grande ever disappears: `LucidaGrande` → `HelveticaNeue` → `NSFont.systemFont`. **Pin row heights to the literal 17 and 18**, never derive them from the font: Helvetica Neue 11 has a 12.0 line height against Lucida Grande's 13.0.

The `.LucidaGrandeUI` faces inside the TTC are system-private (leading-dot PostScript names). Reference only the two public names.

**Expect the text to look lighter than 2005.** macOS removed subpixel antialiasing in 10.14 and there is no supported API to bring it back. Compensate with color (`#1A1A1A` rather than pure black is already a nod to this), never by faking a bolder weight.

### 7.6 iTunes 5/6 alternative (one theme swap)

Replace the metal with a flat **vertical** gradient `#C5C5C5` → `#969696` over a 74 pt header, flat across x with **no grain**, terminated by a 1 px `#3F3F3F` rule. Set the source list background to `#E7EDF6`. Make the LCD a larger, only slightly rounded rectangle with elapsed/remaining times flanking the scrubber. Add a leading row-number column to the track list. iTunes 5's header gradient was measured as noiseless and flat across x: at y=76 it reads `#979797`/`#979798`/`#979798`/`#979797` at x=30/200/390/560.


### 7.7 Dark: "Graphite" (OldTunes' own, not 2005)

iTunes 4.9 had no dark mode, so this one is invented, in the 2005 hardware's terms rather than
2020s software's. The brushed aluminum becomes smoked graphite, the finish of the black iPod nano
(September 2005) and of Mac OS X's own Graphite appearance. The sage LCD switches to its night
mode: a negative display, dark olive glass with the characters lit, and the light they give off
is the day panel's own `#D7DBC0`. That inversion is the one bold move. Everything else follows
four rules:

- **Same metrics, same shapes.** Every gradient keeps its stops and direction; only the values
  change. The metal is still horizontal, still grained by scanline.
- **Same light, from above.** Graphite reflects less of it, so every highlight is fainter (the
  emboss lip drops from 50% white to 11%) and every shadow deeper, but they fall where they fell.
  Gloss is the exception: dark gloss shows its reflections more, not less (the black iPod nano),
  so the gel and bevel buttons keep strong highlights while the matte metal goes quiet.
- **The wells are the darkest thing.** Lists, the search hole and the LCD glass sit below the
  metal, the way a 2005 pro app (Aperture, Front Row) put dark content under dark chrome.
- **Aqua blue is the only accent**, kept for what is chosen, pressed, default or lit: selections,
  the scroller knob, the default button, lit toggle glyphs. It is a step deeper than by day.

Engraved labels flip. By day the lip is a light line 1 pt **under** dark letters; light letters
cannot take a light lip, so at night the groove's other wall shows instead, a dark line 1 pt
**above** (`ChromePalette.engrave`, `AquaStyle.engravedAttributes`). The 10.4 dialogs (Get Info,
alerts, Settings) get charcoal pinstripes and graphite gel where 10.4 had white gel.

**How it is built.** Each token is one dynamic `NSColor` with a light and a dark value
(`Theme.hex(light, dark:)`); AppKit resolves it for the appearance that is drawing, so views name
`Theme.listBG` and never ask which mode is on. Blends and gradients are built once per appearance
with `Theme.themed` instead. Measured on macOS 27: `withAlphaComponent` keeps a dynamic color
dynamic; `blended(withFraction:of:)` resolves it once, when it runs; an `NSGradient` happened to
re-resolve its colors at draw time, but nothing documents that and the deployment target is
macOS 14, so gradients are not trusted to. The brushed-metal bitmap is cached per size **and**
appearance.

**The setting.** OldTunes ▸ Settings… (⌘,) offers Light, Dark and Match System. Light and Dark set
`NSApp.appearance` to `.aqua` / `.darkAqua`; Match System sets it to nil, so the app follows
System Settings ▸ Appearance, Auto included, and changes when the Mac does. The choice is stored
as `OldTunes.appearance` (`light`, `dark`, `system`); unset means Match System. macOS renames an
app-menu item called "Preferences…" to "Settings…" a run-loop turn after launch whatever the app
asks for (measured), so the menu item and the window both say Settings. Test benches start in
Light whatever is saved, because their pixel checks compare against §7.1;
`OLDTUNES_APPEARANCE=light|dark|system` overrides one launch without saving.

**Tokens** (`Theme`, light value from §7.1 unchanged):

| Token | Light | Dark |
|---|---|---|
| `metalEdge` | `#A4A4A4` | `#36373A` |
| `metalCenter` | `#CECECE` | `#505256` |
| `winBorderLeft` | `#959595` | `#1C1D1F` |
| `winBorderRight` | `#999999` | `#1E1F21` |
| `winTopHighlight` | `#F3F3F3` | `#6A6C70` |
| `rule` | `#666666` | `#121315` |
| `btnRing` | `#6C6C6C` | `#0C0D0E` |
| `btnPlayTop` | `#E6E6E6` | `#46484C` |
| `btnPlayBottom` | `#F3F3F3` | `#6C6E72` |
| `btnStepTop` | `#E5E5E5` | `#45474B` |
| `btnStepBottom` | `#F6F6F6` | `#6D6F73` |
| `btnGlyph` | `#3B3B3B` | `#DCDDDF` |
| `volGlyph` | `#3F3F3F` | `#C9CACD` |
| `volGrooveTop` | `#616161` | `#0B0C0D` |
| `volGrooveBottom` | `#E4E4E4` | `#5E6064` |
| `volKnobDimple` | `#4D4D4D` | `#232426` |
| `volKnobRim` | `#626262` | `#111213` |
| `volKnobTop` | `#DADADA` | `#5C5E62` |
| `volKnobBottom` | `#ECECEC` | `#74767A` |
| `volKnobGlint` | `#FFFFFF` | `#8E9094` |
| `lcdBG` | `#D7DBC0` | `#181B12` |
| `lcdBorderTop` | `#7F8173` | `#040503` |
| `lcdBorderSide` | `#999C8B` | `#23261B` |
| `lcdInnerHighlight` | `#E6E8DA` | `#3E4334` |
| `lcdOuterBottom` | `#BDBCC1` | `#5A5C61` |
| `lcdScrubOutline` | `#161810` | `#C5CBA6` |
| `lcdInk` | `#1A1A1A` | `#D7DBC0` |
| `searchFill` | `#FFFFFF` | `#1C1D20` |
| `searchBorderTop` | `#686868` | `#08090A` |
| `searchBorderBottom` | `#ADADAD` | `#5A5C60` |
| `searchInnerTop` | `#E4E4E4` | `#111214` |
| `searchInnerBottom` | `#E3E3E3` | `#1F2023` |
| `listBG` | `#FFFFFF` | `#1E1F22` |
| `rowStripe` | `#ECF3FE` | `#24272E` |
| `srcSelTop` | `#69A7EE` | `#4F8CDB` |
| `srcSelBottom` | `#2972D8` | `#1E58B5` |
| `srcSelEdgeTop` | `#5D8DC6` | `#3E73BC` |
| `srcSelEdgeBottom` | `#3A6EBD` | `#18478F` |
| `srcSelOffTop` | `#989898` | `#5B5D61` |
| `srcSelOffBottom` | `#666666` | `#3B3D41` |
| `trkSel` | `#3C80DF` | `#2C6BCB` |
| `trkSelEdge` | `#7CADE7` | `#4F86D6` |
| `trkSelOff` | `#8E8E8E` | `#46484C` |
| `trkSelOffEdge` | `#A8A8A8` | `#57595D` |
| `colSep` | `#C0C0C0` | `#26272A` |
| `paneBorderSrcL` | `#666666` | `#111214` |
| `paneBorderSrcR` | `#646464` | `#111214` |
| `paneBorderTrkL` | `#65666A` | `#111215` |
| `paneBorderTrkR` | `#686868` | `#121315` |
| `splitterCore` | `#AFB0B4` | `#24262C` |
| `scrollTroughEdge` | `#BFBFBD` | `#111214` |
| `scrollTroughCenter` | `#FCFCFC` | `#2E3033` |
| `scrollKnobRim` | `#2462B5` | `#1A4C92` |
| `scrollKnobMid` | `#2976DE` | `#2A6FD0` |
| `scrollKnobHi` | `#72B7FF` | `#5FA4F2` |
| `footHighlight` | `#F0F0F0` | `#5E6064` |
| `bevelBorder` | `#666666` | `#111214` |
| `bevelFill` | `#CCCCCC` | `#4A4C50` |
| `textPrimary` | `#1A1A1A` | `#DEDFE1` |
| `textDimmed` | `#999999` | `#85878B` |

**Night LCD extras** (dark only): the text glows `#C8D38E` at 90%, blur 3.5 pt; the scrubber's
outline and thumb glow at 45%, blur 2 pt; the glass is lit from behind by an ellipse of `#2A2F1F`
at 85% fading to clear, the panel's width and 1.5 panel heights tall; the end buttons are `#8E9478`
discs with glyphs cut in the glass color; the inner top shadow is 70% black.

**Buttons at night** (dark only, October 20, 2026). The round caps are a clear step lighter than
the metal around them, as they are by day: play runs `#46484C` → `#6C6E72` where the metal is
about `#3B3C3F`. Before this, their tops matched the metal and only the ring drew them. On top of
the §7.1 shape:
- **Rim light** inside the top of each round cap: the cap less a copy of itself 1.5 pt lower,
  white 34% (pressed 12%), fading out by 45% of the cap's height.
- **Well**: a lip under every button at white 20% (round ones 0.75 pt down, bevels 1 pt), and
  above round buttons the well's shadowed wall, black 45%, 0.75 pt up. Bevel buttons have no
  room above them for it; their dark border marks the top.
- **Engraved glyphs**, like the labels: a dark line 1 pt above, black 40%. Dimmed glyphs are not
  engraved.
- **Bevel interior** from `bevelFill`: +42% white, +20%, +4%, −22% black, −38%, at the same stops.
- The volume knob takes the button lip; the groove and dimple keep the metal's.

**Alphas** (light → dark): emboss lip white 50% → 11%; engraving white 40% below → black 55% above;
recess shadow black 13% → 35%; gel sweep on round buttons 60/20% → 22/5% (pressed 25/10% → 9/2%);
gel drop shadow black 13% → 35%; scroller end shade black 22% → 45%. Aqua gels at night (rim top,
rim bottom, body top, mid top, mid bottom, body bottom, highlight): graphite `#18191B #0C0D0E
#6C6E72 #57595D #46484C #5F6165` 22%; blue `#1F4C8C #0F3066 #86B0E2 #4A84D0 #2C68C2 #76ADE8` 50%.

---

## 8. AppKit implementation notes

### 8.1 Defeating modern styling

| Goal | What works | Verified |
|---|---|---|
| Light or dark on our terms | `NSApp.appearance` = `.aqua`, `.darkAqua`, or nil for Match System, set by `AppearancePreference.applyAtLaunch()` before any window exists (§7.7) | `effectiveAppearance` went `NSAppearanceNameDarkAqua` → `NSAppearanceNameAqua`. `.aqua` is not deprecated in the macOS 27 SDK. Every chrome color is a light/dark pair, so no stock dark styling shows through. |
| Brushed metal | Draw it. `NSWindowStyleMaskTexturedBackground` is `API_DEPRECATED(macos(10.2, 11.0))` and has drawn nothing since 10.10 | The bit still *sets and sticks* at runtime (styleMask raw 33039), so a cargo-culted "enable metal" line looks like it worked. Do not debug why metal is not appearing. |
| Opt out of Liquid Glass | **No such API.** `UIDesignRequiresCompatibility` and `NSRequiresAquaSystemAppearance` appear nowhere in Xcode 27 or the SDKs | Draw every control. A stock `NSButton` reports `effectiveCornerRadii` 6.0 on all four corners. |
| Shrink Tahoe control metrics | `contentView.prefersCompactControlSizeMetrics = true` (macOS 26+, guard with `#available`) — inherits to all descendants | Sets and reads back true. |
| Kill the modern inset selection | `tableView.style = .fullWidth` | `effectiveStyle == .fullWidth`. Never leave `.automatic` — that is what infers the modern look from the hierarchy. |
| Stop macOS rounding the scroll view | Subclass `NSScrollView`, `override var cornerConfiguration: NSViewCornerConfiguration? { nil }` | A plain in-window `NSScrollView` reports `effectiveCornerRadii` bottomLeft 16.0 with no API call from you, independent of `borderType`. With the override, nil. This is new in 27. |

Two corrections to watch. **Check `effectiveCornerRadii` only on views already in a window** — a detached `NSScrollView` reports non-nil `cornerConfiguration` with all four radii 0.0, so a pre-install check reads "safe" on a view that is not. And **the window's `contentView` is not safe and cannot be fixed this way**: a stock contentView reports `cornerConfiguration == nil` but `effectiveCornerRadii` 16.0 on **all four** corners, and so does a custom subclass. That rounding comes from the window, not from an overridable property. Accept it — it is the macOS 26/27 window shape — and let the 5 pt painted corner sit inside it. (`NSTableView` reports nil and is genuinely safe.)

### 8.2 Row and header drawing

`NSTableRowView` overrides all still exist and none are deprecated: `drawBackground(in:)`, `drawSelection(in:)`, `drawSeparator(in:)`, `drawDraggingDestinationFeedback(in:)`, plus the read-only `interiorBackgroundStyle` the header explicitly recommends overriding alongside `drawSelection`.

```swift
final class TrackRowView: NSTableRowView {
    var displayRow = 0        // set in tableView(_:rowViewForRow:) — NOT the model id

    override func drawBackground(in dirtyRect: NSRect) {
        (displayRow % 2 == 0 ? Theme.listBG : Theme.rowStripe).setFill()
        dirtyRect.fill()
    }
    override func drawSelection(in dirtyRect: NSRect) {
        (isEmphasized ? Theme.trkSel : Theme.trkSelOff).setFill()
        bounds.fill()
        (isEmphasized ? Theme.trkSelEdge : Theme.trkSelOffEdge).setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
    override var interiorBackgroundStyle: NSBackgroundStyle {
        isSelected ? .emphasized : .normal
    }
}
```

`isEmphasized` is false when the table is not the focused responder in a key window, which is exactly the two-tone behaviour real iTunes had — draw both states. Forgetting `interiorBackgroundStyle` leaves dark text on blue and unreadable. And `drawSelection(in:)` is **not** called synchronously after `selectRowIndexes` — it runs on the display cycle — so a synchronous test right after selecting will wrongly look like the override is broken.

Headers: subclass `NSTableHeaderCell`, override `draw(withFrame:in:)` to paint the gradient, the 1 px right and bottom separators, then `drawInterior(withFrame:in:)` on an inset rect and `drawSortIndicator(withFrame:in:ascending:priority:)`; override `drawSortIndicator` to fill your own `NSBezierPath` triangle. Both methods are still present and the header file says *"Override this routine to customize the sorting UI."* `NSTableHeaderView` can be subclassed and installed but has almost no API (`tableView`, `draggedColumn`, `draggedDistance`, `resizedColumn`, `headerRect(ofColumn:)`, `column(at:)`), so a fully custom header iterates `headerRect(ofColumn:)` and draws everything itself.

### 8.3 Scrollers

```swift
final class AquaScroller: NSScroller {
    // Leave isCompatibleWithOverlayScrollers FALSE. That is what pins legacy mode.
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { 15 }
    override func draw(_ dirtyRect: NSRect) { /* trough, knob, arrow pair */ }
    override func drawKnob() { … }
    override func drawKnobSlot(in slotRect: NSRect, highlight: Bool) { … }
    override func rect(for part: NSScroller.Part) -> NSRect { /* carve 32pt for arrows */ }
    override func testPart(_ point: NSPoint) -> NSScroller.Part { /* hand-rolled hit test */ }
}
```

This is the strongest single finding in the UI research. Leaving `isCompatibleWithOverlayScrollers` false **pins the scroll view to legacy always-visible scrollers regardless of the user's preference**: `NSScroller.preferredScrollerStyle` is `.overlay` on this machine, `scrollView.scrollerStyle` stayed `.legacy`, posting `preferredScrollerStyleDidChangeNotification` did not change it, and explicitly setting `scrollView.scrollerStyle = .overlay` was *refused*. Overlay scrollbars would break the look entirely, so this matters.

Three traps:

- **`hasVerticalScroller = true` is required.** Assigning `scrollView.verticalScroller` does **not** turn the scroller on: with only the assignment, `hasVerticalScroller` stays false and the scroller reports `isHidden == true` with an unchanged frame. Add the flag and the same code lays out at `(384, 29, 15, 270)` — the 15 pt width override honoured. (`scrollerStyle = .legacy` is harmless but redundant.)
- **Arrows are gone from the machinery, not just from the look.** `rect(for:)` returns `NSRect.zero` for `.decrementLine` and `.incrementLine`, so arrow hit-testing built on it silently does nothing. `drawArrow(_:highlight:)` is deprecated ("Scrollers don't have arrows as of 10.7"), `arrowsPosition` has had no effect since 10.7, `trackScrollButtons` is not invoked. Compute the arrow rects yourself and override `testPart(_:)`/`mouseDown(_:)`.
- **`NSScroller.isFlipped == true`**, as are `NSTableView` and `NSTableHeaderView`. In a vertical scroller y=0 is the **top**. For the iTunes arrow pair at the bottom, use `y = bounds.height - 32`, not `y = 0`.

Scroll view setup:

```swift
scrollView.hasVerticalScroller = true
scrollView.verticalScroller    = AquaScroller(frame: .zero)
scrollView.autohidesScrollers  = false
scrollView.borderType          = .bezelBorder
```

### 8.4 Table performance

Measured on this machine at 50,000 rows, `-O` build, with every sort result consumed so nothing could be optimised away:

| Operation | Cost | Conclusion |
|---|---|---|
| `reloadData()`, view-based, 50k rows | **0.07–0.09 ms** | Not a bottleneck. No diffable updates, no `NSArrayController`. |
| `noteHeightOfRows` over all 50k, `tile()` | ~0.01 ms | Lazy/deferred. |
| Sort by `Int32` key | **1.28 ms** | The index-array design is worth it. |
| Sort by `Double` date | 1.26 ms | |
| Plain `[Int32].sort()` | 2.12 ms | |
| Sort by raw `String <` | 8.77 ms | 7× an integer key. |
| Sort by precomputed lowercased `String` | 8.88 ms | |
| **`localizedStandardCompare`** | **226.65 ms** | **26× a plain String compare, 177× an integer key. Never in a comparator.** |
| `reverse()` an already-sorted order | 0.02 ms | How descending is implemented. |
| Re-sort descending on nearly-sorted input | 0.06 ms | Effectively free. |
| Scroll 200 screens of 50k (`scrollRowToVisible` every 250 rows, forced display) | 129 ms total, 11,144 `makeView` calls | View reuse works: ~0.65 ms per screenful of 28 rows, and the call count tracks visible cells traversed, not rows. |
| Filter 50k with `range(of:options:.caseInsensitive)` | 91 ms | Why filtering lives in SQLite, not in Swift. |
| Filter 50k with precomputed lowercase + `contains` | 25–37 ms | Still worse than FTS5's sub-millisecond. |

So: back the table with a materialized `[Int64]` id array, re-run the whole sorted id query on a header click (1.2–1.5 ms at 47.7k), swap the array, `reloadData()`. Fetch row detail by id on demand and keep a small LRU of `SongRow` for the visible window. Debounce search 140 ms and cancel in flight:

```swift
private var searchTask: Task<Void, Never>?

func search(_ text: String) {
    searchTask?.cancel()
    searchTask = Task { [index] in
        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }
        let ids = await index.search(text, sortedBy: sort)
        guard !Task.isCancelled else { return }
        self.order = ids                 // inherits MainActor isolation
        self.tableView.reloadData()
    }
}
```

Table configuration: `style = .fullWidth`, `selectionHighlightStyle = .regular`, `usesAlternatingRowBackgroundColors = false`, `gridStyleMask = []`, `rowHeight = 17` (18 for the source list), `intercellSpacing = NSSize(width: 3, height: 0)`, `usesAutomaticRowHeights = false`, header view height 15.

Cell-based tables are soft-deprecated only — `NSTableColumn.dataCell` carries no deprecation attribute and compiles warning-free under Swift 6 — but `preparedCell(atColumn:row:)`, `focusedColumn` and all five text-editing hooks are deprecated since 10.10. **Use view-based**; `reloadData` is 0.07 ms either way and the row-view override points are where all the retro drawing happens.

### 8.5 Swift 6.4 concurrency shape

Verified: the full retro AppKit shape — custom row views, header cells, a legacy scroller subclass, a `@MainActor` view controller and a background actor store with `Sendable` snapshot structs — compiles under `-swift-version 6` with **zero** errors and zero concurrency warnings. AppKit's delegate methods are already `NS_SWIFT_UI_ACTOR`, so the compiler does most of the work.

```swift
// Crosses actor boundaries. Nothing else does.
struct SongRow: Sendable, Hashable, Identifiable { … }     // Model/Track.swift already has this shape

// Concurrency-correct already; parallel reads. Fallback: make it an actor if Sendable complains.
final class LibraryIndex: Sendable {
    private let pool: DatabasePool
    func order(by: TrackSort) async throws -> [Int64]
    func search(_ q: String, sortedBy: TrackSort) async throws -> [Int64]
    func rows(ids: [Int64]) async throws -> [SongRow]
}

actor LibraryIngest {                 // owns the single ITLibrary instance
    func run() async throws -> IngestResult
}

actor TagEditor {                     // @preconcurrency import SFBAudioEngine
    func write(_ edits: TagEdits, to url: URL) throws
}

@MainActor final class LibraryViewController: NSViewController, NSTableViewDataSource { … }
@MainActor final class PlaybackCoordinator { … }   // both transports live here
```

Rules that are not negotiable:

- **`ApplicationMusicPlayer` only on the main actor.** It is not `Sendable` and has zero `@MainActor` annotations in the whole macOS swiftinterface, so Swift 6 will not stop you touching `.shared` from a background actor. The module interface predates strict checking; the discipline is yours.
- `AVPlayer` is `@MainActor` at class level but most members are `nonisolated`. Mixing produces confusing isolation errors on the few that *are* isolated — `init(playerItem:)` and `.asset`, because `AVAsset` is not `Sendable`. Use `AVURLAsset`, which is.
- SFBAudioEngine's `AudioFile` and `AudioMetadata` are Objective-C and non-`Sendable`. They never leave `TagEditor`.
- A `Task` started from a `@MainActor` method inherits MainActor isolation, so assigning `self.order` inside one needs no hop and no annotation.
- Create exactly **one** `ITLibrary` and keep it. Two instances in one process share a process-wide cache, which is how a warm-cache measurement wrongly makes eager init look free.
- `ITLibraryDidChangeNotification` arrives on `NSDistributedNotificationCenter`, **not** `NotificationCenter.default` — registering on the default center compiles, runs and never fires. It is explicitly coarse (no per-object changes), so debounce several seconds, re-ingest into a temp table and swap, so search keeps working during the rebuild. On macOS 26+ the typed `ITLibrary.DidChangeLibraryMessage` / `NotificationCenter.MessageIdentifier.didChange` is available; the distributed notification is the portable path.
- `CGWindowListCreateImage` is a **hard compile error** on macOS 27 ("Please use ScreenCaptureKit instead"), not a deprecation. Any carried-over screenshot code will fail to build.

### 8.6 iTunesLibrary API landmines

- **Never call `enumerateValues(forProperties: nil)` from Swift.** Hard SIGSEGV at 0x0 in `swift_getObjectType`: the block imports `id value` as non-optional `Any` under `NS_ASSUME_NONNULL_BEGIN` and the framework passes nil. Confirmed by crash report, not theory. It is also simply wrong — 4 keys over 3,000 songs produced 14,695 callbacks instead of 12,000 — and slower per item than typed access. Use typed properties.
- **Property key strings are short names, not symbol names.** `ITLibMediaItemPropertyArtistName == "Artist"`, `…PropertyTitle == "Title"`, `…PropertyAlbumRepresentativeItemPersistentID == "AlbumRepresentativePersistentID"`. Guessing the string from the symbol returns nil for every field, which looks exactly like a broken framework. Declare the externs through a bridging header (`extern NSString * const ITLibMediaItemPropertyStoreItemID;`) or `dlsym` at startup rather than hardcoding.
- Using `StoreItemID` means linking a symbol that is in the `.tbd` but in no public header. Fine for Developer ID; it would be a Mac App Store rejection risk. It is only needed for fallback step 3.
- **Do not touch** `ITLibRequest`, `ITLibResponse`, `ITLibSearchRequest`, `ITLibSearchResponse`, `ITLibSearchScope`, `ITLibIdentifierSet` or the `ITLibraryModifyLibrary*` constants. They are exported, absent from every header, and look exactly like the query and write API you want. Build the index instead.
- `ITLibInitOptions` is an `NS_ENUM`, not `NS_OPTIONS`: `.none` or `.lazyLoadData`, never `options: []` (that fails to compile).
- `.lazyLoadData` does not make loading faster — it moves the ~1.3 s (≈4.3 s extrapolated at 50k) from init to the first `allMediaItems` access. Touch it on a background executor or you have traded a slow launch for a 4-second beachball.
- `reloadData()` returns true in 0.0 ms and does nothing visible; the 1,535 ms lands on the next `allMediaItems`.
- `mediaFolderLocation` returns **nil** on this machine, so it cannot be used to locate media. Use each item's own `.location`. The real tree is `/Users/noah/Music/Music/Media.localized/Music` — note `.localized`; plain `~/Music/Music/Media` does not exist.
- **Do not crawl the library tree yourself.** `readdir` returns EPERM on `~/Music/Music`, on `Media.localized`, on `Media.localized/Music` and on the `.musiclibrary` bundle for an ungranted process, even though `stat` on known children succeeds. And never parse `Library.musicdb` — private format, separate macOS 14+ app-data TCC class, changes without notice.
- `ITLibArtwork.image` **does** work, but only in a file that also `import AppKit` (the header forward-declares `NSImage` without importing it; without AppKit you get *"has no member 'image'"*). Use `.imageData` anyway: you need the bytes to downscale, and `.image` retains a full-size `NSImage` in the artwork object's cache.
- **There is no artwork thumbnail API** — every read is the full original, averaging 114–156 KB at 300×300 up to 1200×1200. Reads are cheap (1.02 ms cold, 0.24–0.32 ms warm, 0.32 ms for cloud-only tracks), but 10,277 of them raw would cost well over a gigabyte. Downscale to 64×64 and 300×300 at first display, cache on disk keyed by `AlbumPersistentID` (far fewer distinct albums than songs).
- `ITLibrary.artworkForMediaFile(_:)` took 45.5 ms and returned nil for a perfectly good local MP3. Do not use it, not even as a fallback.
- `ITLibMediaItem.description` is a declared property that shadows `NSObject.description`; printing an item with `"\(item)"` behaves unexpectedly.
- Swift case names: `mediaKind == .kindSong` (raw value 2), not `.song`. `locationType == .file` (raw 1).

---

## 9. Build order

Each milestone is independently verifiable and the app shows something real from milestone 2 onward. Commands run on Noah's Mac from `/Users/noah/Projects/iJustWantToListenToMyOldMusic` unless stated otherwise.

**1 — Permission and ingest truth, no UI (half a day).**
Do the portal step (§3.4). Add the entitlements and the `NSAppleEventsUsageDescription`. Build and sign with `Apple Development: Noah Tsutsui (H3ZP723CJJ)` and confirm `TeamIdentifier=92N52YB23U`. Launch, accept the one Media & Apple Music prompt, and have the app write a report to `~/Library/Logs/OldTunes/ingest.log`: the three-way permission check, `allMediaItems.count`, the `mediaKind` histogram, the `locationType` histogram, the count of rows with a non-zero `StoreItemID`, the `MusicLibraryRequest<Song>` count, the join rate, and `MusicSubscription.current`'s three flags.
**Verify:** 16,178 items, 15,900 songs, `{1: 5, 3: 15895}`, 6,742 with a store id, 15,900 MusicKit songs, 15,900/15,900 join, all three subscription flags as expected. Any number off means stop and find out why before building on it.

**2 — Window and metal (half a day).**
`MetalWindow` + `MetalContentView`: horizontal gradient, seeded scanline grain, 1 px frame, hidden real traffic lights with hand-drawn orbs and group hover, drawn title. Dead chrome, no lists.
**Verify:** screenshot the window; sample the title-bar row at 10% / 50% / 90% width and get ≈`#ACACAC` / `#CECECE` / `#A8A8A8`; sample the left gutter at four different y values and get `#A4A4A4`–`#A6A6A6` every time. Resize and confirm the centre highlight tracks the window.

**3 — The index (half a day).**
GRDB, the §4.2 DDL, pragmas, `ANALYZE`. Ingest milestone 1's rows into it. Implement `order(by:)`, `search(_:sortedBy:)`, `rows(ids:)`.
**Verify:** a test that asserts 15,900 rows; each of the four sort queries returns 15,900 ids in under 5 ms; `EXPLAIN QUERY PLAN` on the name sort says `SCAN song USING INDEX ix_title` with no temp b-tree; `'oas'` on the trigram table and `'o*'` on the prefix table both return plausible counts in under 3 ms; blank-artist rows land at the end of the artist sort.

**4 — Track list, real rows (one day).**
`NSTableView` with `AquaScroller`, `TrackRowView`, `TrackHeaderCell`, the five columns, click-to-sort with the triangle, `reverse()` for descending.
**Verify:** 15,900 real song titles on screen; all four columns sort both directions with no visible delay; screenshot-sample row backgrounds for `#FFFFFF`/`#ECF3FE` alternating by display row after a sort; the scrollbar is 15 pt, always visible, with the arrow pair at the bottom.

**5 — Search box (two hours).**
Hand-drawn capsule, 140 ms debounce, length-routed query, cancel in flight.
**Verify:** typing `oasis` and `nderw` both return rows; the first keystroke does not stall; clearing restores 15,900 rows; typing fast never shows stale results.

**6 — Cloud playback (one day). The milestone that proves the project.**
`CloudTransport`, `PlaybackCoordinator` with order/cursor, `PlaybackClock` at 10 Hz, transport buttons, LCD text, scrubber with drag-to-seek.
**Verify:** double-click any of the 15,895 cloud-only rows and hear audio; `playbackTime` advances in the LCD; dragging the scrubber seeks; next/previous moves the selection and the audio together; nothing plays in Music.app.

**7 — Local playback and shuffle (half a day).**
`LocalTransport`, the §1 fallback chain, transport switching with `stop()` before `load()`, the shuffle button and Swift-side permutation.
**Verify:** the 5 local songs play; construct a queue that alternates local and cloud and confirm no double audio at the boundary and no stuck state; shuffle produces a different order each time and keeps the current song playing.

**8 — Source list and bottom bar (half a day).**
18 pt rows, gradient selection with the unfocused variant, the standard sources plus playlists read from `ITLibrary.allPlaylists`; bottom bar with the 4+3 buttons and the centred summary.
**Verify:** both tables on screen at once, visibly different row heights and selection styles; clicking into each table flips `isEmphasized` and both selections change appearance; the summary reads a real song count, duration and byte total.

**9 — Tag editor (one day).**
Get Info sheet. Music.app ScriptingBridge path first (it serves 15,895 songs), SFBAudioEngine + atomic swap second (5 songs). Lazy Automation prompt. The one-time file-edit warning.
**Verify:** edit the genre of one cloud track, confirm it in Music.app's own Get Info, re-ingest and confirm the index agrees. Edit the year of the one local MP3 to 2005, confirm `AudioFile` reads back `"2005"`, and confirm the file's creation date, POSIX mode and xattrs survived (`stat -f` before and after).

**10 — Polish (open-ended).**
Column browser, artwork pane with the downscale cache, live library-change re-ingest, Monaco Get Info technical block, keyboard navigation, window state persistence.

---

## 10. Risks and unknowns

Ordered by how much damage each would do. Every experiment is cheap and runs on Noah's Mac from `/Users/noah/Projects/iJustWantToListenToMyOldMusic` unless stated.

**R1 — Does the Media & Apple Music grant alone let us *read the audio files* under `~/Music/Music/Media.localized/Music`?**
Everything points to yes: Apple's own sandboxed helpers inside `iTunesLibrary.framework` get by on `app-sandbox` + `assets.music.read-only` + `network.client` plus a private MediaLibrary pre-grant; the sandbox profile allows `~/Music` recursively; a forum reporter's sandboxed app worked on the media grant alone and a reply explicitly confirmed Full Disk Access is *not* needed. But no source confirms reading the files specifically, and the shell already gets EPERM in that tree. Affects only the 5 local songs, so it is a small blast radius with a cheap check.
**Experiment (5 min, inside milestone 1):** in the signed app, for each of the 5 rows with `locationType == .file`, call `FileManager.default.contents(atPath: item.location!.path)` and log the byte count. **Fallback:** a one-time open-panel grant on `~/Music` persisted as a security-scoped bookmark.

**R2 — Would an iTunes-Match-only user (no Apple Music) be able to stream cloud tracks?**
Unprovable here, because Noah *is* a catalog subscriber. Evidence is suggestive — the track that played had no `catalogId` and `playParameters` marked it `isLibrary = true`, so catalog entitlement was not what served the audio — but not proven. **Does not block this build.** It only matters if Noah later cancels Apple Music.
**Experiment:** none available without a second account. The §1 table already specifies the behaviour for that state, so the code is written for it either way.

**R3 — How do we know a cloud track finished?**
MusicKit gives no finish callback, and the proposed heuristic (status leaves `.playing` while `position >= duration - 1.0`) is inference. If it misfires, shuffle either stalls at the end of every song or double-skips — and this is the most likely place a 2005-iTunes-feel app feels wrong.
**Experiment (20 min, during milestone 6):** queue a single 30-second cloud track, log `state.playbackStatus`, `playbackTime`, and `queue.currentEntry` at 10 Hz through the natural end, and read the transition off the log. **Fallback:** a watchdog that fires `onFinish` at `duration - 0.25` on a timer set when playback starts, corrected on each tick.

**R4 — Does writing a tag through Music.app scripting actually succeed on a matched, non-downloaded cloud track?**
The sdef says `track`'s tag properties are read-write and `cloud status` is read-only, but the command has never been run against this library. This is the primary editor for 15,895 of 15,900 songs, so if it fails the metadata-editing requirement is unmet for all but 5 songs.
**Experiment (10 min, with Noah watching, during milestone 9):** pick one throwaway cloud track, `set comment of track id N to "oldtunes-probe"`, read it back, confirm in Music.app's Get Info, then set it back to empty. Do this on a track Noah does not care about, and ask first.

**R5 — Is `PlayParameters` round-trip `Codable`, and how long does the one big `MusicLibraryRequest` take?**
The plan rebuilds the `[Int64: Song]` play map at every launch rather than persisting it, which depends on that request being fast. If it is slow, the fix is to persist the `playParameters` JSON — which depends on it decoding back into something `ApplicationMusicPlayer` accepts. Neither is measured.
**Experiment (15 min, during milestone 1):** time one `MusicLibraryRequest<Song>` with `limit = 50000`; then `JSONEncoder` one `Song.playParameters`, `JSONDecoder` it back into `PlayParameters`, queue it, and play. **Fallback if decoding fails and the request is slow:** show the index-backed list immediately and enable playback per row as the map fills.

**R6 — How long is a cold `ITLibrary` load after a reboot?**
Measured 13 ms init + 1,280–1,535 ms for `allMediaItems` warm, but the *first ever* run cost 2,978 ms for init alone (one-time TCC/XPC warm-up). Whether that recurs after a restart or after Music.app rewrites the database is unknown, and it decides whether first-launch-after-login needs a progress indicator.
**Experiment (5 min, after any reboot):** run the milestone-1 app first thing and read the two timings out of `~/Library/Logs/OldTunes/ingest.log`. **Fallback:** show the SQLite-backed list from the previous session immediately and ingest behind it — which the architecture already does, so this is cosmetic.

**R7 — Does the AppleScript `download` command complete for an *uploaded* (non-catalog) track, and how is completion observed?**
The command exists (`hookDwnl`) but has never been invoked. Not in v1, so this is only a risk if download gets added later.
**Experiment:** invoke it on one track with Noah watching and poll `ITLibMediaItem.locationType` until it becomes `.file`. Needs his explicit go-ahead — it writes to his library and consumes disk.

**R8 — Does `x-apple.systempreferences:com.apple.preference.security?Privacy_Media` still open the right pane on macOS 27?**
The Settings extension's own anchor list has no `Privacy_Media` entry (it has `Privacy_Camera`, `Privacy_Microphone`, `Privacy_Photos`…) and refers to the pane internally as `mediaLibrary`.
**Experiment (1 min, on Noah's Mac from any directory):** `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Media"` and see where it lands. **Fallback is already written** (§3.6 falls back to opening System Settings plainly).

**R9 — The unfocused track-list selection colour is a choice, not a measurement.**
No reference screenshot showed a track list that had lost focus. `trkSelOff #8E8E8E` / `trkSelOffEdge #A8A8A8` is derived from the source list's measured unfocused gradient (`#989898` → `#666666`), but Mac OS X 10.4's secondary table selection was lighter than that.
**Experiment:** none possible from the available references. Make it a two-line theme change and let Noah pick by eye against a real screenshot once milestone 4 runs.

**R10 — SFBAudioEngine's 10 embedded frameworks and notarization.**
`otool -L` on a release build shows 10 `@rpath` frameworks (wavpack, ogg, FLAC, opus, vorbis, lame, mpc, mpg123, sndfile, tta-cpp) plus system libz and libc++; CSpeex, CDUMB and CXXMonkeysAudio link statically. Every one must be embedded and signed or notarization fails and the app will not launch on a clean machine. Since the local-file path serves 5 songs, the whole dependency may not be worth its weight.
**Experiment (20 min, during milestone 9):** build release, `codesign --deep` verify, notarize, then launch from a fresh user account. **Fallback if it fights back:** drop SFBAudioEngine and route *all* tag edits through Music.app scripting, accepting that a local file's tags then change only via Music's own re-read. That is a one-file change because `TagEditor` already has two paths behind one API.

**R11 — Ingest linearity, and whether anything changes at 50k.**
The ~85 µs/item ingest rate extrapolates to ~4.3 s at 50,000 items, but only a 16,178-item library was measured, and the trigram table's size and latency curve past 47.7k rows is untested. At 15,900 there is a lot of headroom; this only matters if Noah's library grows 3×.
**Experiment:** duplicate the 15,900 rows three times into a scratch database in the scratchpad directory and re-run the §4.4 query benchmarks. **Fallback:** raise the trigram route's threshold and lengthen the prefix list.

**R12 — Full-screen and Stage Manager with hand-drawn traffic lights.**
Both re-tile the titlebar. Hiding the real buttons (the chosen route) should be immune, but it was not tested, and neither was whether a hand-drawn scroller's arrows actually scroll when clicked — only that `rect(for:)` gives nothing to work with and that the drawing renders.
**Experiment (10 min, during milestone 2 and 3):** enter and leave full screen, open Stage Manager, confirm the drawn chrome stays put; click each scroller arrow 20 times and confirm the row offset changes by one each time.
