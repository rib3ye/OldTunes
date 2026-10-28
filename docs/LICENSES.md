# Third-party licences

OldTunes ships open-source code: GRDB, SFBAudioEngine, and the libraries SFBAudioEngine pulls
in. Their licences ask for credit, and most ask for a copy of the licence text with the app. The
About box (`OldTunes/App/Credits.html`) credits each library and names its licence file. The
files sit in `OldTunes/App/Licenses/`, which `project.yml` copies whole into the app as
`Contents/Resources/Licenses/`. Geiss HDR's licence and NOTICE stay in `Contents/Resources`
(`docs/VISUALIZER.md`).

## What ships

| Library | Version | Where it is in the app | Licence |
|---|---|---|---|
| GRDB | 7.11.1 | Built into the OldTunes binary | MIT |
| SFBAudioEngine | 0.14.0 | Built in | MIT |
| loudness_ebur128 (Google), inside SFBAudioEngine | — | Built in | Apache-2.0 |
| dsd2pcm (Sebastian Gesemann), inside SFBAudioEngine | — | Built in | BSD-2-Clause-Views |
| AVFAudioExtensions, CXXAudioRingBuffer, CXXDispatchSemaphore, CXXMessageQueue, CXXQueue, CXXUnfairLock | 0.5.1, 0.2.0, 0.4.1, 0.2.2, 0.1.1, 0.3.1 | Built in | MIT |
| TagLib (CXXTagLib) | 2.3.2 | Built in | MPL-1.1 (TagLib is LGPL-2.1 or MPL-1.1; OldTunes uses MPL) |
| Monkey's Audio SDK (CXXMonkeysAudio, from `Vendor/`) | 12.13, with 13.43's MD5 | Built in | BSD-3-Clause; the MD5 is under RSA's MD5 licence (see "Monkey's Audio's MD5") |
| DUMB (CDUMB, kode54's fork) | 2.0.3 | Built in | DUMB licence (zlib-style); its LPC code is Xiph BSD plus the Degener/Bormann notice |
| Speex and SpeexDSP (CSpeex) | 1.2.1 | Built in | BSD-3-Clause |
| FLAC | 1.5.0 | `Contents/Frameworks/FLAC.framework` | BSD-3-Clause |
| Ogg | 1.3.6 | `ogg.framework` | BSD-3-Clause |
| Vorbis | 1.3.7 | `vorbis.framework` | BSD-3-Clause |
| Opus, Opusfile, libopusenc | 1.6.1, git `cc04a82`, 0.3 | `opus.framework` | BSD-3-Clause, one licence each |
| WavPack | 5.9.0 | `wavpack.framework` | BSD-3-Clause |
| Musepack | r475 plus an added stream encoder | `mpc.framework` | Decoder BSD-3-Clause, encoder LGPL-2.1 |
| LAME | 3.100 | `lame.framework` | LGPL-2.0 (the Library GPL) |
| mpg123 | 1.33.4 | `mpg123.framework` | LGPL-2.1 |
| libsndfile | 1.2.2 | `sndfile.framework` | LGPL-2.1; its ALAC code is Apache-2.0, GSM 6.10 and G.72x have their own notices |
| TTA (libtta-cpp) | 2.3 | `tta-cpp.framework` | LGPL-3.0, which needs the GPL-3.0 text too |

The upstream version inside each binary framework is in the name of the package's GitHub release
(for example `sbooth/lame-binary-xcframework` release 0.1.2 is "LAME 3.100"). Those frameworks
are built from `github.com/sbooth/AudioXCFrameworks`, which holds each library's source, its
patches and its Xcode project. The folders behind OldTunes's frameworks have not changed since the
builds, so its commit `03caaf2` (13 Feb 2026) has the exact source.

## Where each file comes from

Package paths are inside the package's checkout, which a build puts in
`build/dd/SourcePackages/checkouts/<package>/`; CXXMonkeysAudio's is `Vendor/CXXMonkeysAudio/`.
"Verbatim" means byte for byte.

| File | Bytes | SHA-256 | Source |
|---|---|---|---|
| GRDB.txt | 1062 | `9853f9dce81365fcc1d9b46004633354450164b8d17904e92e80c444545f7e87` | GRDB.swift 7.11.1 `LICENSE`, verbatim |
| SFBAudioEngine.txt | 1078 | `59de26e7c7784ae9652a78547004a167933b1a125bbe17de77e8ababf80e180f` | SFBAudioEngine 0.14.0 `LICENSE.txt`, verbatim |
| Apache-2.0.txt | 11358 | `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30` | SFBAudioEngine 0.14.0 `Sources/CSFBAudioEngine/Analysis/loudness_ebur128/LICENSE.txt`, verbatim (the standard Apache 2.0 text; libsndfile's ALAC code uses it too) |
| dsd2pcm.txt | 1522 | `dbb9de2c8101e4e552dad9427552b3306e04baae257973a255f39a2e5123f791` | SFBAudioEngine 0.14.0 `ACKNOWLEDGMENTS.md`, the dsd2pcm notice (lines 8–36) |
| AVFAudioExtensions.txt | 1078 | `99f84cec023b658901b0e638b9fff3b947824996f226a1617351d44ad01a0878` | AVFAudioExtensions 0.5.1 `LICENSE.txt`, verbatim |
| CXXAudioRingBuffer.txt | 1078 | `99f84cec023b658901b0e638b9fff3b947824996f226a1617351d44ad01a0878` | CXXAudioRingBuffer 0.2.0 `LICENSE.txt`, verbatim |
| CXXDispatchSemaphore.txt | 1078 | `5a9a34489410fd62a3ebccf4c897e4fb4c78591d8a2804da631fca29f9cdef09` | CXXDispatchSemaphore 0.4.1 `LICENSE.txt`, verbatim |
| CXXMessageQueue.txt | 1073 | `09faa2ae9891cbd313e84ff6ba0a9f4f9a7457c9af6aadcce2fe7b3bbb935fbc` | CXXMessageQueue 0.2.2 `LICENSE.txt`, verbatim |
| CXXQueue.txt | 1073 | `09faa2ae9891cbd313e84ff6ba0a9f4f9a7457c9af6aadcce2fe7b3bbb935fbc` | CXXQueue 0.1.1 `LICENSE.txt`, verbatim |
| CXXUnfairLock.txt | 1078 | `2f3e627b153e01eb7bd477563077987c422e232964ab89024bbd0a361f72e77a` | CXXUnfairLock 0.3.1 `LICENSE.txt`, verbatim |
| TagLib.txt | 25755 | `53692a2ed6c6a2c6ec9b32dd0b820dfae91e0a1fcdf625ca9ed0bdf8705fcc4f` | CXXTagLib 2.3.2 `LICENSE.txt` (MPL 1.1), verbatim |
| MonkeysAudio.txt | 1537 | `8cb551f3dbe81085540a95c673400fbe2fe335b2f61f3d4ae4c778f6b0a8fd18` | CXXMonkeysAudio 12.13.0 `LICENSE.txt`, verbatim |
| RSA-MD5.txt | 1160 | `7e1f2dff2c874d91b694e052c66635f93c1ba4da22a11d3efb5bcd3786b5f7cf` | The notice atop `Vendor/CXXMonkeysAudio/Sources/MAC/MACLib/MD5.cpp` (Monkey's Audio SDK 13.43's), lines 2–24 without the comment's asterisks, after a line saying where it's from |
| DUMB.txt | 4684 | `8ab37725c26659c9042ced0786904e663c4268a5af3b3f51a1610646444085e0` | CDUMB 2.0.3 `LICENSE.txt`, verbatim |
| Speex.txt | 1773 | `2654a4264b2bfe298dedc508748d140111840c315cc8eb646a3a68c13fa75b01` | CSpeex 1.2.1 `LICENSE.txt`, verbatim |
| FLAC.txt | 1509 | `7866ee98760fc1f0156b4fe6bf530257e02be487ab3fd94e2b63799dd32d6b2c` | AudioXCFrameworks `03caaf2` `flac/flac-src/COPYING.Xiph` (FLAC 1.5.0's own), verbatim. The package's `LICENSE.txt` is older: it says 2011–2023 where FLAC 1.5.0 says 2011–2025 |
| Ogg.txt | 1466 | `d2ab5758336489da61c12cc5bb757da5339c4ae9001f9bb0562b4370249af814` | ogg-binary-xcframework 0.1.3 `LICENSE.txt`, verbatim |
| Vorbis.txt | 1470 | `ec1815db59fcd302846df949d7424876cb2e2dc5ed1606c5fb0b36787b1cf43a` | vorbis-binary-xcframework 0.1.2 `LICENSE.txt`, verbatim |
| Opus.txt | 1945 | `01e1167d54a096d123cf6dfbbeb19587278845c6481d2d66d545669846079551` | opus-binary-xcframework 0.3.0 `LICENSE.txt` (libopus only), verbatim |
| Opusfile.txt | 1487 | `0267ae795ab744c4e0f9c45e249440fdf2e75dac8c804f36066b28649bf74aaf` | AudioXCFrameworks `03caaf2` `opus/opusfile-src/COPYING`, verbatim |
| libopusenc.txt | 1522 | `93b17ab56b8230127fea532be0dcb4e6d71e66ab5e8ce5d6ae8785d7288b164f` | AudioXCFrameworks `03caaf2` `opus/libopusenc-src/COPYING`, verbatim |
| WavPack.txt | 1561 | `1703dd391c9b422910287add8483a27d9bead0b0b5ccd6d5017e995a7192b3e2` | wavpack-binary-xcframework 0.2.0 `LICENSE.txt`, verbatim |
| Musepack.txt | 1563 | `141f551d8e4f037b7f6bc9136b7d3116c7ae9ec8da10c4f14c07c6dc34bc9aa5` | AudioXCFrameworks `03caaf2` `mpc/musepack-src/libmpcdec/COPYING`, verbatim. The package's `LICENSE-BSD.txt` rewords it into GitHub's BSD template |
| Musepack-encoder.txt | 26525 | `814cf1a7e79dc6a3eda3d197fa7ded36c3b733917ed5da1e8cc135eb24f3ac09` | mpc-binary-xcframework 0.1.2 `LICENSE-LGPL.txt`, verbatim |
| LAME.txt | 25284 | `bfe4a52dc4645385f356a8e83cc54216a293e3b6f1cb4f79f5fc0277abf937fd` | lame-binary-xcframework 0.1.2 `LICENSE.txt`, verbatim |
| mpg123.txt | 40718 | `c22482728a634a8dfdb4ff72a96d4c1ed64cd8f3e79335c401751ac591609366` | mpg123-binary-xcframework 0.3.1 `LICENSE.txt` (mpg123's `COPYING`), verbatim |
| libsndfile.txt | 26518 | `ad01ea5cd2755f6048383c8d54c88459cd6fcb17757c5c8892f8c5ea060f6140` | sndfile-binary-xcframework 0.1.2 `LICENSE.txt`, verbatim |
| GSM-6.10.txt | 690 | `1bbe7119b1bcd1489e0f36cb95b8902f7f0ceec9a2f3a67394bc9f4709a4e0a7` | AudioXCFrameworks `03caaf2` `sndfile/libsndfile-src/src/GSM610/COPYRIGHT`, verbatim (DUMB's LPC code carries the same notice) |
| G72x.txt | 1300 | `23c3454853c5c04961121de6fb09a67d5094e46bb0e9ec4312a81ecade94c6da` | AudioXCFrameworks `03caaf2`: the notice atop `sndfile/libsndfile-src/src/G72x/g72x.c` and lines 9–11 of `README.original`, each after a line saying where it's from |
| TTA.txt | 7816 | `ea7d049c7705dc13afc202dd18e1827f3484f8212fd3fa7b82fc4a0c363432c9` | tta-cpp-binary-xcframework 0.1.2 `LICENSE.txt` (LGPL 3), verbatim |
| GPL-3.0.txt | 35149 | `3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986` | The FSF's GPL 3 text, as GNU coreutils 9.12 ships it in `COPYING` |

## When a package version changes

1. After `xcodegen generate` and a build, `Package.resolved` (in
   `OldTunes.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/`) lists every package and
   version.
2. For each new or changed package, read its licence file in the checkout and copy it over the
   matching file in `OldTunes/App/Licenses/`. A binary framework's release name says which
   upstream version is inside. Compare a binary package's licence with the one in the source it
   was built from (AudioXCFrameworks): FLAC's and Musepack's package copies didn't match.
3. Update the versions and copyright lines in `Credits.html`, and the tables here.
4. Check a Release build: `Contents/Resources/Licenses` holds the files, and the About box shows
   the credits.
5. CXXMonkeysAudio comes from `Vendor/`, so a new SFBAudioEngine doesn't change it and
   `Package.resolved` doesn't list it. On every SFBAudioEngine bump, read `Vendor/README.md` ▸
   When to remove it.

## Checked (2026-10-28)

- Each file matches its source above byte for byte.
- The standard licences are the real texts. `Apache-2.0.txt` and `TagLib.txt` (MPL 1.1) are
  byte-identical to Homebrew's copies in caddy and cairo, and `GPL-3.0.txt` to nine Homebrew
  packages'. The LGPL texts (LAME, libsndfile, Musepack encoder, TTA, and both licences inside
  `mpg123.txt`) match Homebrew copies word for word, apart from the FSF's old postal address and
  the optional "How to Apply These Terms" appendix that mpg123 leaves out.
- The prebuilt frameworks' licences match the source they were built from. Ogg's and Opus's also
  match Homebrew's copies of the same releases, and mpg123's matches Homebrew's 1.33.7. Speex and DUMB match their upstream releases
  (Speex and SpeexDSP 1.2.1 on gitlab.xiph.org, kode54/dumb 2.0.3).
- Versions come from `Package.resolved`, and for the binary frameworks from `configure.ac` in
  the exact source or the binary's own version string. Two quirks: DUMB 2.0.3's `dumb.h` still
  says 2.0.2, and opus.framework's libopusenc reports "1.6.1" because the framework is built
  with one `config.h`; its source is libopusenc 0.3.
- Every link in the About box opens. sourceforge.net refuses scripted visits to the TTA project
  page, but its files page loads: "TTA Lossless Audio Codec", libtta 2.3.

## Rules

- Every LGPL library is a separate framework in `Contents/Frameworks`, never built into the
  OldTunes binary. LGPL code built in would oblige OldTunes to let people relink it.
- The About box says where the LGPL libraries' source code is, and where TagLib's is (MPL 1.1
  §3.6 asks for that too).

## Monkey's Audio's MD5

The Monkey's Audio SDK is BSD-licensed, but `MACLib/MD5.cpp` in CXXMonkeysAudio 12.13.0 carries a
GPL-2.0-or-later header: it is dietlibc's MD5, by Frank Klemm. SFBAudioEngine's Monkey's Audio
encoder calls it, and the linker always keeps that encoder, so it was built into OldTunes even
though OldTunes never encodes. Monkey's Audio replaced the file in 12.74 (April 27, 2026). Until
CXXMonkeysAudio catches up, OldTunes builds that package from `Vendor/CXXMonkeysAudio`, with SDK
13.43's MD5 under RSA's MD5 licence (`RSA-MD5.txt`). `Vendor/README.md` has the details and says
when to remove it. Releases built before that change still contain the GPL code.
