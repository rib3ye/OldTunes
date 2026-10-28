#!/bin/zsh
# Builds OldTunes for release and publishes it as a GitHub release: a Release build signed with
# Developer ID, notarized when a notarytool profile is set up, zipped, and uploaded with notes
# listing the pull requests merged since the last release.
#
# The Release workflow (.github/workflows/release.yml) runs this on Noah's Mac, through a
# self-hosted Actions runner, every time main moves on GitHub. It also runs by hand, on that Mac,
# from the repo root of a clean checkout of the commit to release:
#     tools/release.sh             # build, notarize, publish
#     tools/release.sh --dry-run   # the same, except that it publishes nothing
#
# The version is MARKETING_VERSION in project.yml and the build number is HEAD's commit count, so
# each commit on main gets its own release, tagged v<version>-<build>. A commit that already has
# its release is skipped.
#
# Needs Xcode 27, XcodeGen and gh (brew install xcodegen gh), gh logged in (or GH_TOKEN set), and
# the "Developer ID Application: Noah Tsutsui (92N52YB23U)" identity in the login keychain.
# Notarizing also needs a notarytool profile, made once on that Mac with
#     xcrun notarytool store-credentials OldTunes-notary --apple-id <Apple ID> --team-id 92N52YB23U
# (it asks for an app-specific password from account.apple.com). Without one the release is
# signed but not notarized, and its notes say how to open it anyway.

set -euo pipefail

dry_run=0
case "${1:-}" in
  "") ;;
  --dry-run) dry_run=1 ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 1 ;;
esac

cd "${0:a:h}/.."
team=92N52YB23U
identity="Developer ID Application: Noah Tsutsui ($team)"
notary_profile="${OLDTUNES_NOTARY_PROFILE:-OldTunes-notary}"
out=build/release

for tool in xcodegen xcodebuild gh ditto unzip; do
  command -v "$tool" >/dev/null || { echo "$0: $tool not found (brew install xcodegen gh)" >&2; exit 1; }
done
# A shallow clone counts too few commits, and the build number would go backwards.
if [[ "$(git rev-parse --is-shallow-repository)" == true ]]; then
  echo "$0: this clone is shallow; the build number needs full history (fetch-depth: 0)" >&2
  exit 1
fi
# A release must be exactly one commit. A dry run only warns.
if [[ -n "$(git status --porcelain)" ]]; then
  if (( ! dry_run )); then
    echo "$0: the working tree has changes; release from a clean checkout" >&2
    exit 1
  fi
  echo "warning: the working tree has changes, so this dry run is not exactly HEAD" >&2
fi
# A branch's commit count can equal a later main commit's, and that commit would then be skipped
# as already released. So only commits on GitHub's main get releases.
if (( ! dry_run )) && ! git merge-base --is-ancestor HEAD origin/main; then
  echo "$0: HEAD is not on origin/main; push main first, or release a commit that is on it" >&2
  exit 1
fi

sha=$(git rev-parse HEAD)
build=$(git rev-list --count HEAD)
version=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"$/\1/p' project.yml)
[[ -n "$version" ]] || { echo "$0: no MARKETING_VERSION in project.yml" >&2; exit 1; }
tag="v$version-$build"
title="OldTunes $version ($build)"
zip="$out/OldTunes-$version-$build.zip"

if (( ! dry_run )) && gh release view "$tag" >/dev/null 2>&1; then
  echo "$tag is already released; nothing to do"
  exit 0
fi

echo "building $title from $sha"
rm -rf "$out"
xcodegen generate --quiet
# Release, signed with Developer ID by hand (not Xcode's automatic Apple Development), with the
# secure timestamp and no get-task-allow that notarization requires. Archiving strips symbols.
xcodebuild archive -quiet \
  -project OldTunes.xcodeproj -scheme OldTunes -configuration Release \
  -derivedDataPath "$out/dd" -archivePath "$out/OldTunes.xcarchive" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" \
  OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  CURRENT_PROJECT_VERSION="$build"
app="$out/OldTunes.xcarchive/Products/Applications/OldTunes.app"

# Check what notarization and Gatekeeper will check: the app and each of SFBAudioEngine's
# embedded frameworks signed with Developer ID and timestamped, the app with hardened runtime.
codesign --verify --deep --strict "$app"
for code in "$app" "$app"/Contents/Frameworks/*.framework; do
  info=$(codesign -dvv "$code" 2>&1)
  if [[ "$info" != *"Authority=$identity"* || "$info" != *"TeamIdentifier=$team"* || "$info" != *"Timestamp="* ]]; then
    echo "$0: ${code:t} is not signed with a timestamped Developer ID signature:" >&2
    echo "$info" >&2
    exit 1
  fi
done
[[ "$(codesign -dvv "$app" 2>&1)" == *"(runtime)"* ]] || { echo "$0: the app lacks hardened runtime" >&2; exit 1; }
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null)
if [[ "$entitlements" == *get-task-allow* ]]; then
  echo "$0: the app has get-task-allow, which notarization refuses" >&2
  exit 1
fi
# Sandboxed, and with none of the test benches' extras that only Debug builds may carry
# (tools/debug-entitlements.sh): the sandbox exceptions, and Music's playback access group.
if [[ "$entitlements" != *"<key>com.apple.security.app-sandbox</key><true/>"* || "$entitlements" == *temporary-exception* ||
      "$entitlements" == *com.apple.Music.playback* ]]; then
  echo "$0: the app's entitlements are not the release set in OldTunes/App/OldTunes.entitlements:" >&2
  echo "$entitlements" >&2
  exit 1
fi
# The list of what macOS moves into the container the first time a sandboxed OldTunes opens. It
# only ever runs that once, so a release without it would leave people's settings behind.
migration="$app/Contents/Resources/container-migration.plist"
[[ -f "$migration" ]] && plutil -lint -s "$migration" ||
  { echo "$0: the app has no valid Contents/Resources/container-migration.plist" >&2; exit 1; }
plist="$app/Contents/Info.plist"
shown="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist") ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist"))"
[[ "$shown" == "$version ($build)" ]] || { echo "$0: the app says it is $shown, not $version ($build)" >&2; exit 1; }

# ditto keeps the bundle's symlinks and signatures intact; plain zip can break them. It must leave
# out extended attributes (the build stamps com.apple.provenance on every file): ditto stores them
# as ._ files, which Archive Utility folds back in but other unzip tools write into the bundle as
# real files. A ._ file in a framework breaks its seal, and Gatekeeper then says Apple "could not
# verify" the app, notarized or not.
zip_app() { rm -f "$zip"; ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$app" "$zip"; }
zip_app

notes="Built from $sha."
if xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1; then
  echo "notarizing; Apple usually takes a few minutes"
  result=$(xcrun notarytool submit "$zip" --keychain-profile "$notary_profile" --wait --output-format json)
  if [[ "$(print -r -- "$result" | plutil -extract status raw -o - -)" != Accepted ]]; then
    echo "$0: notarization failed: $result" >&2
    echo "Apple's reasons: xcrun notarytool log $(print -r -- "$result" | plutil -extract id raw -o - -) --keychain-profile $notary_profile" >&2
    exit 1
  fi
  xcrun stapler staple -q "$app"
  spctl --assess --type execute -v "$app"
  zip_app
  notes+=" Signed with Developer ID and notarized by Apple."
else
  echo "warning: no notarytool profile \"$notary_profile\", so this release is not notarized" >&2
  notes+=" Not notarized yet, so macOS refuses to open it the first time. Then open System Settings ▸ Privacy & Security and click Open Anyway."
fi

# Unpack the zip with plain unzip, the strictest of the tools people use, and check the signature
# again: what a download unpacks to must still verify, not only the app in the archive.
unpacked="$out/unzipped"
rm -rf "$unpacked"
unzip -q "$zip" -d "$unpacked"
codesign --verify --deep --strict "$unpacked/OldTunes.app" ||
  { echo "$0: the app in $zip fails its signature check once unzipped" >&2; exit 1; }

if (( dry_run )); then
  echo "dry run: would publish $tag (\"$title\") at $sha with $zip"
  exit 0
fi
gh release create "$tag" "$zip" --target "$sha" --title "$title" --notes "$notes" --generate-notes --latest
echo "published $(gh release view "$tag" --json url --jq .url)"
