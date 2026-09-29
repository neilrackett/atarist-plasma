#!/usr/bin/env python3
# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later

"""Measure where each mid-row palette write takes effect, per entry.

With more than one palette a row, the mid-row MOVEM does not change the
palette at a clean edge: the shifter takes each register as the MOVEM
reaches it, so entry j changes over some cycles into the store, and a
cycle is a pixel. The converter has to know exactly where -- guess it and
every picture picks up a vertical seam.

So measure it. This paints row y entirely in palette index (y mod 16),
gives that index a different colour in each segment (red, then green,
then blue), runs it through Hatari, and reads the boundaries off each
row. Row y's boundaries ARE entry (y mod 16)'s change-over pixels.

Usage:
    src/image4k/tools/rastertest/calibrate.py [segments] [outdir] [machine]

Prints a SEGMENT_SWITCH_X entry ready to paste into ../convert.py.
"""

import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
W, H, ENTRIES = 320, 200, 16

# One per segment. Saturated primaries so classification is unambiguous.
SEGMENT_COLOURS = [(15, 0, 0), (0, 15, 0), (0, 0, 15)]

# Rows 0 and 1 never receive a mid-row write: the engine runs a row ahead
# of itself and its stabilised lock costs another (see raster_run2).
SKIP_ROWS = 2

PHASE = {2: 128, 3: 139}


def ste_word(r, g, b):
    return (
        (((r >> 1) & 7) << 8)
        | ((r & 1) << 11)
        | (((g >> 1) & 7) << 4)
        | ((g & 1) << 7)
        | (((b >> 1) & 7) << 0)
        | ((b & 1) << 3)
    )


def build_inputs(outdir, segments):
    """Row y is solid index (y mod 16), a different colour in each segment."""
    idx = np.repeat(np.arange(H, dtype=np.uint8)[:, None] % ENTRIES, W, axis=1)

    groups = idx.astype(np.uint16).reshape(H, W // 16, 16)
    shifts = np.arange(15, -1, -1, dtype=np.uint16)
    planes = np.zeros((H, W // 16, 4), dtype=np.uint16)
    for p in range(4):
        planes[:, :, p] = np.bitwise_or.reduce(
            ((groups >> p) & 1).astype(np.uint16) << shifts, axis=2
        )

    # Row-major segment tuples. Only the entry this row uses is coloured;
    # everything else stays black so a misread is obvious, not subtle.
    pal = np.zeros((H, segments, ENTRIES), dtype=">u2")
    for y in range(H):
        j = y % ENTRIES
        for seg in range(segments):
            pal[y, seg, j] = ste_word(*SEGMENT_COLOURS[seg])

    os.makedirs(outdir, exist_ok=True)
    scr = os.path.join(outdir, "calib.scr")
    pl = os.path.join(outdir, "calib.pal")
    planes.reshape(-1).astype(">u2").tofile(scr)
    pal.reshape(-1).tofile(pl)
    return scr, pl


def classify(shot):
    """Boolean mask per segment colour."""
    r, g, b = shot[:, :, 0], shot[:, :, 1], shot[:, :, 2]
    return [
        (r > 120) & (g < 90) & (b < 90),
        (g > 120) & (r < 90) & (b < 90),
        (b > 120) & (r < 90) & (g < 90),
    ]


def measure(shot_path, segments):
    """Locate the display area by its content, then read each boundary.

    Every row we drew shows segment 0's colour and every later segment's,
    and nothing outside the display area does -- so the longest run of
    such rows IS the display area. Scoring candidate crops by how many
    coloured pixels they hold is not enough: shifting vertically barely
    changes the count but rotates which row maps to which palette entry,
    which would silently corrupt the whole table.
    """
    shot = np.asarray(Image.open(shot_path).convert("RGB"), dtype=np.int16)
    masks = classify(shot)

    good = masks[0].any(axis=1)
    for seg in range(1, segments):
        good &= masks[seg].any(axis=1)

    best_len = best_start = run_start = run_len = 0
    for y, ok in enumerate(good):
        if ok:
            if run_len == 0:
                run_start = y
            run_len += 1
            if run_len > best_len:
                best_len, best_start = run_len, run_start
        else:
            run_len = 0

    want = 2 * (H - SKIP_ROWS)
    if best_len < want:
        sys.exit(f"display area not found (longest run {best_len}, need {want})")

    oy = best_start - 2 * SKIP_ROWS

    # Find the left edge on a row that does NOT use entry 0: the ST border
    # IS palette entry 0, so on rows where entry 0 is the coloured one the
    # border is coloured too and the first hit is the screenshot edge.
    probe = oy + 2 * (SKIP_ROWS + 1)
    ox = int(np.argmax(masks[0][probe].astype(np.uint8)))

    switch = {seg: {} for seg in range(1, segments)}
    for y in range(SKIP_ROWS, H):
        row = oy + 2 * y
        if not masks[0][row, ox : ox + 2 * W].any():
            continue
        for seg in range(1, segments):
            hit = np.nonzero(masks[seg][row, ox : ox + 2 * W])[0]
            if len(hit):
                switch[seg].setdefault(y % ENTRIES, []).append(int(hit[0]) // 2)
    return switch, (ox, oy)


def main():
    segments = int(sys.argv[1]) if len(sys.argv) > 1 else 2
    outdir = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(REPO, "obj", "rastertest", f"calib{segments}")
    )
    machine = sys.argv[3] if len(sys.argv) > 3 else "ste"
    if segments not in PHASE:
        sys.exit("segments must be 2 or 3 (one segment has nothing to measure)")

    scr, pal = build_inputs(outdir, segments)
    shots = os.path.join(outdir, "shots")
    phase = PHASE[segments]

    env = dict(os.environ)
    env.update(
        SEGMENTS=str(segments),
        PHASE_DEFS=f"-DPHASE_START={phase} -DPHASE_END={phase} -DPHASE_STEP=4",
        PHASE_START=str(phase),
        PHASE_STEP="4",
    )
    subprocess.run(
        [os.path.join(HERE, "run.sh"), scr, pal, shots, machine],
        cwd=REPO,
        env=env,
        check=True,
        stdout=subprocess.DEVNULL,
    )

    shot = os.path.join(shots, f"phase{phase:03d}.png")
    if not os.path.exists(shot):
        sys.exit(f"no screenshot at {shot}")
    switch, origin = measure(shot, segments)

    print(f"{segments} segments, phase {phase}, display area at {origin}\n")
    table = {}
    for seg in range(1, segments):
        print(f"  segment {seg}:")
        print(f"  {'entry':>7}  {'switch x':>9}  {'samples':>8}  {'spread':>6}")
        row = []
        for j in range(ENTRIES):
            xs = switch[seg].get(j, [])
            if not xs:
                print(f"  {j:7d}  {'(none)':>9}")
                row.append(None)
                continue
            vals, counts = np.unique(xs, return_counts=True)
            mode = int(vals[int(np.argmax(counts))])
            row.append(mode)
            print(
                f"  {j:7d}  {mode:9d}  {len(xs):8d}  "
                f"{int(vals.max() - vals.min()):6d}"
            )
        table[seg] = row
        if all(v is not None for v in row):
            steps = sorted({row[j + 1] - row[j] for j in range(ENTRIES - 1)})
            print(f"    step between entries: {steps}")
        print()

    if all(all(v is not None for v in r) for r in table.values()):
        print(f"    {segments}: (")
        for seg in range(1, segments):
            base = table[seg][0]
            if all(table[seg][j] == base + 4 * j for j in range(ENTRIES)):
                print(f"        tuple({base} + 4 * j for j in range(PALETTE_ENTRIES)),")
            else:
                print("        (" + ", ".join(str(v) for v in table[seg]) + "),")
        print("    ),")


if __name__ == "__main__":
    main()
