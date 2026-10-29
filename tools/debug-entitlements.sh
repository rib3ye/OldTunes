#!/bin/zsh
# Writes OldTunes/App/OldTunes-Debug.entitlements, which is not committed: OldTunes.entitlements
# plus four things only Debug builds get, for the benches (docs/DEVELOPMENT.md ▸ Test benches):
#   - /private/tmp/, where benches keep their index, fixtures, snapshots and evidence
#     (OLDTUNES_DB_PATH and the rest). Sandboxed, an app may touch only its own container, and
#     no other process can read that container, so bench files have to live outside it.
#   - ~/Library/Logs/OldTunes/, so a Debug build logs where benches and people read the log
#     (Log.directory).
#   - /opt/homebrew/, to read and run, for the metadata bench's MP3 fixture made with lame
#     (HarnessFixtures): a sandboxed app may otherwise run only the system's own tools.
#   - Music's playback access group, for the A/B bench (AudioABBench), which plays songs in Music
#     to compare. OldTunes itself never sends Music a playback command, so a release build can't.
#     Because Debug reaches more of Music than a release build, check Music scripting on a
#     Bench build too (OLDTUNES_HARNESS=musicaccess, and the live checks): Release's entitlements
#     with the benches, which Release builds leave out (project.yml).
# Release builds, which ship and which the Mac App Store would review, sign with
# OldTunes.entitlements alone. XcodeGen runs this after every `xcodegen generate`
# (project.yml ▸ options ▸ postGenCommand).

set -euo pipefail
cd "${0:a:h}/.."
out=OldTunes/App/OldTunes-Debug.entitlements
cp OldTunes/App/OldTunes.entitlements "$out"
/usr/libexec/PlistBuddy \
  -c 'Add :com.apple.security.temporary-exception.files.absolute-path.read-write array' \
  -c 'Add :com.apple.security.temporary-exception.files.absolute-path.read-write:0 string /private/tmp/' \
  -c 'Add :com.apple.security.temporary-exception.files.home-relative-path.read-write array' \
  -c 'Add :com.apple.security.temporary-exception.files.home-relative-path.read-write:0 string /Library/Logs/OldTunes/' \
  -c 'Add :com.apple.security.temporary-exception.files.absolute-path.read-only array' \
  -c 'Add :com.apple.security.temporary-exception.files.absolute-path.read-only:0 string /opt/homebrew/' \
  -c 'Add :com.apple.security.scripting-targets:com.apple.Music:1 string com.apple.Music.playback' \
  "$out" >/dev/null
