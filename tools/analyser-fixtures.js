// Makes oldTunes/Visualizer/Harness/VisualizerFixtures+Analyser.swift: what Geiss HDR's own
// AudioInput.getFrame() returns in Chrome for a synthetic signal the visualizer bench can rebuild
// exactly. The bench (OLDTUNES_VIS_MODE=audio) checks the Swift AnalyserNode and getFrame port
// against these numbers.
//
// Run it on https://www.geisswerks.com/geiss_hdr/run.html, in Chrome's DevTools console or Claude's
// built-in browser. It imports audio_input.js from that site when it runs, so no Geiss HDR code is
// copied into this repo. It returns { swift, sha256, checks }; save `swift` as the file above and
// compare its SHA-256.
//
// The signal is built only from powers of two (saw, square and triangle waves with power-of-two
// periods, and mulberry32 noise cut to 16 bits), so JavaScript and Swift produce the same samples
// to the bit. It has a stretch of exact silence and a decaying burst, to exercise the smoothing.

const RATE = 48000;
const FRAMES = 30720;
const FFT = 2048;
const SEED = 20261020;
const FIRST_END = 4096;   // the first window ends here: a full 2048 samples back, on a 128-frame quantum
const STEP = 384;         // three render quanta between snapshots, about 125 per second
const SNAPSHOTS = 48;
const BINS = [0, 1, 3, 8, 16, 21, 43, 64, 85, 128, 171, 256, 384, 512, 768, 1023];
const WAVE_INDICES = [0, 1, 1000, 2046, 2047];
const BANDS = [ { f0: 30, f1: 200 }, { f0: 200, f1: 2200 }, { f0: 2200, f1: 12000 }, { f0: 30, f1: 12000 } ];

function mulberry32(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6D2B79F5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function makeSignal() {
  const rand = mulberry32(SEED);
  const L = new Float32Array(FRAMES);
  const R = new Float32Array(FRAMES);
  for (let n = 0; n < FRAMES; n++) {
    const noiseL = Math.floor(rand() * 65536) / 65536 - 0.5;
    const noiseR = Math.floor(rand() * 65536) / 65536 - 0.5;
    const saw = (n % 128) / 128 - 0.5;
    const square = (n % 16) < 8 ? 0.5 : -0.5;
    const triangle = Math.abs((n % 256) / 128 - 1) - 0.5;
    let l = 0.5 * saw + 0.25 * square + noiseL / 32;
    let r = 0.5 * triangle + noiseR / 32;
    if (n >= 9600 && n < 14400) { l = 0; r = 0; }
    if (n >= 14400) {
      const burst = ((n % 512) < 256 ? 0.75 : -0.75) / 2 ** Math.floor((n - 14400) / 1024);
      l += burst;
      r -= burst / 2;
    }
    L[n] = l;
    R[n] = r;
  }
  return { L, R };
}

const f9 = x => x === -Infinity ? '-.infinity' : x === Infinity ? '.infinity' : Math.fround(x).toPrecision(9);
const d17 = x => x.toPrecision(17);

async function run() {
  const { AudioInput } = await import('https://www.geisswerks.com/geiss_hdr/audio_input.js');
  const { L, R } = makeSignal();
  const mono = new Float32Array(FRAMES);
  for (let n = 0; n < FRAMES; n++) mono[n] = Math.fround(Math.fround(L[n] + R[n]) * 0.5);

  const ctx = new OfflineAudioContext(2, FRAMES, RATE);
  const buffer = ctx.createBuffer(2, FRAMES, RATE);
  buffer.copyToChannel(L, 0);
  buffer.copyToChannel(R, 1);
  const source = ctx.createBufferSource();
  source.buffer = buffer;

  // Set up exactly as AudioInput.startMP3/startMic/startTab do.
  const analyser = ctx.createAnalyser();
  analyser.fftSize = FFT;
  analyser.smoothingTimeConstant = 0.6;
  analyser.minDecibels = -100;
  analyser.maxDecibels = -30;
  source.connect(analyser);
  analyser.connect(ctx.destination);

  const input = new AudioInput({ fftSize: FFT });
  input.ctx = ctx;
  input.analyser = analyser;
  input.waveF = new Float32Array(FFT);
  input.spectrum = new Float32Array(FFT / 2);

  const snapshots = [];
  let worstMonoMismatch = 0;
  for (let k = 0; k < SNAPSHOTS; k++) {
    const end = FIRST_END + STEP * k;
    // Halfway into the quantum, so rounding the time either way lands on the same boundary.
    ctx.suspend((end + 64) / RATE).then(() => {
      const decibels = new Float32Array(FFT / 2);
      analyser.getFloatFrequencyData(decibels);        // the analysis for this moment
      const timeDomain = new Float32Array(FFT);
      analyser.getFloatTimeDomainData(timeDomain);
      // Where does Chrome's window end? Find where it equals ½(L+R), trying quantum boundaries
      // nearest the suspend time first: in the silent stretch every all-zero window matches.
      let found = -1;
      for (const e of [end + 128, end, end + 256, end - 128]) {
        let same = true;
        for (let i = 0; i < FFT && same; i++) same = timeDomain[i] === mono[e - FFT + i];
        if (same) { found = e; break; }
      }
      if (found >= 0) {
        for (let i = 0; i < FFT; i++) worstMonoMismatch = Math.max(worstMonoMismatch, Math.abs(timeDomain[i] - mono[found - FFT + i]));
      }
      // The original getFrame; its getFloatFrequencyData at the same moment does not analyse again.
      const frame = input.getFrame({ waveScale: 1.0, wantWave: true, wantSpec: true, bandsHz: BANDS });
      snapshots.push({
        end, found,
        rms: frame.rms, visualEnergy: frame.visual_energy,
        bands: Array.from(frame.bandEnergy),
        decibels: BINS.map(b => decibels[b]),
        spectrum: BINS.map(b => frame.spectrum[b]),
        wave: WAVE_INDICES.map(i => frame.wave[i]),
      });
      ctx.resume();
    });
  }
  source.start(0);
  await ctx.startRendering();

  const lines = [];
  lines.push('// Generated by tools/analyser-fixtures.js. Do not edit by hand.');
  lines.push(`// What Geiss HDR v335's AudioInput.getFrame() returned in ${navigator.userAgent.match(/Chrome\/[\d.]+/)?.[0] ?? 'Chrome'}`);
  lines.push('// for the synthetic signal VisualizerHarness+Audio.swift rebuilds (see the tool for its recipe).');
  lines.push('');
  lines.push('enum AnalyserFixtures {');
  lines.push('    struct Snapshot {');
  lines.push('        /// Where the analyser window ends (exclusive), in frames from the start of the signal.');
  lines.push('        let end: Int');
  lines.push('        let rms: Double');
  lines.push('        let visualEnergy: Double');
  lines.push('        let bands: [Float]');
  lines.push('        /// getFloatFrequencyData at `bins`.');
  lines.push('        let decibels: [Float]');
  lines.push('        /// getFrame\'s perceptual spectrum at `bins`.');
  lines.push('        let spectrum: [Float]');
  lines.push('        /// getFrame\'s wave at `waveIndices`.');
  lines.push('        let wave: [Float]');
  lines.push('    }');
  lines.push('');
  lines.push(`    static let sampleRate = ${RATE}.0`);
  lines.push(`    static let frames = ${FRAMES}`);
  lines.push(`    static let seed: UInt32 = ${SEED}`);
  lines.push(`    static let bins = [${BINS.join(', ')}]`);
  lines.push(`    static let waveIndices = [${WAVE_INDICES.join(', ')}]`);
  lines.push('');
  lines.push('    static let snapshots: [Snapshot] = [');
  for (const s of snapshots) {
    const end = s.found >= 0 ? s.found : s.end;
    lines.push(`        Snapshot(end: ${end}, rms: ${d17(s.rms)}, visualEnergy: ${d17(s.visualEnergy)},`);
    lines.push(`                 bands: [${s.bands.map(f9).join(', ')}],`);
    lines.push(`                 decibels: [${s.decibels.map(f9).join(', ')}],`);
    lines.push(`                 spectrum: [${s.spectrum.map(f9).join(', ')}],`);
    lines.push(`                 wave: [${s.wave.map(f9).join(', ')}]),`);
  }
  lines.push('    ]');
  lines.push('}');
  lines.push('');
  const swift = lines.join('\n');
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(swift));
  const sha256 = [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('');
  return {
    swift, sha256,
    checks: {
      snapshots: snapshots.length,
      windowEndsFound: snapshots.filter(s => s.found >= 0).length,
      windowEndOffsets: [...new Set(snapshots.map(s => s.found - s.end))],
      worstMonoMismatch,
    },
  };
}

await run();
