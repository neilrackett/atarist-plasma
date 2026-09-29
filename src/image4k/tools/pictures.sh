#!/bin/bash
# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regenerate pictures/1..3 -- one conversion of the same photographs per
# palette engine -- from the photographs in photos/.
#
# The converted pictures are committed, so this is only needed to change
# them. The photographs are not: photos/README.md says where to get them.
#
# Runs on the host rather than under stcmd: it needs Python 3 with numpy
# and Pillow.
#
# Usage:
#   src/image4k/tools/pictures.sh [segments...]   # default: 1 2 3
#
# Environment:
#   PHOTOS   source photographs (default: src/image4k/photos)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
image4k="$(dirname "$here")"
photos="${PHOTOS:-$image4k/photos}"
segs=("$@")
[ ${#segs[@]} -eq 0 ] && segs=(1 2 3)

# Three pictures: at three palettes a row that's a ~156 KB .TOS, and a
# 512 KB ST has about 400 KB of TPA to play with. Keep in step with
# pic_table in image4k.s and IMAGE4K_PICTURES in the Makefile.
pictures=(balloons braies spectrum)

for n in "${segs[@]}"; do
    echo "=== $n palette(s) per scanline ==="

    specs=()
    for p in "${pictures[@]}"; do specs+=("$p=$photos/$p.jpg"); done
    python3 "$here/convert.py" --segments "$n" \
        -o "$image4k/pictures/$n" "${specs[@]}"
done
