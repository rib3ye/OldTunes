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
   OldTunes itself. One Core Audio process tap reads both: a stereo mixdown, unmuted and private,
   inside a private aggregate device clocked by the default output.
2. The IOProc mixes each buffer to mono, ½(L+R), into `SampleRing`, four seconds long.
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
- The visualizer is off at every launch, and the tap exists only while it's on.

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
| `render` | The Metal renderer: HDR and SDR set-up, frame time, Metal validation |
| `ui` | The button, the menu, full screen, the keys, the Settings checkbox |
| `cycles` | Fifty on/off cycles in a small window kept above other windows, then checks nothing is left behind |

Benches tap muted, so they make no sound, unless `OLDTUNES_VIS_AUDIBLE=1`. Before a run:
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
