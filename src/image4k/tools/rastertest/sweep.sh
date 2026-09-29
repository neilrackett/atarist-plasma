#!/bin/bash
# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Validate the raster engine in Hatari: convert a photograph, sweep the
# phase with the harness, and score each phase's screenshot against what
# the converter says the ST should be showing. A good result is RMS 0.00
# with 0 bad rows. Any change to raster.s should be re-run through this.
#
# Usage:
#   src/image4k/tools/rastertest/sweep.sh [picture] [machine]
#
#   picture   a photograph in photos/, without the .jpg (default: balloons)
#   machine   ste (default) or st
#
# Environment:
#   SEGMENTS  palettes per row (default: 1). The harness sweeps phases for
#             the one-palette engine; pass PHASE_DEFS for the others.
#   PHOTOS    source photographs (default: src/image4k/photos)
#   ...plus anything run.sh takes.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
image4k="$(cd "$here/../.." && pwd)"
repo="$(cd "$image4k/../.." && pwd)"
photos="${PHOTOS:-$image4k/photos}"
picture="${1:-balloons}"
machine="${2:-ste}"
work="$repo/obj/rastertest/sweep"

python3 "$here/../convert.py" --segments "${SEGMENTS:-1}" \
    -o "$work" --preview-dir "$work" "$picture=$photos/$picture.jpg"
"$here/run.sh" "$work/$picture.scr" "$work/$picture.pal" "$work/shots" "$machine"
python3 "$here/score.py" "$work/$picture.png" "$work/shots"
