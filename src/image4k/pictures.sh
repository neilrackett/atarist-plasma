#!/bin/bash
# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Regenerate pictures/1..3 -- one conversion of the same photographs per
# palette engine -- using MD/4000's converter.
#
# The converted pictures are committed, so this is only needed to change
# them. The photographs are not: they're stock images, and MD/4000's
# assets/source/README.md says where to get them.
#
# Runs on the host rather than under stcmd: it needs Python 3 with numpy
# and Pillow.
#
# Usage:
#   src/image4k/pictures.sh [segments...]   # default: 1 2 3
#
# Environment:
#   MD4000       MD/4000 checkout (default: md-4000 alongside this repo)
#   MD4000_SRC   source photographs (default: $MD4000/assets/source)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
md4000="${MD4000:-$(dirname "$repo")/md-4000}"
src="${MD4000_SRC:-$md4000/assets/source}"
segs=("$@")
[ ${#segs[@]} -eq 0 ] && segs=(1 2 3)

# Three pictures rather than six: a 512 KB ST has about 400 KB of TPA to
# play with. Keep in step with pic_table in image4k.s and IMAGE4K_PICTURES
# in the Makefile.
pictures=(balloons braies spectrum)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for n in "${segs[@]}"; do
    echo "=== $n palette(s) per scanline ==="

    specs=()
    for p in "${pictures[@]}"; do specs+=("$p=$src/$p.jpg"); done
    python3 "$md4000/tools/img_to_md4000.py" --segments "$n" \
        --raw-dir "$tmp/raw$n" "${specs[@]}"

    mkdir -p "$here/pictures/$n"
    for p in "${pictures[@]}"; do
        cp "$tmp/raw$n/$p.scr" "$tmp/raw$n/$p.pal" "$here/pictures/$n/"
    done
done
