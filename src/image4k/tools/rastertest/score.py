#!/usr/bin/env python3
# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later

"""Score Hatari screenshots of the raster harness against the expected picture.

The converter knows exactly what the ST *should* display (the preview PNG
it renders is pixel-for-pixel what the shifter is being asked to produce).
This compares each phase's emulator screenshot with that reference and
reports the RMS error, so picking the phase where the palette writes land
cleanly in the border is a measurement rather than a judgement call.

Usage:
    src/image4k/tools/rastertest/score.py <reference.png> <sweep-dir>
"""

import glob
import os
import re
import sys

import numpy as np
from PIL import Image


def load_reference(path):
    img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    if img.shape[:2] != (200, 320):
        raise SystemExit(f"reference must be 320x200, got {img.shape[1]}x{img.shape[0]}")
    return img


def find_offset(shot, ref):
    """Locate the 320x200 display area inside Hatari's bordered screenshot.

    Hatari renders the ST screen at 2x with the overscan borders around it,
    so the picture is a 640x400 nearest-neighbour blow-up at some offset.
    Search for the offset with the lowest error instead of hard-coding
    Hatari's border metrics, which vary with machine and border settings.
    """
    h, w = shot.shape[:2]
    best = None
    for oy in range(0, h - 400 + 1, 1):
        for ox in range(0, w - 640 + 1, 2):
            crop = shot[oy : oy + 400 : 2, ox : ox + 640 : 2]
            err = np.abs(crop - ref).mean()
            if best is None or err < best[0]:
                best = (err, ox, oy)
    return best


def rms(a, b):
    return float(np.sqrt(((a - b) ** 2).mean()))


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    ref = load_reference(sys.argv[1])
    shots = sorted(glob.glob(os.path.join(sys.argv[2], "phase*.png")))
    if not shots:
        raise SystemExit(f"no phase*.png in {sys.argv[2]}")

    # Lock the crop once, on the shot that aligns best overall.
    first = np.asarray(Image.open(shots[len(shots) // 2]).convert("RGB"), dtype=np.float64)
    err, ox, oy = find_offset(first, ref)
    print(f"display area found at ({ox}, {oy}) in {first.shape[1]}x{first.shape[0]}\n")

    results = []
    for path in shots:
        shot = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
        crop = shot[oy : oy + 400 : 2, ox : ox + 640 : 2]
        phase = int(re.search(r"phase(\d+)", os.path.basename(path)).group(1))
        # Fraction of rows that differ from the reference at all: a palette
        # write landing late corrupts whole rows, so this is the sharpest
        # signal of a mistimed phase.
        bad_rows = int((np.abs(crop - ref).max(axis=(1, 2)) > 24).sum())
        results.append((phase, rms(crop, ref), bad_rows))

    print(f"{'phase':>6}  {'RMS':>8}  {'bad rows':>9}")
    for phase, e, bad in results:
        mark = ""
        print(f"{phase:6d}  {e:8.2f}  {bad:9d}{mark}")

    best = min(results, key=lambda r: (r[2], r[1]))
    print(f"\nbest phase: {best[0]}  (RMS {best[1]:.2f}, {best[2]} bad rows)")
    clean = [r[0] for r in results if r[2] == 0]
    if clean:
        print(f"clean phases: {clean[0]}..{clean[-1]}")


if __name__ == "__main__":
    main()
