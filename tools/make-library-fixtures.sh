#!/bin/zsh
# Makes the audio files the library bench (OLDTUNES_HARNESS=library) adds as a folder: short
# clips of made-up speech from `say`, converted to each format and tagged with invented names.
# Nothing here comes from a real music library.
#
# Run on a Mac, from the repo root, before the first library run in a new evidence folder:
#     tools/make-library-fixtures.sh <evidence folder>
# The evidence folder is the one holding the bench's index (OLDTUNES_DB_PATH), so its path
# contains /scratchpad/evidence/library/ or /scratchpad/fixes/library/. The script writes only
# <evidence folder>/fixtures and <evidence folder>/fixtures-src, replacing both.
# Needs ffmpeg, flac and lame: brew install ffmpeg flac lame

set -euo pipefail

if (( $# != 1 )) || [[ -z "$1" ]]; then
  echo "usage: $0 <evidence folder>  (the folder the bench's index.sqlite goes in)" >&2
  exit 1
fi
V="${1:a}"
if [[ "$V" == *.sqlite ]]; then
  echo "$0: pass the folder that holds the index, not the index file" >&2
  exit 1
fi
# The bench refuses any other index path, so fixtures anywhere else would never be read.
if [[ "$V/" != */scratchpad/evidence/library/* && "$V/" != */scratchpad/fixes/library/* ]]; then
  echo "$0: $V is not inside scratchpad/evidence/library/ or scratchpad/fixes/library/; nothing written" >&2
  exit 1
fi
for tool in say afconvert ffmpeg flac lame; do
  command -v "$tool" >/dev/null || { echo "$0: $tool not found (brew install ffmpeg flac lame)" >&2; exit 1; }
done

S="$V/fixtures-src"; F="$V/fixtures"
rm -rf "$F" "$S"
mkdir -p "$F/sub" "$S"

# The bench's PCM bit-rate check expects say's usual output, 22,050 Hz 16-bit mono AIFC. Pinned
# in case another Mac's voice defaults to something else (on this one it is byte-identical).
speak() { say --file-format=AIFC --data-format=BEI16@22050 --channels=1 -o "$1" "$2"; }

speak "$S/tagged-source.aiff" "harness tagged source song"
speak "$F/harness-one.aiff" "test one"
# Accented name in NFC (é as the bytes C3 A9), for the Music-owned-path normalization check.
speak "$F/caf"$'\xc3\xa9'"-nfc.aiff" "cafe"
speak "$S/two.aiff" "test two"
speak "$S/three.aiff" "test three"
speak "$S/four.aiff" "test four"
speak "$F/sub/harness-nested-five.aiff" "nested five"
speak "$S/six.aiff" "test six mp3"
afconvert -f m4af -d aac "$S/two.aiff" "$F/harness-two.m4a"
afconvert -f WAVE -d LEI16 "$S/three.aiff" "$F/harness-three.wav"
afconvert -f caff -d LEI16 "$S/four.aiff" "$F/harness-four.caf"

# Files the folder scan must skip: protected and audiobook extensions, non-audio, hidden.
cp "$F/harness-two.m4a" "$F/protected-skip.m4p"
cp "$F/harness-two.m4a" "$F/audiobook-skip.m4b"
echo "not audio" > "$F/notes.txt"
mkdir -p "$F/.hidden"; cp "$F/harness-one.aiff" "$F/.hidden/hidden-skip.aiff"
cp "$F/harness-one.aiff" "$F/.dotfile-skip.aiff"

# ID3v2.3 MP3: TYER year, TRCK n/m, TPOS n/m, numeric "(17)" genre, TCMP compilation.
ffmpeg -loglevel error -y -i "$S/six.aiff" -c:a libmp3lame -b:a 128k -id3v2_version 3 \
  -metadata title="Verify MP3 Song" -metadata artist="MP3 Artist" -metadata album="MP3 Album" \
  -metadata album_artist="MP3 Album Artist" -metadata composer="MP3 Composer" -metadata genre="(17)" \
  -metadata date="1997" -metadata track="4/10" -metadata disc="2/3" -metadata compilation=1 \
  -metadata comment="mp3 comment" "$F/verify-id3v23.mp3"
# ID3v2.4 MP3: TDRC recording time.
ffmpeg -loglevel error -y -i "$S/six.aiff" -c:a libmp3lame -b:a 128k -id3v2_version 4 \
  -metadata title="Verify MP3 v24" -metadata artist="MP3v24 Artist" -metadata date="2001-05-02" \
  -metadata track="9" -metadata genre="Electronic" "$F/verify-id3v24.mp3"
afconvert -f WAVE -d LEI16 "$S/six.aiff" "$S/six.wav"
# FLAC with Vorbis comments. flac warns that it skips six.wav's 'FLLR' chunk (afconvert's
# padding); that warning is expected.
flac --silent -f -o "$F/verify.flac" -T TITLE="Verify FLAC Song" -T ARTIST="FLAC Artist" -T ALBUM="FLAC Album" \
  -T DATE=2010 -T TRACKNUMBER=5 -T TRACKTOTAL=11 -T GENRE="Ambient" "$S/six.wav"
# ALAC in MP4 with iTunes atoms.
ffmpeg -loglevel error -y -i "$S/six.aiff" -c:a alac -metadata title="Verify ALAC Song" -metadata artist="ALAC Artist" \
  -metadata album="ALAC Album" -metadata date="2012" -metadata track="2/8" "$F/verify-alac.m4a"
# ID3v1-only MP3 (no ID3v2 header): a 128-byte TAG trailer, written by lame.
lame --quiet --id3v1-only --tt "Verify ID3v1 Song" --ta "V1 Artist" --tl "V1 Album" --ty 1985 --tn 6 --tg Jazz \
  "$S/six.wav" "$F/verify-id3v1.mp3"
# FLAC with lower-case field names, a pair-form disc number, TOTALTRACKS, and the rest of the fields.
flac --silent -f -o "$F/verify-vorbis-extra.flac" -T title="Vorbis Extra" -T artist="VX Artist" -T albumartist="VX Album Artist" \
  -T album="VX Album" -T composer="VX Composer" -T genre="Folk" -T date=1972-03-04 -T tracknumber=3 -T totaltracks=7 \
  -T discnumber=2/4 -T compilation=1 -T comment="vx comment" -T bpm=99 -T artistsort="Artist, VX" "$S/six.wav"

echo "$(find "$F" "$S" -type f | wc -l | tr -d ' ') files in $F and $S"
echo "Run the bench with OLDTUNES_DB_PATH=$V/index.sqlite"
