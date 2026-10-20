# VisualizerCore

The OldTunes visualizer's engine, renderer and audio analysis. It is a static library, built with
optimization even in Debug, because the engine is numeric Swift.

It is based on [Geiss HDR](https://www.geisswerks.com/geiss_hdr) by Ryan Geiss (version 335), ported
from JavaScript and WebGPU to Swift and Metal.

- **Files with the Geiss HDR header** are derived from Geiss HDR, Apache-2.0. Each one names the
  module it came from and says it was changed. The licence, the NOTICE file and the outputs
  permission sit next to this file, verbatim: `LICENSE.txt`, `NOTICE.txt`, `OUTPUTS.txt`.
- **Files without that header** are OldTunes's own code.

"Geiss" and "Geiss HDR" are Ryan Geiss's reserved names (see `NOTICE.txt`). Use them only to
describe where this code came from, never as the name of the feature, a type or a file.

See `docs/VISUALIZER.md` for the design, the porting rules and how to test.
