# Visualizer

The bottom-bar flower button swaps the track list for a music visualizer, as iTunes 4.9 did. The
visualizer is based on **Geiss HDR** by Ryan Geiss (www.geisswerks.com/geiss_hdr), ported from
JavaScript and WebGPU to Swift and Metal. Geiss HDR is Apache-2.0.

Status: working in the app (M0–M4). Still to do (M5): a side-by-side check against the original in
Chrome, a long listening test, and these notes' results.

## Where the code lives

| Folder | What | Licence |
|---|---|---|
| `VisualizerCore/` | Static library: the ported engine, the Metal renderer, the AnalyserNode emulation, the sample ring | Ported files Apache-2.0 (they carry the Geiss HDR header); the rest is OldTunes's |
| `OldTunes/Visualizer/` | App side: the Core Audio tap, the silence watchdog, the view, the window, the bench | OldTunes's |

`VisualizerCore` is its own target because it is built with `-O` in every configuration. The
engine is numeric Swift: at `-Onone` one warp map would take seconds instead of milliseconds.

Shaders are Metal Shading Language source strings, compiled when the app runs
(`makeLibrary(source:)`), the way the original compiles its WGSL strings. That keeps the build free
of Xcode's separately downloaded Metal toolchain.

## How sound reaches the screen

1. Cloud songs sound from Apple's `com.apple.MediaPlayer.RemotePlayerService`, local files from
   OldTunes itself. When OldTunes has System Audio Recording, one Core Audio process tap reads both
   (`MusicAudioTap`): a stereo mixdown, unmuted and private, inside a private aggregate device
   clocked by the default output. When it isn't known to, ScreenCaptureKit capturing OldTunes itself
   reads both, with no permission (`SelfCapture`; see "Without the permission" below).
2. Each buffer is mixed to mono, ½(L+R), into `SampleRing`, four seconds long.
3. Once per engine step, the AnalyserNode emulation reads the 2048 samples that end at that step's
   time and makes an `AudioFrame`: the same numbers Chrome's AnalyserNode (fftSize 2048, smoothing
   0.6) gives Geiss HDR.
4. The driver (the engine part of `main.js`) runs the clocks, the palette, the levels and the beat
   detector, then the engine (`engine.js`) makes the warp weights and the dots, and the renderer
   (`gpu_warp.js`, `webgpu_present.js`) draws them.

The animation is tuned for 120 steps a second. On a 60 Hz screen each frame runs two steps, each
with its own slice of audio.

A `CAMetalDisplayLink` on the main thread runs all of this (`OldTunes/Visualizer/VisualizerRenderLoop.swift`).
It hands each refresh a free drawable, so the main thread never waits in `nextDrawable()`. One rule
comes with it: while a link exists on the layer, never set the layer's `maximumDrawableCount`. It
throws (`CAMetalLayerInvalidOperation`) even when the value doesn't change, and an Objective-C
exception that unwinds through Swift corrupts the process: it crashed a moment later, somewhere
unrelated in AppKit. The pixel format, colour space and EDR flag may all change under a running link.

In HDR the layer is `rgba16Float` in `CGColorSpace.extendedSRGB`: the values are sRGB-encoded, the curve
continued above 1. That is how the original's canvas reads them. The WebGPU spec says a value is "correctly
encoded for use on a 'srgb'-tagged (approximately perceptually-linear) canvas" only after gamma encoding, and
that each colour space runs over "an extended range, as defined by the referenced CSS definitions"
(https://www.w3.org/TR/webgpu/, §3.11). So the palette's top value, 3.0, means about 12.8× SDR white, and the
screen caps it at its headroom (4× to 16× on a MacBook Pro's XDR screen). It looks very bright, in Chrome too.
`extendedLinearSRGB` would read 3.0 as only 3× white.

## Without the permission

macOS lets an app capture its own content with no permission and no prompt
(`SCShareableContent.currentProcess`, macOS 14.4). The sound of an app capture is the app's own plus
that of every process RunningBoard counts as hosted by the app, and RunningBoard counts the
RemotePlayerService MusicKit starts for OldTunes as hosted by OldTunes (the log names it
`xpcservice<com.apple.MediaPlayer.RemotePlayerService([app<application.com.noahtsutsui.oldtunes…>:pid])>`).
So `SelfCapture`, a ScreenCaptureKit capture of OldTunes alone, hears iCloud songs as well as files.
replayd, which runs the capture, makes the audio tap itself, on its own entitlements; the app's own
permissions don't come into it. The probe under "Measured" showed this with a service of its own and
no permission at all, and the `selfcapture` bench with a real iCloud song.

Which ears the visualizer uses (`VisualizerAudio`):

- The tap when OldTunes is known to have System Audio Recording: the cloud route is playing a song
  out (which proves it), this launch's probe heard its tone at the first iCloud song, or, before then,
  the last launch's probe did (`SystemAudioProbe.lastAnswer`, kept per signing certificate, as macOS
  keeps the permission).
  Benches always use the tap: only it can mute, and the tap benches check it. On macOS 14.2 and 14.3
  it is always the tap, as before.
- `SelfCapture` otherwise, on macOS 14.4 and later. There the visualizer raises the permission
  prompt only if the last launch's answer is out of date (a tap is made only with the permission
  known granted); otherwise only the first iCloud song does, for the volume and Sound Check.
- Ears that have heard nothing since they started, while a song played long enough for the watchdog's
  permission hint, give way to the other kind if that can hear (a tap only with the permission). A
  silence after sound is the music's own and changes nothing, as before. When no other ears can take
  over, the permission hint shows, as before: the permission is what makes a tap possible (after
  reopening OldTunes, at its first iCloud song). A `SelfCapture` stopped from the menu bar stays
  stopped until the visualizer is turned on again; if no tap can take over, a hint says to turn the
  visualizer off and on. Each new song gives deaf ears a fresh chance. A last launch's "granted" is
  forgotten once the tap has heard nothing in two songs.

What it costs: macOS counts the capture as sharing the screen. Control Center lists the stream and
Notification Center logs "Display sharing state changed to: true", so the menu bar's screen-sharing
icon is expected, and notifications are held by default while a screen is shared. Nobody has looked
at either yet: the probe ran while the Mac was locked. The video ScreenCaptureKit insists on is
16 × 16 pixels once a second, thrown away. Sound arrives in 20 ms buffers 31–34 ms late on the median,
so the renderer reads 50 ms behind the present while `SelfCapture` is in use
(`VisualizerEars.readDelay`). Now and then, after a buffer about 38 ms late or more, two steps read
the same window.

To try it on a Mac that has the permission, launch a Debug build with
`OLDTUNES_SIMULATE_NO_SYSTEM_AUDIO=1`: OldTunes then plays as if the permission were off from the
start (no route, iCloud songs at their own level), and the visualizer picks `SelfCapture`.
`OLDTUNES_VIS_EARS=tap` or `self-capture` forces one kind whatever the permission; forcing
`self-capture` while the route plays a song out makes it hear that song twice, so use the first.

How this was found (October 29, 2026): six approaches were researched, each with a skeptic. Music's
`download` command plus decoding the file (about 99% of the library would download unprotected, but
it needs the Automation permission, writes about 10 MB a song and was never tried from the sandbox)
and the system content-sharing picker (a click every launch) survived. Previews, metadata, Apple's
player internals and an audio driver didn't. The picker's investigator noticed
`currentProcess`; the probe under "Measured" showed it works.

## Source

Geiss HDR version "335", read on 2026-10-20 from https://www.geisswerks.com/geiss_hdr/run.html.
The site refuses plain curl (HTTP 406); read it in a browser. These hashes let a later version be
compared file by file.

| Module | Bytes | Lines | SHA-256 | Ported as |
|---|---|---|---|---|
| main.js | 102157 | 3340 | `93844609934e7bdeb21a1e90337d1f5cce84eea0e2a8fd82d691cba7c054cfdb` | Only the engine part of `render()` and `frame()`: `Engine/Driver.swift` |
| engine.js | 65923 | 1909 | `93b0e7d7131a8956214960c4d715d299a769a47212aae3ad12928abd0897c92f` | `Engine/WarpEngine.swift`, `Engine/WarpSlots.swift` |
| motion.js | 79810 | 2314 | `38ad3b83813f6b7223b68f76ce0f4b828a0a7c49f2c2129885e56a497b15ba0e` | `Engine/WarpMapBuilder.swift`, `Engine/WarpModes+*.swift` |
| gpu_warp.js | 34082 | 1085 | `29fe2758a359c7b51792ceb85040bb2ba442cf09afd7916c704882bc14126d0d` | `Render/GPUWarp.swift`, `Render/Shaders.swift` |
| palette.js | 34691 | 542 | `65405407ebf6fb8b55c970270ae2f4663383437facd8ed7dc5ece5f664e16d04` | `Engine/Palettes.swift` (not the palette-editing helpers) |
| webgpu_present.js | 14847 | 466 | `6b18640707eee68825d7e707b58f5d86f5de301935b79b64ba5ca3191d227f80` | `Render/Presenter.swift`, `Render/Shaders.swift` |
| audio_input.js | 13734 | 481 | `58692f5fa308924a4ef23ce7c30c16906ef746b9f25ae31f01329f325bf40c9f` | Only `getFrame()`: `Audio/AudioFrame.swift` |
| warp.js | 13572 | 393 | `b95d5672adb258191f2b296694bd3ad4b21205c1685a76249a81edb0364fb2f9` | Only `AdvectPoint`: `Engine/Advect.swift` |
| wave_align.js | 11115 | 357 | `27861eb5fe6fbf264b7b47c766269057052aca59a89eb2ca99e0bd0c4bb3e44b` | `Engine/WaveAligner.swift` |
| gpu_text_overlay.js | 10594 | 410 | `47abd9054ca7f4d72340756e17208f47de6760123199b12c4e9c2559984c2042` | Not ported (song-title burn-in) |
| dot_renderer.js | 9131 | 283 | `5bfdd9d3f3f00dda02b92f54a09f22d43c0fdc04142f698e4b797207e57d3a8a` | `Render/DotRenderer.swift`, `Render/Shaders.swift` |
| draw_palette.js | 6840 | 208 | `92e276e0ba0e4d98a5e1179732970edd812b6941065aacb6e5b3e2b598e8fee3` | `Render/PaletteOverlay.swift`, `Render/Shaders.swift` |
| noise_textures.js | 4184 | 115 | `da3cc0ac04778882c90b8453c864682ee5c5f249f56bf9b3caf7474a75ae087b` | `Render/GPUWarp.swift` |
| beat_detect.js | 4153 | 135 | `d030ccc52f1ce722e6d396217c8d1c70203928afac3dac663e31342ee26dbcca` | Not ported (its import is commented out) |
| coords.js | 2508 | 86 | `a68f2b9b26872b4e1334a81173bf152149071059a3f75ee58863c244dc49444c` | `Engine/TransformHelper.swift` |
| background_worker.js | 1277 | 44 | `327881bc6a4f325779b22c4cbded8393a5d6baaaad15671fbfbe5fb1c122538b` | A background task |
| const.js | 1149 | 32 | `66b24a8955b45ecc2b45bca9184340766f5d3c1a84ed102c476e1d8aeaa2c509` | `Engine/Constants.swift` |
| error.js | 985 | 31 | `4b855993fc2f7970968d66c07eac0e68d1b334611a3ed5b8242e4a042db3221b` | Not ported |
| version.js | 31 | 2 | `1d04b1bcb6004f44538c74eb65a5b1ad53cf833ebe761d107aa8dfd8b14b52fa` | — |
| LICENSE.txt | 10172 | 176 | `59899c6091b540582ed617e8eeaac4919dc985ccfc35459ee9752b699be5205b` | `VisualizerCore/LICENSE.txt`, verbatim |
| NOTICE.txt | 1500 | 37 | `4c5122f9e186d18f3678595f3c90be58b95126cb3cb764f403cb5da40ee89260` | `VisualizerCore/NOTICE.txt`, verbatim |
| OUTPUTS.txt | 445 | 11 | `69732bc5a294768a2ee97d9d6a96a00626bb72daff8b2df0d501a5c26e00f944` | `VisualizerCore/OUTPUTS.txt`, verbatim |

## Porting rules

JavaScript carries on where Swift stops the app, so the port follows these rules:

- **`x | 0`** goes through `toInt32(x)`, which turns NaN and infinity into 0, like JavaScript does.
  `Int(x)` would crash on them.
- **Every array index is checked** or clamped. Out of range in JavaScript is `undefined`, which
  turns into NaN and keeps going; in Swift it crashes.
- **Arithmetic is `Double`, storage is `Float`.** JavaScript numbers are doubles and the original
  stores results in `Float32Array`s. Doing the same keeps seeded runs within float rounding.
- **Random numbers come in the original order** from a `RandomSource`. Benches seed it with
  mulberry32, the same generator `tools/visualizer-fixtures.js` puts in place of `Math.random`, so
  the Swift and JavaScript runs see the same numbers.
- **One Swift file per JavaScript module**, in the same order, so a later Geiss HDR version can be
  diffed and merged module by module.

## Licence rules

- Every ported file starts with the original Geiss HDR header, its paths pointing at
  `VisualizerCore/`, plus one line saying what was changed. Apache-2.0 §4(b) requires the second
  part and §4(c) the first.
- The app bundle carries `LICENSE.txt` and `NOTICE.txt`, and the About panel says "Visualizer based
  on Geiss HDR by Ryan Geiss". The visualizer's key list (H) says it too.
- "Geiss" and "Geiss HDR" are reserved names: only for describing origin, never as the name of the
  feature, a menu item, a type or a file. The feature is called "Visualizer". Noah may ask Ryan
  whether the menu item can say "Geiss"; until he says yes, it doesn't.

## Decisions (Noah, 2026-10-20)

- Name: "Visualizer" (see above).
- HDR: on for screens that can show it, with a Settings checkbox to turn it off.
- Full screen: ⇧⌘F. ⌃⌘F stays the plain window full screen; ⌘F stays Search.
- Keys: Geiss HDR's keys work while the visualizer shows. Space stays Play/Pause, so "randomize
  everything" moves from Space to R. H shows the key list.
- Turn On Visualizer is ⌘T, in a Visualizer menu after Controls (iTunes 4.9's place).
- The visualizer is off at every launch, and its ears exist only while it's on.

## Test bench

```bash
open -n --env OLDTUNES_HARNESS=visualizer --env OLDTUNES_VIS_MODE=<mode> build/dd/Build/Products/Debug/OldTunes.app
```

Run it on your Mac, from the repo (or worktree) folder the app was built in.

| `OLDTUNES_VIS_MODE` | Checks |
|---|---|
| `core` | The sample ring and the host clock, which every other part leans on |
| `parity` | The ported engine against numbers from the original JavaScript (warp maps, palettes, aligner, AdvectPoint) |
| `audio` | The tap, the sample ring, the AnalyserNode emulation against Chrome's, the watchdog |
| `selfcapture` | Which ears are picked, every case; with `OLDTUNES_VIS_AUDIBLE=1` also `SelfCapture` live: a local file and an iCloud song reach the feed, a paused song is silence, delivery within the read delay, 10 start/stop cycles. It plays out loud, a few seconds of each, because it can't mute |
| `render` | The Metal renderer: HDR and SDR set-up, frame time, Metal validation |
| `ui` | The button, the menu, full screen, the keys, the Settings checkbox |
| `cycles` | Fifty on/off cycles in a small window kept above other windows, then checks nothing is left behind |

Benches tap muted, so they make no sound, unless `OLDTUNES_VIS_AUDIBLE=1`; `selfcapture`'s live
checks run only then. Before a run:
`pgrep -lx OldTunes` must print nothing (benches share settings and the log with the real app),
and the build must be signed "Apple Development: Noah Tsutsui" (team 92N52YB23U). Unlock the
screen first: while the Mac is locked no window is visible, so the visualizer draws nothing and
full screen never finishes, and `ui`, `cycles` and `render` fail.

## Measured

On 2026-10-20, on a MacBook Pro (Apple M2 Max) with its built-in 120 Hz screen, in a Debug build.

| What | Result | Bench |
|---|---|---|
| The analyser against Chrome's | Levels within 0.00004 dB; time-domain samples exact (48 frames) | `audio` |
| The engine against the original JavaScript | All 34 warp modes, the palettes, the aligner and AdvectPoint exact | `parity` |
| One warp map | 0.53 ms on average, 5.8 ms for the slowest mode; 2.3 ms on one thread | `parity` |
| One engine step | 0.17 ms on average at 1512×982 | `parity` |
| GPU time | 0.45 ms a step in HDR at 1512×982 | `render` |
| In the window | 355 frames in 3 s, 120 steps a second, none skipped | `ui` |
| At 60 Hz | 60 frames and 120 steps a second: two steps a frame | `ui` |
| 50 on/off cycles | No taps, aggregate devices or frames left after off; Metal memory flat (13.5 MB in the first ten rounds and the last ten); the extra worker threads gone within 4 s | `cycles` |
| Building the tap | About 70 ms | `audio` |
| Permission off, then on (Noah, by hand) | A tap built with System Audio Recording off hears only zeros, so the note appears about 6 s into a song. It clears 13 s after the permission comes back, with the next 30-s retry and no relaunch (tested with a local file). Switching the permission off doesn't silence a tap that's already running; only the next tap goes deaf | by hand |

Still to check with Noah (M5): the picture side by side with the original in Chrome, and a long
listening test. Done by hand on 2026-10-20: the HDR highlights ("it looked great") and the permission note.

`SelfCapture` before it was in OldTunes, on 2026-10-29, macOS 27.0.1, with a probe app and an XPC
service of its own (`tools/self-capture-probe`; its `build.sh` says how to run it), sandboxed and
ad-hoc signed, never granted Screen Recording or System Audio Recording. Each played an inaudible tone
(19 kHz and 18 kHz, −60 dBFS), the service's starting 10 s after the capture. The Mac was locked.

| What | Result |
|---|---|
| Permission | `CGPreflightScreenCaptureAccess()` false; replayd logged "TCC Disallow" and started the stream anyway; TCC saw preflights only; no prompt |
| The app's own tone | −63.0 dBFS RMS, the right level for a −60 dBFS sine; 100% non-zero |
| The hosted service's tone | −63.0 dBFS RMS; replayd re-listed the app's related processes when the service started |
| Silence | Exact zeros |
| Window minimized, app hidden | No change, capturing the window (with the screen locked, so nothing was on screen anyway) |
| Only window ordered out after the capture started | No change, capturing the window and capturing the app (as `SelfCapture` does) |
| Format | 48 kHz, 2 ch, 32-bit float, non-interleaved, 960 frames a buffer |
| Delivery | 31–34 ms late on the median and 46–49 ms at worst in each run of about 1,100 buffers (once 66 ms); the stream clock converts to host time to within 2 ms |

Then in OldTunes, the `selfcapture` bench at 6:54 AM PT the same day, on the MacBook Pro (Apple M2
Max), in a Debug build signed with Developer ID (so it shares the installed app's Media & Apple Music
grant; replayd doesn't consult its System Audio Recording one). 18 PASS, 0 FAIL:

| What | Result |
|---|---|
| Permission | Screen Recording preflight false; replayd "TCC Disallow", stream started anyway; TCC preflights only, no prompt |
| Building `SelfCapture` | 100 ms; the slowest of 10 start/stop cycles 149 ms, nothing restarting after the last stop |
| A local file, at a tenth of full volume | 68% non-zero, −51.5 dBFS |
| An iCloud song (FairPlay), RemotePlayerService started after the capture | 100% non-zero, −13.0 dBFS: copy-protected sound isn't held back |
| The song paused | Exact zeros |
| Lag of the newest sample, sampled every 25 ms | Median 42 ms, worst 62 ms (it includes each buffer's wait for the next); read delay 50 ms |

Not yet tried: what the menu bar and notifications do, minimizing or hiding with the screen
unlocked, a capture started with no window on screen, and macOS earlier than 27.
