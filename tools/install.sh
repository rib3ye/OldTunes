#!/bin/zsh
# Installs a release build of OldTunes as /Applications/OldTunes.app, in place of the copy there.
# tools/release.sh runs it on Noah's Mac after each release, with the app it just published, so the
# OldTunes he opens is always the newest release. It also runs by hand, from the repo root:
#     tools/install.sh                        # the last build of tools/release.sh
#     tools/install.sh path/to/OldTunes.app
# It installs nothing when /Applications already has that build or a newer one; --force installs
# it anyway.
#
# An open OldTunes is never replaced: it would go on running the old build but load the new one's
# files from then on, and its code signature would stop matching what is on disk. Instead the build
# waits in ~/Library/Application Support/com.noahtsutsui.oldtunes.install, and a launchd job checks
# every minute and installs it once OldTunes has quit. The job lasts until logout, so a restart
# drops a waiting build; the next release brings it.

set -euo pipefail

dest=/Applications/OldTunes.app
team=92N52YB23U
label=com.noahtsutsui.oldtunes.install
queue="$HOME/Library/Application Support/$label"
script=${0:a}

force=0 pending=0 app=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --pending) pending=1 ;; # how the launchd job runs it
    -*) echo "usage: $0 [--force] [OldTunes.app]" >&2; exit 1 ;;
    *) app=$arg ;;
  esac
done

build_of() { plutil -extract CFBundleVersion raw -o - "$1/Contents/Info.plist" 2>/dev/null || echo 0; }
is_open() { pgrep -qf "^$dest/Contents/MacOS/"; }
# Deletes the waiting build and ends the launchd job. When the job runs it, this ends the script.
drop_queue() {
  rm -rf "$queue"
  launchctl bootout "gui/$UID/$label" 2>/dev/null || true
}

if (( pending )); then
  is_open && exit 0 # launchd runs this again in a minute
  echo "$(date): OldTunes has quit; installing the build that was waiting"
  # Installed or not, this was the job's one try: a failure would only repeat every minute.
  trap drop_queue EXIT
  app="$queue/OldTunes.app"
fi
app=${app:-${script:h:h}/build/release/unzipped/OldTunes.app}

info=$(codesign -dvv "$app" 2>&1) || true
if ! codesign --verify --deep --strict "$app" ||
    [[ "$info" != *"Identifier=com.noahtsutsui.oldtunes"* || "$info" != *"Authority=Developer ID Application: "*"($team)"* ]]; then
  echo "$0: $app is not OldTunes signed with Developer ID" >&2
  exit 1
fi
build=$(build_of "$app")
installed=$(build_of "$dest")
if (( ! force && installed >= build )); then
  echo "/Applications already has OldTunes build $installed, so build $build is not installed"
  exit 0
fi

if (( ! pending )) && is_open; then
  # A copy of this script runs the job: by the time OldTunes quits, this checkout may have changed.
  drop_queue
  mkdir -p "$queue"
  ditto "$app" "$queue/OldTunes.app"
  cp "$script" "$queue/install.sh"
  cat >"$queue/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$label</string>
	<key>ProgramArguments</key>
	<array><string>/bin/zsh</string><string>$queue/install.sh</string><string>--pending</string></array>
	<key>RunAtLoad</key><true/>
	<key>StartInterval</key><integer>60</integer>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/$label.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/$label.log</string>
</dict>
</plist>
EOF
  launchctl bootstrap "gui/$UID" "$queue/$label.plist"
  echo "OldTunes is open, so build $build will be installed in /Applications once it quits"
  exit 0
fi

# Copy the app in beside the old one, then swap the two by renaming, so /Applications never holds
# half an app. A copy left by a run that was cut short goes first.
new="${dest:h}/.OldTunes-new" old="${dest:h}/.OldTunes-old"
rm -rf "$new" "$old"
ditto "$app" "$new"
codesign --verify --deep --strict "$new"
[[ -e "$dest" ]] && mv "$dest" "$old"
mv "$new" "$dest" || { [[ -e "$old" ]] && mv "$old" "$dest"; exit 1; }
rm -rf "$old"
echo "installed OldTunes $(plutil -extract CFBundleShortVersionString raw -o - "$dest/Contents/Info.plist") ($build) in /Applications"
# A build still waiting for OldTunes to quit is older than this one.
if (( ! pending )) && [[ -d "$queue" ]]; then drop_queue; fi
