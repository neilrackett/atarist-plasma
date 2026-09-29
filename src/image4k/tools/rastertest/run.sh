#!/bin/bash
# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build the image4k raster harness and run it under Hatari, collecting a
# screenshot per phase value. Hatari emulates the shifter cycle by cycle
# (including mid-line palette writes), so this validates the beam-locked
# timing in src/image4k/raster.s without real hardware.
#
# Usage:
#   src/image4k/tools/rastertest/run.sh <picture.scr> <picture.pal> [outdir] [machine]
#
# <picture.scr>/<picture.pal> come from:
#   src/image4k/tools/convert.py photo.jpg -o <dir>
#
# Environment:
#   SEGMENTS     palettes per row to build the harness for (default: 1)
#   PHASE_DEFS   extra vasm -D options, e.g. to override PHASE_START/END/STEP
#   TOS_ROM      path to a TOS ROM image (default: search a few known spots)
#   HATARI       path to the Hatari binary

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../../.." && pwd)"
build="$repo/obj/rastertest"

scr="${1:?usage: run.sh <picture.scr> <picture.pal> [outdir] [machine]}"
pal="${2:?usage: run.sh <picture.scr> <picture.pal> [outdir] [machine]}"
out="${3:-$build/shots}"
machine="${4:-ste}"

HATARI="${HATARI:-/Applications/Hatari.app/Contents/MacOS/hatari}"
if [ ! -x "$HATARI" ]; then
    HATARI="$(command -v hatari || true)"
fi
[ -x "$HATARI" ] || { echo "ERROR: Hatari not found (set HATARI=...)"; exit 1; }

if [ -z "${TOS_ROM:-}" ]; then
    for cand in \
        "$HOME/Projects/__OS/atarist-highwire/tmp/roms/TOS 2.06 - UK - Original.IMG" \
        "$HOME/Projects/__OS/pico-compad/build/tos/tos206.IMG" \
        "$HOME/Projects/__OS/pico-compad/build/tos/etos256uk.img"; do
        [ -f "$cand" ] && { TOS_ROM="$cand"; break; }
    done
fi
[ -f "${TOS_ROM:-}" ] || { echo "ERROR: no TOS ROM (set TOS_ROM=...)"; exit 1; }

mkdir -p "$build"
cp "$scr" "$build/picture.scr"
cp "$pal" "$build/picture.pal"

echo "Assembling raster harness ($(basename "$scr"))..."
# stcmd mangles quoted compound commands, so each tool runs on its own.
( cd "$repo" && STCMD_NO_TTY=1 ST_WORKING_FOLDER="$repo" stcmd \
    vasm -Faout -quiet -x -m68000 -spaces -devpac \
         -DSEGMENTS=${SEGMENTS:-1} ${PHASE_DEFS:-} \
         -I src/image4k -I obj/rastertest \
         src/image4k/tools/rastertest/rastertest.s \
         -o obj/rastertest/rastertest.o >/dev/null )
( cd "$repo" && STCMD_NO_TTY=1 ST_WORKING_FOLDER="$repo" stcmd \
    vlink -bataritos -o obj/rastertest/RASTER.TOS \
          obj/rastertest/rastertest.o >/dev/null )

hd="$build/hd"
rm -rf "$hd" "$out"
mkdir -p "$hd" "$out"
cp "$build/RASTER.TOS" "$hd/"

echo "Running Hatari (machine=$machine, TOS=$(basename "$TOS_ROM"))..."
"$HATARI" \
    --machine "$machine" --tos "$TOS_ROM" \
    --harddrive "$hd" --auto 'C:\RASTER.TOS' \
    --bios-intercept on \
    --screenshot-dir "$out" --screenshot-format png \
    --fast-boot on --sound off --confirm-quit off --fast-forward on -w \
    > "$build/hatari.log" 2>&1 || true

count=$(ls "$out"/grab*.png 2>/dev/null | wc -l | tr -d ' ')
echo "Captured $count screenshot(s) in $out"
[ "$count" -gt 0 ] || { tail -20 "$build/hatari.log"; exit 1; }

# Name them by the phase they were taken at (see PHASE_* in rastertest.s).
start="${PHASE_START:-$(awk '/^PHASE_START  */ {print $3; exit}' "$here/rastertest.s")}"
step="${PHASE_STEP:-$(awk '/^PHASE_STEP  */ {print $3; exit}' "$here/rastertest.s")}"
i=0
for f in $(ls "$out"/grab*.png | sort); do
    mv "$f" "$out/phase$(printf '%03d' $((start + i * step))).png"
    i=$((i + 1))
done
ls "$out"
