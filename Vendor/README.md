# Vendor

## CXXMonkeysAudio

A copy of [sbooth/CXXMonkeysAudio](https://github.com/sbooth/CXXMonkeysAudio) 12.13.0 (commit
`79cafc4`): the Monkey's Audio SDK packaged for SwiftPM, which SFBAudioEngine uses to play `.ape`
files. `project.yml` lists this folder as a local package, so Xcode builds it in place of the GitHub
copy SFBAudioEngine asks for. Nothing else changes: SFBAudioEngine still comes from GitHub.

**Why.** 12.13.0's `Sources/MAC/MACLib/MD5.cpp` is under the GPL (version 2 or later), although
the rest of Monkey's Audio is 3-clause BSD. The file is Frank Klemm's MD5 from dietlibc (dietlibc's
changelog for 0.12: "add Frank Klemm's optimized md5"), and it has been in the Monkey's Audio SDK
since at least 3.99. SFBAudioEngine's Monkey's Audio encoder calls it, and the linker always keeps
that encoder, so the code ends up in oldTunes even though oldTunes never encodes. Monkey's Audio
replaced the file itself in 12.74 (April 27, 2026), with a FreeBSD MD5 under RSA's MD5 licence.

**What differs from 12.13.0.**

- `Sources/MAC/MACLib/MD5.cpp`: the official Monkey's Audio 13.43 SDK file, byte for byte.
- `Sources/MAC/MACLib/MD5.h`: the 13.43 file, with `APE_INLINE` spelled `__forceinline`, 12.13's
  name for it.
- `.github/` is left out.

Both MD5s give the same digests (the RFC 1321 test vectors, and 2,000 random messages checked
against CommonCrypto), and the old and new encoders write byte-identical `.ape` files.

RSA's licence asks that this MD5 be named "derived from the RSA Data Security, Inc. MD5
Message-Digest Algorithm" wherever it is mentioned. The About box says so, and the app carries
the notice as `Licenses/RSA-MD5.txt` (`docs/LICENSES.md`).

**When to remove it.** Once SFBAudioEngine resolves a CXXMonkeysAudio release built from Monkey's
Audio 12.74 or later: delete this folder and the `CXXMonkeysAudio` entry under `packages:` in
`project.yml`, and update the Monkey's Audio version in `Credits.html` and `docs/LICENSES.md`.
Keep `RSA-MD5.txt`: the new MD5 still needs its notice. To see which MD5 the newest
CXXMonkeysAudio ships, on your Mac, from any directory (a GPL one starts with a box of asterisks
and says "GNU General Public License"):

```bash
curl -s https://raw.githubusercontent.com/sbooth/CXXMonkeysAudio/main/Sources/MAC/MACLib/MD5.cpp | head -8
```
