#!/usr/bin/env python3
# Copyright (C) 2026 Neil Rackett
# SPDX-License-Identifier: GPL-3.0-or-later

"""Convert photographs into image4k per-scanline-palette Atari ST pictures.

An image4k picture is a normal 320x200 low-res ST screen (4 bitplanes,
16 colours) plus **one to three 16-colour palettes per scanline**. The
viewer re-programs all 16 shifter palette registers during every
horizontal border, so each row gets its own 16 colours out of the STE's
4096 (the ST's 512 -- see --depth).

With --segments 2 a SECOND palette is written across the middle of each
row, lifting it to 32 colours. That write is not a clean edge: the shifter
takes each palette register as the MOVEM reaches it, so entry j changes
over at pixel SEGMENT_SWITCH_X[j] and the 60 pixels in between run on a
mix of the two palettes. Those pixels are not wasted -- the mix is a
perfectly good 16-colour palette, it just isn't either of the two -- so
the quantiser models it exactly rather than avoiding it. --segments 3
does the same again with a third palette.

This tool does the expensive part offline so the ST only ever has to copy
bytes:

  1. crop to the display aspect and resize to 320x200
  2. fit a 16-colour palette to every scanline (k-means, seeded from
     the row above so colours stay stable down the picture)
  3. dither the picture against those per-row palettes
  4. write the raw ST screen (NAME.scr) and the palette table (NAME.pal)

Output per picture is 32000 B of screen + 6400 B of palette per segment.

Usage:
    src/image4k/convert.py photo.jpg -o src/image4k/pictures/1
    src/image4k/convert.py --segments 2 balloons=photo.jpg -o out --preview-dir out
"""

import argparse
import os
import sys
import time

import numpy as np
from PIL import Image, ImageEnhance, ImageFilter

SCREEN_W = 320
SCREEN_H = 200
PALETTE_ENTRIES = 16

# Perceptual channel weights for every colour distance in this file
# (palette fitting and dither matching alike). Plain RGB Euclidean
# over-weights blue and leaves skies banded; these are the classic
# 2:4:3 weights, applied as per-channel scale factors so ordinary
# Euclidean distance in the scaled space *is* the weighted distance.
CHANNEL_WEIGHTS = np.array([2.0, 4.0, 3.0])
CHANNEL_SCALE = np.sqrt(CHANNEL_WEIGHTS / CHANNEL_WEIGHTS.sum())


# --------------------------------------------------------------------
# Palette grids
# --------------------------------------------------------------------
# The ST shifter takes 3 bits per channel (512 colours). The STE widens
# that to 4 bits (4096) by adding a *low* bit at the TOP of each nibble,
# so a plain ST reading an STE palette word simply ignores bit 3 and
# sees the top-3-bit approximation of the same colour. One palette is
# therefore correct on both machines with no runtime detection -- the
# STE just places its 16 entries on a finer grid. (Same trick as
# md-mjpeg's quantizer; see PALETTE_STE_RGB there.)

GRID_MAX = {"ste": 15, "st": 7}


# --------------------------------------------------------------------
# Two-segment change-over
# --------------------------------------------------------------------
# Pixel at which each palette entry changes from segment A to segment B,
# MEASURED on an emulated STE by rastertest/calibrate.py rather than
# derived -- get this wrong and every picture picks up a vertical seam.
# MOVEM.L puts a register out every 8 cycles (two word writes of four)
# and a cycle is a pixel in low resolution, hence the even 4-pixel step.
# The absolute position is set by RASTER2_PAD_MID in ../raster.s, and it
# MOVES WITH THE PHASE: one step of phase is four pixels -- and NOT
# linearly, so recalibrate rather than extrapolate if either changes.
# Reproducible run to run (three separate Hatari runs at the default
# phase agree exactly), which is what the stop-stabilised lock in
# raster_lock buys and what makes this usable at all: without it the band
# wanders ~20 pixels a frame and shimmers.
# One entry per mid-row write: SEGMENT_SWITCH_X[n][w][j] is the pixel at
# which palette entry j changes over to segment w+1. Segment 0 is written
# in the horizontal border and is live from pixel 0, so it has no entry.
#
# Three segments saturate the line (444 of 512 cycles are MOVEM), which
# is why its two bands cannot be moved relative to each other -- see
# RASTER3_PAD_* in ../raster.s. They are always 148 pixels apart.
#
# These are measured with rastertest/calibrate.py and then corrected
# with rastertest/solve_offset.py, because the calibration samples a
# single frame and the beam lock is not yet stable enough for that to be
# the last word. solve_offset.py is the arbiter: it reports which uniform
# shift renders the picture with zero error.
SEGMENT_SWITCH_X = {
    1: (),
    2: (tuple(121 + 4 * j for j in range(PALETTE_ENTRIES)),),
    3: (
        tuple(57 + 4 * j for j in range(PALETTE_ENTRIES)),
        tuple(205 + 4 * j for j in range(PALETTE_ENTRIES)),
    ),
}


def segment_map(segments, width=SCREEN_W):
    """seg[x, j] = which segment's palette is live for entry j at pixel x."""
    seg = np.zeros((width, PALETTE_ENTRIES), dtype=np.int32)
    xs = np.arange(width)[:, None]
    for switch in SEGMENT_SWITCH_X[segments]:
        seg += (xs >= np.asarray(switch)[None, :]).astype(np.int32)
    return seg


def live_states(segments, width=SCREEN_W):
    """Collapse the per-pixel map into a handful of distinct palettes.

    Only the *set* of live segments matters, and it only changes at the
    switch pixels, so a row has at most 16 * (segments - 1) + 1 distinct
    states however wide it is. Returns (state_of_x, states[s, j]).
    """
    seg = segment_map(segments, width)
    states, state_of_x = np.unique(seg, axis=0, return_inverse=True)
    return state_of_x.astype(np.int32), states


def segment_spans(segments, width=SCREEN_W):
    """The stretch of row each segment's palette mainly governs.

    Split on the middle of each change-over band, so a palette is fitted
    to the pixels it actually decides rather than to the ones it shares.
    """
    if segments == 1:
        return [(0, width)]
    bounds = [0]
    for switch in SEGMENT_SWITCH_X[segments]:
        bounds.append((switch[0] + switch[-1] + 1) // 2)
    bounds.append(width)
    return list(zip(bounds[:-1], bounds[1:]))


def encode_palette_word(rgb4, depth):
    """Pack one 0..grid-per-channel colour into an ST/STE palette word."""
    r, g, b = (int(v) for v in rgb4)
    if depth == "st":
        return ((r & 7) << 8) | ((g & 7) << 4) | (b & 7)
    # STE: high 3 bits in the ST positions, extra LOW bit at the top.
    return (
        (((r >> 1) & 7) << 8)
        | ((r & 1) << 11)
        | (((g >> 1) & 7) << 4)
        | ((g & 1) << 7)
        | (((b >> 1) & 7) << 0)
        | ((b & 1) << 3)
    )


def grid_to_rgb888(levels, grid):
    """Expand 0..grid channel levels to full-range 0..255 floats."""
    return levels.astype(np.float64) * (255.0 / grid)


# --------------------------------------------------------------------
# Image preparation
# --------------------------------------------------------------------


def prepare_image(path, aspect, sharpen, saturation):
    """Load, centre-crop to `aspect`, resize to 320x200, sharpen."""
    img = Image.open(path).convert("RGB")
    src_w, src_h = img.size

    target_ar = aspect[0] / aspect[1]
    src_ar = src_w / src_h

    # Fill crop ("crop to fit"): keep the full width or the full height,
    # whichever leaves the picture covering the whole screen, and trim
    # the excess off the other axis symmetrically. Never letterboxes.
    if src_ar > target_ar:
        crop_w = int(round(src_h * target_ar))
        crop_h = src_h
    else:
        crop_w = src_w
        crop_h = int(round(src_w / target_ar))
    left = (src_w - crop_w) // 2
    top = (src_h - crop_h) // 2
    img = img.crop((left, top, left + crop_w, top + crop_h))

    img = img.resize((SCREEN_W, SCREEN_H), Image.LANCZOS)

    if saturation != 1.0:
        img = ImageEnhance.Color(img).enhance(saturation)
    if sharpen > 0.0:
        # Downscaling by 10-20x softens everything; a little unsharp
        # mask buys back detail that survives 16 colours per row.
        img = img.filter(
            ImageFilter.UnsharpMask(radius=1.2, percent=int(sharpen * 100), threshold=2)
        )

    return np.asarray(img, dtype=np.float64)


# --------------------------------------------------------------------
# Per-scanline palette fitting
# --------------------------------------------------------------------


def median_cut(pixels, k):
    """Plain median cut -- used only to seed the first row's k-means."""
    boxes = [pixels]
    while len(boxes) < k:
        # Split the box with the largest weighted channel spread.
        scored = [
            (np.ptp(b * CHANNEL_SCALE, axis=0).max() if len(b) > 1 else -1.0, i)
            for i, b in enumerate(boxes)
        ]
        spread, idx = max(scored)
        if spread <= 0:
            break
        box = boxes.pop(idx)
        axis = int(np.argmax(np.ptp(box * CHANNEL_SCALE, axis=0)))
        order = np.argsort(box[:, axis], kind="stable")
        box = box[order]
        half = len(box) // 2
        boxes.extend([box[:half], box[half:]])

    centres = [b.mean(axis=0) for b in boxes if len(b)]
    while len(centres) < k:  # degenerate (near-flat) images
        centres.append(centres[-1].copy())
    return np.array(centres[:k])


def kmeans_line(pixels, seed, iters):
    """Lloyd's algorithm for one scanline, seeded from the row above.

    Seeding from the previous row is what keeps the picture from
    shimmering: entry *k* stays near entry *k* of the row above, so the
    palette drifts smoothly down the image instead of being re-chosen
    independently (and arbitrarily) 200 times.
    """
    scaled_px = pixels * CHANNEL_SCALE
    centres = seed.copy()

    for _ in range(iters):
        scaled_ce = centres * CHANNEL_SCALE
        # (N, K) squared distances.
        d = ((scaled_px[:, None, :] - scaled_ce[None, :, :]) ** 2).sum(axis=2)
        labels = np.argmin(d, axis=1)

        for k in range(len(centres)):
            members = pixels[labels == k]
            if len(members):
                centres[k] = members.mean(axis=0)
            else:
                # Empty cluster: move it onto the worst-served pixel so
                # all 16 entries stay useful instead of collapsing.
                worst = int(np.argmax(d.min(axis=1)))
                centres[k] = pixels[worst]
                d[worst, :] = -1.0

    return centres


def fit_line_palettes(img, window, iters, grid, segments=1, verbose=False):
    """Fit the per-scanline palettes. Returns (200, segments, 16, 3) levels.

    With two segments each half of the row gets its own palette, fitted
    only to the pixels it governs, and each carries its own seed down the
    picture so the two evolve independently but both stay stable.
    """
    palettes = np.zeros((SCREEN_H, segments, PALETTE_ENTRIES, 3), dtype=np.int32)
    spans = segment_spans(segments)
    seeds = [None] * segments

    for y in range(SCREEN_H):
        lo = max(0, y - window)
        hi = min(SCREEN_H, y + window + 1)

        for seg, (x0, x1) in enumerate(spans):
            # Rows 0 and 1 are displayed entirely under segment A. The
            # engine is always a row ahead of itself, and its stabilised
            # lock costs a further row (see raster_lock), so neither gets
            # a segment-B write. Fit them across the full width and give
            # both slots the same palette.
            if segments > 1 and y <= 1:
                pixels = img[lo:hi].reshape(-1, 3)
            else:
                pixels = img[lo:hi, x0:x1].reshape(-1, 3)

            if seeds[seg] is None:
                seeds[seg] = median_cut(pixels, PALETTE_ENTRIES)

            centres = kmeans_line(pixels, seeds[seg], iters)
            seeds[seg] = centres  # carry to the next row

            # Snap to the hardware grid and sort by luminance so entry 0 is
            # the darkest. Index 0 is also the ST border colour, so a dark
            # entry 0 keeps the border from strobing as the palette changes
            # -- and with two segments it also lines the palettes up, since
            # entry j then means "the j-th darkest" in both, which makes
            # the change-over band far less jarring.
            levels = np.clip(np.rint(centres / 255.0 * grid), 0, grid).astype(np.int32)
            luma = (levels * CHANNEL_WEIGHTS).sum(axis=1)
            palettes[y, seg] = levels[np.argsort(luma, kind="stable")]

        if segments > 1 and y <= 1:
            palettes[y, 1:] = palettes[y, 0]

        if verbose and y % 50 == 0:
            print(f"      row {y:3d}/{SCREEN_H}", file=sys.stderr)

    return palettes


# --------------------------------------------------------------------
# Dithering
# --------------------------------------------------------------------

# Floyd-Steinberg weights, serpentine-aware (mirrored on right-to-left
# rows so the error does not develop a directional grain).
FS_RIGHT = 7.0 / 16.0
FS_DOWN_LEFT = 3.0 / 16.0
FS_DOWN = 5.0 / 16.0
FS_DOWN_RIGHT = 1.0 / 16.0


def live_palettes(palettes, grid):
    """Expand the fitted palettes into what is actually on screen.

    Returns (eff, region) where eff[y, r] is the 16 colours live at
    region r of row y, and region[x] says which region pixel x is in.
    With one segment there is a single state; with more, one for each
    entry that has changed over (see SEGMENT_SWITCH_X).
    """
    rgb = grid_to_rgb888(palettes, grid)  # (200, segments, 16, 3)
    segments = palettes.shape[1]
    if segments == 1:
        return rgb[:, 0][:, None, :, :], np.zeros(SCREEN_W, dtype=np.int32)
    region, states = live_states(segments)
    # eff[y, s, j] = the colour entry j actually holds in state s.
    eff = rgb[:, states, np.arange(PALETTE_ENTRIES)[None, :], :]
    return eff, region


def dither_image(img, palettes, grid, mode):
    """Map every pixel to an index in the palette live *at that pixel*.

    Error diffusion crossing into the next row is not a problem here even
    though that row has a different palette -- the error is a colour, and
    the next row's palette absorbs whatever of it it can. The same goes
    for crossing the two-segment change-over band.
    """
    eff, region = live_palettes(palettes, grid)
    scaled_eff = eff * CHANNEL_SCALE  # (200, R, 16, 3)
    indices = np.zeros((SCREEN_H, SCREEN_W), dtype=np.uint8)

    if mode == "none":
        for y in range(SCREEN_H):
            # (W, 16) -- each pixel against the palette live where it is.
            d = (
                (img[y][:, None, :] * CHANNEL_SCALE - scaled_eff[y][region]) ** 2
            ).sum(2)
            indices[y] = np.argmin(d, axis=1)
        return indices, eff, region

    if mode == "ordered":
        # 4x4 Bayer, scaled to roughly one palette step of amplitude.
        bayer = (
            np.array(
                [
                    [0, 8, 2, 10],
                    [12, 4, 14, 6],
                    [3, 11, 1, 9],
                    [15, 7, 13, 5],
                ],
                dtype=np.float64,
            )
            / 16.0
            - 0.5
        )
        amp = 255.0 / grid
        for y in range(SCREEN_H):
            bias = bayer[y % 4][np.arange(SCREEN_W) % 4] * amp
            row = np.clip(img[y] + bias[:, None], 0, 255)
            d = ((row[:, None, :] * CHANNEL_SCALE - scaled_eff[y][region]) ** 2).sum(2)
            indices[y] = np.argmin(d, axis=1)
        return indices, eff, region

    # Floyd-Steinberg, serpentine.
    work = img.copy()
    for y in range(SCREEN_H):
        row_scaled = scaled_eff[y]
        row_rgb = eff[y]
        left_to_right = (y % 2) == 0
        xs = range(SCREEN_W) if left_to_right else range(SCREEN_W - 1, -1, -1)
        step = 1 if left_to_right else -1

        for x in xs:
            old = np.clip(work[y, x], 0, 255)
            r = region[x]
            d = ((old * CHANNEL_SCALE - row_scaled[r]) ** 2).sum(axis=1)
            k = int(np.argmin(d))
            indices[y, x] = k
            err = old - row_rgb[r][k]

            nx = x + step
            if 0 <= nx < SCREEN_W:
                work[y, nx] += err * FS_RIGHT
            if y + 1 < SCREEN_H:
                if 0 <= x - step < SCREEN_W:
                    work[y + 1, x - step] += err * FS_DOWN_LEFT
                work[y + 1, x] += err * FS_DOWN
                if 0 <= nx < SCREEN_W:
                    work[y + 1, nx] += err * FS_DOWN_RIGHT

    return indices, eff, region


# --------------------------------------------------------------------
# Output
# --------------------------------------------------------------------


def to_st_planar(indices):
    """Convert the index map to a raw ST low-res screen (32000 bytes).

    Low res packs 16 pixels into four interleaved 16-bit planes:
    plane 0 word, plane 1 word, plane 2 word, plane 3 word, then the
    next 16 pixels. Bit 15 of each word is the leftmost pixel.
    """
    idx = indices.astype(np.uint16)
    groups = idx.reshape(SCREEN_H, SCREEN_W // 16, 16)
    # Bit position within the word, leftmost pixel = MSB.
    shifts = np.arange(15, -1, -1, dtype=np.uint16)
    planes = np.zeros((SCREEN_H, SCREEN_W // 16, 4), dtype=np.uint16)
    for p in range(4):
        bits = ((groups >> p) & 1).astype(np.uint16) << shifts
        planes[:, :, p] = np.bitwise_or.reduce(bits, axis=2)
    return planes.reshape(-1).astype(">u2").tobytes()


def render_preview(indices, eff, region):
    """Exactly what the ST will display, as an RGB array."""
    out = np.zeros((SCREEN_H, SCREEN_W, 3), dtype=np.uint8)
    for y in range(SCREEN_H):
        out[y] = eff[y][region, indices[y]].astype(np.uint8)
    return out


def file_name(name):
    """A filesystem- and assembler-friendly version of a picture name."""
    return "".join(ch if ch.isalnum() else "_" for ch in name).strip("_").lower()


# --------------------------------------------------------------------


def parse_aspect(text):
    if ":" in text:
        a, b = text.split(":", 1)
        return (float(a), float(b))
    return (float(text), 1.0)


def split_spec(spec):
    """Split an image argument into (name, path).

    Accepted forms:
        photo.jpg              -- name taken from the filename
        balloons=photo.jpg     -- explicit name
    """
    if "=" not in spec:
        return os.path.splitext(os.path.basename(spec))[0], spec
    name, path = spec.split("=", 1)
    return name, path


def convert(spec, args, grid):
    name, path = split_spec(spec)
    name = file_name(name)

    t0 = time.time()
    img = prepare_image(path, args.aspect, args.sharpen, args.saturation)
    palettes = fit_line_palettes(
        img, args.window, args.iters, grid, args.segments, args.verbose
    )
    indices, eff, region = dither_image(img, palettes, grid, args.dither)

    # Row-major, segments interleaved: row 0's A then its B, row 1's A...
    # which is exactly the order raster_run2 walks the table in.
    words = [
        encode_palette_word(palettes[y, seg, k], args.depth)
        for y in range(SCREEN_H)
        for seg in range(args.segments)
        for k in range(PALETTE_ENTRIES)
    ]

    distinct = len({tuple(c) for c in palettes.reshape(-1, 3)})

    os.makedirs(args.out, exist_ok=True)
    base = os.path.join(args.out, name)
    with open(base + ".scr", "wb") as fh:                 # raw ST low-res screen
        fh.write(to_st_planar(indices))
    np.array(words, dtype=">u2").tofile(base + ".pal")    # 200 x segments x 16 words

    if args.preview_dir:
        os.makedirs(args.preview_dir, exist_ok=True)
        preview = render_preview(indices, eff, region)
        out = Image.fromarray(preview)
        if args.preview_scale != 1:
            out = out.resize(
                (SCREEN_W * args.preview_scale, SCREEN_H * args.preview_scale),
                Image.NEAREST,
            )
        out.save(os.path.join(args.preview_dir, f"{name}.png"))

    print(
        f"  {os.path.basename(path):52s} -> {name + '.scr/.pal':28s} "
        f"{distinct:4d} distinct colours  {time.time() - t0:5.1f}s"
    )


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument(
        "images",
        nargs="+",
        metavar="[NAME=]IMAGE",
        help="source image, optionally prefixed with the name to give its "
        "output files (default: the image's own file name)",
    )
    ap.add_argument(
        "-o", "--out", required=True, help="directory for the .scr/.pal output"
    )
    ap.add_argument(
        "--aspect",
        type=parse_aspect,
        default="4:3",
        help="source crop aspect. 4:3 (default) matches what an ST actually "
        "displays, so circles stay round on real hardware; 16:10 crops to "
        "the 320x200 pixel grid instead.",
    )
    ap.add_argument("--depth", choices=("ste", "st"), default="ste")
    ap.add_argument(
        "--segments",
        type=int,
        choices=(1, 2, 3),
        default=1,
        help="palettes per scanline. 1 (default) writes one in the "
        "horizontal border; 2 and 3 add further palettes across the row, "
        "for up to 32 and 48 colours a row, at 2x and 3x the palette-table "
        "size. The modes produce DIFFERENT pixel data and are not "
        "interchangeable.",
    )
    ap.add_argument("--dither", choices=("fs", "ordered", "none"), default="fs")
    ap.add_argument(
        "--window",
        type=int,
        default=1,
        help="rows either side of each scanline included in its palette fit "
        "(default 1 = a 3-row window; larger is smoother but flatter)",
    )
    ap.add_argument("--iters", type=int, default=8, help="k-means iterations per row")
    ap.add_argument("--sharpen", type=float, default=0.8, help="unsharp amount, 0 = off")
    ap.add_argument("--saturation", type=float, default=1.08)
    ap.add_argument("--preview-dir", help="write exact-output PNG previews here")
    ap.add_argument("--preview-scale", type=int, default=1)
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if isinstance(args.aspect, str):
        args.aspect = parse_aspect(args.aspect)

    grid = GRID_MAX[args.depth]
    print(
        f"image4k converter: {len(args.images)} image(s), {args.depth.upper()} "
        f"palette grid, {args.dither} dither, "
        f"{args.aspect[0]:g}:{args.aspect[1]:g} crop, "
        f"{args.segments} palette{'s' if args.segments > 1 else ''}/row"
    )

    for spec in args.images:
        convert(spec, args, grid)


if __name__ == "__main__":
    main()
