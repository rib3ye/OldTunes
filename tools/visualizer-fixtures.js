// Makes OldTunes/Visualizer/Harness/VisualizerFixtures+Engine.swift: what the original Geiss HDR
// (version 335) JavaScript computes for synthetic inputs. The visualizer's parity bench
// (OLDTUNES_HARNESS=visualizer OLDTUNES_VIS_MODE=parity) checks the Swift port against these numbers.
//
// Run it in a browser, not on your Mac's command line:
//   1. Open https://www.geisswerks.com/geiss_hdr/run.html in Chrome. Don't start the visualizer.
//   2. Open the DevTools console, paste this whole file and press Return.
//   3. The Swift file is printed, and copied to the clipboard. Save it over the file named above.
//
// It imports the original modules from geisswerks.com as it runs, so no Geiss HDR code is copied into
// the repo. While it measures, it puts mulberry32 (seeded) in place of Math.random, the same generator
// as RandomSource.mulberry32 in VisualizerCore, and puts Math.random back afterwards. Every input is
// synthetic: seeded random numbers and plain arithmetic, which JavaScript and Swift compute alike.

async function visualizerFixtures() {
  const base = "https://www.geisswerks.com/geiss_hdr/";
  const version = (await import(base + "version.js")).g_version;
  if (version !== "335") throw new Error(`These fixtures are for Geiss HDR 335; the site has ${version}.`);
  const motion = await import(base + "motion.js");
  const palette = await import(base + "palette.js");
  const waveAlign = await import(base + "wave_align.js");
  const warp = await import(base + "warp.js");
  const coords = await import(base + "coords.js");
  const engine = await import(base + "engine.js");

  // ---- Random numbers ------------------------------------------------------------------------

  function mulberry32(seed) {
    let s = seed >>> 0;
    return function () {
      s = (s + 0x6D2B79F5) >>> 0;
      let t = s;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  const originalRandom = Math.random;
  // Runs `body` with Math.random replaced by `random`; nothing else can run in between.
  function withRandom(random, body) {
    Math.random = random;
    try {
      return body();
    } finally {
      Math.random = originalRandom;
    }
  }
  // Makes Math.random return these numbers, in order.
  function scripted(values) {
    let i = 0;
    return () => {
      if (i >= values.length) throw new Error("scripted Math.random ran out");
      return values[i++];
    };
  }

  // ---- Swift text ----------------------------------------------------------------------------

  // A double, as Swift reads it back exactly: the shortest text that round-trips.
  function d(x) {
    if (Number.isNaN(x)) return ".nan";
    if (x === Infinity) return ".infinity";
    if (x === -Infinity) return "-.infinity";
    if (Object.is(x, -0)) return "-0.0";
    const s = String(x);
    return /[.eE]/.test(s) ? s : s + ".0";
  }
  // A Float32 value: the shortest text whose nearest double rounds back to it, which is how Swift's
  // Float(Double(text)) reads it.
  function f(x) {
    if (!Number.isFinite(x) || x === 0) return d(x);
    for (let p = 1; p <= 9; p++) {
      const s = x.toPrecision(p);
      if (Math.fround(parseFloat(s)) === x) return d(parseFloat(s));
    }
    return d(x);
  }
  const list = (values) => `[${values.map(d).join(", ")}]`;
  const floats = (values) => `[${values.map(f).join(", ")}]`;
  const ints = (values) => `[${values.join(", ")}]`;
  // Σ v[i]·((i mod 7) + 1): a checksum that also notices values moving around.
  function checksum(values) {
    let sum = 0.0;
    for (let i = 0; i < values.length; i++) sum += values[i] * ((i % 7) + 1);
    return sum;
  }

  const out = [];
  const line = (s = "") => out.push(s);

  // ---- Warp maps (motion.js) -----------------------------------------------------------------

  const seed = 12345;
  const W = 512;
  const vectorPixels = [];
  for (let k = 0; k < 16; k++) {
    const x = (31 + 157 * k) % W;
    const y = (19 + 211 * k) % W;
    vectorPixels.push(y * W + x);
  }
  const defaults = withRandom(mulberry32(seed), () => motion.buildWarpMap(-1)).warp_prefs;
  for (const key of ["net_motion", "net_zoom_motion", "in_or_out_motion", "net_clockwise_motion", "cw_or_ccw_motion"]) {
    defaults[key] = 0.0;
  }
  const modes = [];
  for (let m = 0; m <= 38; m++) modes.push(m);
  modes.push(98, 99);
  const maps = {};
  const modeLines = [];
  for (const mode of modes) {
    const map = withRandom(mulberry32(seed), () => motion.buildWarpMap(mode));
    maps[mode] = map;
    let sum = 0.0;
    for (let i = 0; i < map.src_dxy.length; i += 997) sum += map.src_dxy[i];
    const vectors = [];
    for (const p of vectorPixels) vectors.push(map.src_dxy[p * 2], map.src_dxy[p * 2 + 1]);
    // Every field that differs from a mode-less map's (including type_flat_plus_circ, NaN in modes 0
    // and 1), plus the five metadata values.
    const prefs = [];
    for (const [key, value] of Object.entries(map.warp_prefs)) {
      const metadata = ["net_motion", "net_zoom_motion", "in_or_out_motion", "net_clockwise_motion", "cw_or_ccw_motion"].includes(key);
      if (metadata || !Object.is(value, defaults[key])) prefs.push(`"${key}": ${d(value)}`);
    }
    modeLines.push(`        WarpMode(mode: ${mode}, checksum: ${d(sum)},\n` +
                   `                 vectors: ${floats(vectors)},\n` +
                   `                 prefs: [${prefs.join(", ")}]),`);
  }
  // The check values from the port's brief came from one mulberry32(12345) stream with maps built back
  // to back: mode 0 first, mode 14 third, mode 17 fourth. Every map takes exactly 1,280 random numbers
  // (a 256-entry bank and 1,024 for the metadata), so skip that many per map built before.
  const streamChecks = [[0, 0, "-0.134563", "0.34821"], [14, 2, "-16.055804", "4.08258"], [17, 3, "-0.894201", "1.46599"]];
  const streamLines = streamChecks.map(([mode, before, sumText, zoomText]) => {
    const random = mulberry32(seed);
    for (let i = 0; i < before * 1280; i++) random();
    const map = withRandom(random, () => motion.buildWarpMap(mode));
    let sum = 0.0;
    for (let i = 0; i < map.src_dxy.length; i += 997) sum += map.src_dxy[i];
    if (sum.toFixed(6) !== sumText || map.warp_prefs.net_zoom_motion.toFixed(5) !== zoomText) {
      throw new Error(`mode ${mode} check value is off: ${sum}, ${map.warp_prefs.net_zoom_motion}`);
    }
    return `        (mode: ${mode}, mapsBefore: ${before}, checksum: ${d(sum)}, netZoomMotion: ${d(map.warp_prefs.net_zoom_motion)}),`;
  });

  // ---- Palettes (palette.js) -----------------------------------------------------------------

  // A preset, chosen by scripting Math.random: 0.5 > 0.02 picks a preset, then (k + 0.5) / N picks k.
  const presetCount = 117;
  function preset(k) {
    const p = withRandom(scripted([0.5, (k + 0.5) / presetCount]), () => palette.GenerateRandomPalette());
    if (p.name !== `Palette ${k}`) throw new Error(`expected Palette ${k}, got ${p.name}`);
    return p.palette;
  }
  // 100 draws from one seeded stream; pick a seed that gives at least two random palettes.
  let paletteSeed = 0;
  let draws = null;
  for (let s = 1; s < 1000; s++) {
    const tried = withRandom(mulberry32(s), () => {
      const r = [];
      for (let i = 0; i < 100; i++) r.push(palette.GenerateRandomPalette());
      return r;
    });
    if (tried.filter((p) => p.name === "Random palette").length >= 2) {
      paletteSeed = s;
      draws = tried;
      break;
    }
  }
  const drawLines = draws.map((p) => {
    const values = Array.from(p.palette);
    const rgba = p.name === "Random palette" ? floats(values) : "nil";
    return `        PaletteDraw(name: "${p.name}", count: ${values.length / 4}, checksum: ${d(checksum(values))}, rgba: ${rgba}),`;
  });
  const firstRandom = draws.findIndex((p) => p.name === "Random palette");

  const sampleT = [-0.25, 0, 0.001, 0.1, 1 / 3, 0.5, 0.7071, 0.999, 1, 1.25, NaN];
  const samplePresets = [0, 2, 84, 85, 86, 116];
  const sampleLines = [];
  for (const k of [...samplePresets, -1]) {
    const p = k >= 0 ? preset(k) : draws[firstRandom].palette;
    const values = [];
    for (const t of sampleT) {
      const c = palette.SamplePalette(p, t);
      values.push(c.r, c.g, c.b);
    }
    sampleLines.push(`        ${list(values)},`);
  }

  // HdrToSdr: black (which comes back NaN), then 64 seeded colours against a few palette maxima.
  const hdrInputs = [[0, 0, 0, 0, 3]];
  withRandom(mulberry32(31337), () => {
    const maxima = [0.5, 1, 2.4, 3, 3.6];
    for (let i = 0; i < 64; i++) {
      hdrInputs.push([i / 63, Math.random() * 3.2, Math.random() * 3.2, Math.random() * 3.2, maxima[i % maxima.length]]);
    }
  });
  const hdrLines = hdrInputs.map((input) => {
    const col = palette.HdrToSdr(input[0], input[1], input[2], input[3], input[4], false);
    return `        (input: ${list(input)}, output: ${floats(Array.from(col))}),`;
  });

  // ---- WaveAligner and Blur (wave_align.js), linearResampleF (engine.js) ---------------------

  // A triangle wave plus seeded noise: only + − × ÷ and floor, so Swift makes the same samples.
  const waveSeed = 99;
  const frameCount = 12;
  const alignFractions = [0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6, 0.55, 0.55, 0.6, 0.6];
  const resampleLengths = [2949, 811, 1, -1];  // −1: the aligned length itself (a copy)
  const probes = [0, 1, 100, 500, 1000, -2, -1];  // negative: from the end
  const aligner = new waveAlign.WaveAligner();
  const random = mulberry32(waveSeed);
  const frameLines = [];
  for (let f = 0; f < frameCount; f++) {
    const period = 160 + 20 * (f % 3);
    const phase = f * 37;
    const wave = new Float32Array(2048);
    for (let i = 0; i < wave.length; i++) {
      const x = (i + phase) / period;
      const tri = 4 * Math.abs(x - Math.floor(x + 0.5)) - 1;
      wave[i] = tri * 0.5 + (random() - 0.5) * 0.05;
    }
    const aligned = aligner.alignFromF(wave, alignFractions[f], wave.length);
    const blurred = waveAlign.Blur(aligned, 2);
    const resampled = resampleLengths.map((n) => engine.linearResampleF(blurred, n < 0 ? blurred.length : n));
    const probe = (a) => probes.map((p) => a[p < 0 ? a.length + p : p]);
    frameLines.push(`        AlignFrame(count: ${aligned.length}, checksum: ${d(checksum(aligned))}, probes: ${floats(probe(aligned))},\n` +
                    `                   blurChecksum: ${d(checksum(blurred))},\n` +
                    `                   resampled: [${resampled.map((r) => `(count: ${r.length}, checksum: ${d(checksum(r))})`).join(", ")}]),`);
  }

  // ---- AdvectPoint (warp.js) -----------------------------------------------------------------

  const advectModes = [14, 8, 17, 3];
  const advectStrengths = new Float32Array([0.42, -0.31, 0.77, 0.05]);
  const advectWidth = 1512;
  const advectHeight = 982;
  const xform = new coords.TransformHelper(advectWidth, advectHeight);
  const warps = advectModes.map((m) => ({ warp_map: maps[m] }));
  const points = [[0, 0], [advectWidth - 1, advectHeight - 1], [-50, 2000], [advectWidth / 2, advectHeight / 2]];
  withRandom(mulberry32(4242), () => {
    for (let i = 0; i < 12; i++) points.push([Math.random() * advectWidth, Math.random() * advectHeight]);
  });
  const advectLines = points.map(([x, y], i) => {
    const speed = i % 2 === 0 ? 1.0 : 0.5;
    const shiftX = i % 3 === 0 ? 1.25 : -0.5;
    const shiftY = i % 4 === 0 ? -0.75 : 0.25;
    const r = warp.AdvectPoint(x, y, xform, warps, advectStrengths, speed, shiftX, shiftY);
    return `        AdvectCase(x: ${d(x)}, y: ${d(y)}, speed: ${d(speed)}, shiftX: ${d(shiftX)}, shiftY: ${d(shiftY)}, outX: ${d(r.x)}, outY: ${d(r.y)}),`;
  });

  // ---- The engine (engine.js) ----------------------------------------------------------------

  // A fresh copy of engine.js (the query string makes the browser load a new instance, with its own
  // module state), loaded while Math.random is seeded: loading it places the 1,024 fading dots and
  // draws the first map durations, 2,051 random numbers. Then an Engine with a 1×1 CPU buffer (its
  // constructor fills it with one random number) runs 3,600 steps with a presenter that records what
  // it's handed. Nothing awaits during the steps, so the background worker's maps never arrive and
  // every map is built on the spot from the seeded stream.
  const engineSeed = 2468;
  const engineAudioSeed = 5150;
  const engineSteps = 3600;
  const engineSampleEvery = 60;
  const engineWidth = 1512;
  const engineHeight = 982;
  const engineRandom = mulberry32(engineSeed);
  let engineDrawn = 0;
  const countedRandom = () => {
    engineDrawn++;
    return engineRandom();
  };
  let engineModule = null;
  Math.random = countedRandom;
  try {
    engineModule = await import(base + `engine.js?fixtures=${Date.now()}`);
  } finally {
    Math.random = originalRandom;
  }
  if (engineDrawn !== 2048 + 3) throw new Error(`engine.js took ${engineDrawn} random numbers while loading, not 2051`);

  const engineLines = withRandom(countedRandom, () => {
    const slotMaps = [null, null, null, null];
    const ordinals = new Map();  // src_dxy → its number, in order of first appearance
    let drawn = null;
    const presenter = {
      SetWarpMap(slot, src) {
        slotMaps[slot] = src;
        if (!ordinals.has(src)) ordinals.set(src, ordinals.size);
      },
      warpAndDrawWaveform(w0, w1, w2, w3, shiftX, shiftY, points, darkening, time) {
        drawn = { weights: [w0, w1, w2, w3], shiftX, shiftY, points, darkening, time };
      },
      gpu_warp: { text_overlay: { get_intensity: () => 0 }, set_overlay_text() {}, burn_overlay_text() {} },
    };
    const eng = new engineModule.Engine(presenter, engineWidth, engineHeight, 1, 1, 3);
    eng.iw = engineWidth;
    eng.ih = engineHeight;

    const audioRandom = mulberry32(engineAudioSeed);
    const lines = [];
    for (let s = 0; s < engineSteps; s++) {
      // The audio: a triangle wave whose period and level change, plus seeded noise; exact arithmetic.
      const wave = new Float32Array(2048);
      const period = 90 + 30 * Math.floor(s / 300);
      const level = 0.3 + 0.2 * ((s % 97) / 97);
      let sumSquares = 0.0;
      let steps = 0.0;
      for (let i = 0; i < wave.length; i++) {
        const x = (i + s * 13) / period;
        const tri = 4 * Math.abs(x - Math.floor(x + 0.5)) - 1;
        wave[i] = tri * level + (audioRandom() - 0.5) * 0.02;
        sumSquares += wave[i] * wave[i];
        if (i > 0) steps += Math.abs(wave[i] - wave[i - 1]);
      }
      const frame = { wave, rms: Math.sqrt(sumSquares / wave.length), visual_energy: steps / (wave.length - 1) };
      const timeNow = 10 + s / 120;
      const motionTime = 3 + s * 0.9 / 120;
      const waveTime = 5 + s * 0.9 / 120;
      const shiftTime = 7 + s * 0.9 / 120;
      const beat = (s % 60 === 30) ? 0.75 : 0.0;
      eng.update(1 / 120, frame);
      drawn = null;
      eng.render(timeNow, motionTime, waveTime, shiftTime, s, s === 1000, s === 100, 120, 2, -1, 96, beat, 1.0,
                 false, false, "", 0.0, 0.6,
                 s === 200, s === 400 || s === 1700, s === 500 || s === 520, s === 600, s === 800, s === 900,
                 "this_is_the_last_param");
      if (s % engineSampleEvery === engineSampleEvery - 1) {
        lines.push(`        EngineSample(step: ${s}, weights: ${floats(drawn.weights)}, shiftX: ${d(drawn.shiftX)}, ` +
                   `shiftY: ${d(drawn.shiftY)}, darkening: ${d(drawn.darkening)}, dotCount: ${drawn.points.length / 4}, ` +
                   `dotChecksum: ${d(checksum(drawn.points))}, slots: ${ints(slotMaps.map((m) => ordinals.get(m)))}),`);
      }
    }
    return lines;
  });

  // ---- The Swift file ------------------------------------------------------------------------

  const browser = (navigator.userAgent.match(/Chrome\/[\d.]+/) || [navigator.userAgent])[0];
  // Which version of this tool made the file: the SHA-256 of this function's source text.
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(visualizerFixtures.toString()));
  const toolHash = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
  line("// Generated by tools/visualizer-fixtures.js. Do not edit by hand.");
  line(`// What Geiss HDR v${version}'s JavaScript computed in ${browser} for the synthetic inputs below; the`);
  line("// parity bench (VisualizerHarness+Parity.swift) checks the Swift port in VisualizerCore/Engine against it.");
  line(`// Tool: SHA-256 of visualizerFixtures' source ${toolHash}.`);
  line();
  line("enum EngineFixtures {");
  line("    // MARK: motion.js");
  line();
  line("    struct WarpMode {");
  line("        let mode: Int");
  line("        /// Σ src_dxy[i] for i = 0, 997, 1994, …");
  line("        let checksum: Double");
  line("        /// (dx, dy) at each of `vectorPixels`.");
  line("        let vectors: [Double]");
  line("        /// warp_prefs fields that differ from a mode-less map's, plus the five metadata values.");
  line("        let prefs: [String: Double]");
  line("    }");
  line();
  line("    /// warp_prefs of a map with no motion (mode −1): every field's starting value.");
  line(`    static let defaultPrefs: [String: Double] = [${Object.entries(defaults).map(([k, v]) => `"${k}": ${d(v)}`).join(", ")}]`);
  line();
  line("    /// Every map is built with Math.random = mulberry32(seed), started fresh.");
  line(`    static let seed: UInt32 = ${seed}`);
  line("    /// Pixels (y·512 + x) where `WarpMode.vectors` samples the map.");
  line(`    static let vectorPixels: [Int] = ${ints(vectorPixels)}`);
  line("    static let warpModes: [WarpMode] = [");
  modeLines.forEach((l) => line(l));
  line("    ]");
  line();
  line("    /// The check values in the port's brief: one mulberry32(seed) stream, maps built back to back, so");
  line("    /// `mapsBefore` × 1,280 random numbers go by first.");
  line("    static let streamChecks: [(mode: Int, mapsBefore: Int, checksum: Double, netZoomMotion: Double)] = [");
  streamLines.forEach((l) => line(l));
  line("    ]");
  line();
  line("    // MARK: palette.js");
  line();
  line("    struct PaletteDraw {");
  line("        let name: String");
  line("        let count: Int");
  line("        /// Σ v[i]·((i mod 7) + 1) over the RGBA values.");
  line("        let checksum: Double");
  line("        /// Every value, for the random (not preset) palettes.");
  line("        let rgba: [Double]?");
  line("    }");
  line();
  line("    /// 100 GenerateRandomPalette() calls in a row, Math.random = mulberry32(paletteSeed).");
  line(`    static let paletteSeed: UInt32 = ${paletteSeed}`);
  line("    static let paletteDraws: [PaletteDraw] = [");
  drawLines.forEach((l) => line(l));
  line("    ]");
  line();
  line("    /// SamplePalette(palette, t) for each t, (r, g, b) in turn, for each of `samplePresets` (−1: the");
  line("    /// first random palette among `paletteDraws`).");
  line(`    static let sampleT: [Double] = ${list(sampleT)}`);
  line(`    static let samplePresets: [Int] = ${ints([...samplePresets, -1])}`);
  line("    static let samples: [[Double]] = [");
  sampleLines.forEach((l) => line(l));
  line("    ]");
  line();
  line("    /// HdrToSdr(t, r, g, b, max_rgb_in_palette): input (t, r, g, b, max), output (r, g, b).");
  line("    static let hdrToSdr: [(input: [Double], output: [Double])] = [");
  hdrLines.forEach((l) => line(l));
  line("    ]");
  line();
  line("    // MARK: wave_align.js, engine.js linearResampleF");
  line();
  line("    struct AlignFrame {");
  line("        let count: Int");
  line("        let checksum: Double");
  line("        /// The aligned wave at `alignProbes`.");
  line("        let probes: [Double]");
  line("        /// Blur(aligned, 2).");
  line("        let blurChecksum: Double");
  line("        /// linearResampleF(blurred, n) for each of `resampleLengths`.");
  line("        let resampled: [(count: Int, checksum: Double)]");
  line("    }");
  line();
  line("    /// Frame f: x = (i + 37f) / (160 + 20·(f mod 3)), wave[i] = Float32(0.5·(4|x − floor(x + 0.5)| − 1)");
  line("    /// + 0.05·(random() − 0.5)), i = 0 … 2047, random = mulberry32(waveSeed) running across frames.");
  line(`    static let waveSeed: UInt32 = ${waveSeed}`);
  line(`    static let alignFractions: [Double] = ${list(alignFractions)}`);
  line("    /// Indices into the aligned wave; negative ones count from the end.");
  line(`    static let alignProbes: [Int] = ${ints(probes)}`);
  line("    /// −1 resamples to the wave's own length (a copy).");
  line(`    static let resampleLengths: [Int] = ${ints(resampleLengths)}`);
  line("    static let alignFrames: [AlignFrame] = [");
  frameLines.forEach((l) => line(l));
  line("    ]");
  line();
  line("    // MARK: warp.js AdvectPoint");
  line();
  line("    struct AdvectCase {");
  line("        let x: Double, y: Double, speed: Double, shiftX: Double, shiftY: Double");
  line("        let outX: Double, outY: Double");
  line("    }");
  line();
  line("    /// The four maps are `warpModes`' maps for these modes; the strengths go through a Float32Array.");
  line(`    static let advectModes: [Int] = ${ints(advectModes)}`);
  line(`    static let advectStrengths: [Double] = ${list([0.42, -0.31, 0.77, 0.05])}`);
  line(`    static let advectSize = (width: ${d(advectWidth)}, height: ${d(advectHeight)})`);
  line("    static let advectCases: [AdvectCase] = [");
  advectLines.forEach((l) => line(l));
  line("    ]");
  line();
  line("    // MARK: engine.js");
  line();
  line("    struct EngineSample {");
  line("        let step: Int");
  line("        /// The four warp strengths (Float32).");
  line("        let weights: [Double]");
  line("        let shiftX: Double, shiftY: Double, darkening: Double");
  line("        let dotCount: Int");
  line("        /// Σ v[i]·((i mod 7) + 1) over the points (x, y, size, alpha, …), a Float32Array.");
  line("        let dotChecksum: Double");
  line("        /// Each slot's map, numbered in order of first appearance.");
  line("        let slots: [Int]");
  line("    }");
  line();
  line("    /// A fresh engine.js, loaded and run with Math.random = mulberry32(engineSeed): Engine(presenter,");
  line("    /// 1512, 982, 1, 1, motion_time 3), then step s = 0 … 3599 with update(1/120, frame) and render(");
  line("    /// time 10 + s/120, motion 3 + s·0.9/120, wave 5 + s·0.9/120, shift 7 + s·0.9/120, fps 120,");
  line("    /// smoothing 2, beat 0.75 when s mod 60 = 30, align_frac 0.6, randomize motion at 1000 and wave at");
  line("    /// 100, toggles: grid 200, fading 400 and 1700, chasers 500 and 520, dotty 600, random beat dots 800,");
  line("    /// radial beat dots 900). The audio is described in VisualizerHarness+Parity.swift.");
  line(`    static let engineSeed: UInt32 = ${engineSeed}`);
  line(`    static let engineAudioSeed: UInt32 = ${engineAudioSeed}`);
  line(`    static let engineSteps = ${engineSteps}`);
  line(`    static let engineSize = (width: ${engineWidth}, height: ${engineHeight})`);
  line("    /// Every 60th step's draw.");
  line("    static let engineSamples: [EngineSample] = [");
  engineLines.forEach((l) => line(l));
  line("    ]");
  line("}");

  const text = out.join("\n") + "\n";
  if (typeof copy === "function") copy(text);  // DevTools console only
  console.log(text);
  return text;
}

await visualizerFixtures();
