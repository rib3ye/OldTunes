#!/bin/zsh
# Builds SelfCaptureProbe.app, with ToneService.xpc inside, into /private/tmp/self-capture-probe
# (main.swift says what it tests). `tools/self-capture-probe/build.sh --sandbox` signs both into
# the App Sandbox, like oldTunes; that also makes ~/Library/Containers/com.noahtsutsui.selfcaptureprobe.
# Signed ad hoc, so it has none of oldTunes's permissions. Plays only inaudible tones. Run it with:
#   open -n -W --stdout /private/tmp/self-capture-probe/probe.log --stderr /private/tmp/self-capture-probe/probe.log \
#     /private/tmp/self-capture-probe/SelfCaptureProbe.app --args --mode app
# then read the log's SUMMARY. It quits by itself after about 23 s (plus any --hold).
set -euo pipefail
here=${0:A:h}
out=/private/tmp/self-capture-probe
mkdir -p $out
app=$out/SelfCaptureProbe.app
xpc=$app/Contents/XPCServices/ToneService.xpc
sdk=$(xcrun --show-sdk-path)
rm -rf $app
mkdir -p $app/Contents/MacOS $xpc/Contents/MacOS

cat > $app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.noahtsutsui.selfcaptureprobe</string>
  <key>CFBundleName</key><string>SelfCaptureProbe</string>
  <key>CFBundleExecutable</key><string>SelfCaptureProbe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

cat > $xpc/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.noahtsutsui.selfcaptureprobe.tone</string>
  <key>CFBundleName</key><string>ToneService</string>
  <key>CFBundleExecutable</key><string>ToneService</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>XPCService</key><dict><key>ServiceType</key><string>Application</string></dict>
</dict></plist>
PLIST

flags=(-O -swift-version 5 -sdk $sdk -target arm64-apple-macos14.4)
xcrun swiftc $flags -o $xpc/Contents/MacOS/ToneService $here/service/main.swift $here/shared.swift
xcrun swiftc $flags -o $app/Contents/MacOS/SelfCaptureProbe $here/main.swift $here/shared.swift

if [[ ${1:-} == --sandbox ]]; then
  ent=$out/sandbox.entitlements
  cat > $ent <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST
  codesign --force --sign - --entitlements $ent $xpc
  codesign --force --sign - --entitlements $ent $app
else
  codesign --force --sign - $xpc
  codesign --force --sign - $app
fi
codesign -dv $app 2>&1 | grep -E "^Identifier"
echo "built $app"
