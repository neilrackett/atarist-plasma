#!/usr/bin/env python3
# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later

"""Solve for where the mid-row palette bands actually landed.

score.py answers "does the emulator match the reference?". When it does
not, this answers the more useful question: "is the model right and only
the position wrong?" It slides every change-over band by the same delta
and reports which deltas render the picture with zero error.

A single zero-error delta means the engine is exact and only the absolute
position is out -- correct SEGMENT_SWITCH_X by that delta. No zero-error
delta at any offset means something is wrong with the model itself.

Usage:
    src/image4k/tools/rastertest/solve_offset.py <base.scr> <base.pal> <segments> <shots-dir>
"""

import glob
import os
import re
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from convert import SEGMENT_SWITCH_X  # noqa: E402

W, H, E = 320, 200, 16
SEARCH = 60
TOLERANCE = 24  # per-channel difference that counts as a real mismatch


def decode_ste(word):
    w = int(word)
    return (
        ((w >> 8) & 7) * 2 + ((w >> 11) & 1),
        ((w >> 4) & 7) * 2 + ((w >> 7) & 1),
        (w & 7) * 2 + ((w >> 3) & 1),
    )


def load(scr_path, pal_path, segments):
    # Low res is four interleaved 16-bit planes per 16 pixels, leftmost
    # pixel in bit 15 -- the inverse of to_st_planar in convert.py.
    planes = np.fromfile(scr_path, dtype=">u2").reshape(H, W // 16, 4)
    shifts = np.arange(15, -1, -1, dtype=np.uint16)
    idx = np.zeros((H, W // 16, 16), dtype=np.uint8)
    for p in range(4):
        idx |= (((planes[:, :, p, None] >> shifts) & 1) << p).astype(np.uint8)
    idx = idx.reshape(H, W)

    pal = np.fromfile(pal_path, dtype=">u2").reshape(H, segments, E)
    rgb = np.array(
        [[[decode_ste(pal[y, s, k]) for k in range(E)] for s in range(segments)]
         for y in range(H)],
        dtype=np.float64,
    ) * (255.0 / 15.0)
    return idx, rgb


def render(idx, rgb, segments, delta):
    """What the ST shows if every band is `delta` pixels from nominal."""
    seg = np.zeros((W, E), dtype=np.int32)
    xs = np.arange(W)[:, None]
    for switch in SEGMENT_SWITCH_X[segments]:
        seg += (xs >= (np.asarray(switch) + delta)[None, :]).astype(np.int32)
    # live[y, x] = rgb[y, seg[x, idx[y,x]], idx[y,x]]
    live_seg = np.take_along_axis(seg[None, :, :].repeat(H, 0), idx[:, :, None], axis=2)
    live_seg = live_seg[:, :, 0]
    ys = np.arange(H)[:, None].repeat(W, 1)
    return rgb[ys, live_seg, idx]


def main():
    if len(sys.argv) != 5:
        raise SystemExit(__doc__)
    scr, pal, segments, shots = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
    idx, rgb = load(scr, pal, segments)

    files = sorted(glob.glob(os.path.join(shots, "phase*.png")))
    if not files:
        raise SystemExit(f"no phase*.png in {shots}")

    print(f"{'phase':>6}  {'zero-error deltas':<28} {'best':>6} {'bad px':>8}")
    for f in files:
        phase = int(re.search(r"phase(\d+)", os.path.basename(f)).group(1))
        shot = np.asarray(Image.open(f).convert("RGB"), dtype=np.int16)
        crop = shot[58 : 58 + 400 : 2, 96 : 96 + 640 : 2]
        zeros, best = [], None
        for d in range(-SEARCH, SEARCH + 1):
            bad = int(
                (np.abs(render(idx, rgb, segments, d) - crop).max(axis=2) > TOLERANCE).sum()
            )
            if bad == 0:
                zeros.append(d)
            if best is None or bad < best[0]:
                best = (bad, d)
        shown = ", ".join(str(z) for z in zeros) if zeros else "(none)"
        print(f"{phase:6d}  {shown:<28} {best[1]:6d} {best[0]:8d}")


if __name__ == "__main__":
    main()
