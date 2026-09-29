# image4k

Plain `.TOS` picture viewers for the Atari ST/STE that give every scanline
its own palette. No hard disk needed: the pictures are baked in.

## The builds

```sh
stcmd make                     # everything, including all three
stcmd make dist/IMAGE4K1.TOS   # just one
```

| | palettes per row | colours per row | per picture |
| --- | --- | --- | --- |
| `dist/IMAGE4K1.TOS` | 1 | 16 | 3,200 |
| `dist/IMAGE4K2.TOS` | 2 | 32 | 6,400 |
| `dist/IMAGE4K3.TOS` | 3 | 48 | 9,600 |

Measured on the bundled pictures, distinct colours actually used:

| picture | 1 palette | 2 palettes | 3 palettes |
| --- | --- | --- | --- |
| Spectrum | 866 | 1,566 | **1,825** |
| Balloons | 555 | 735 | 850 |
| Lago di Braies | 423 | 568 | 641 |

**48 colours a row is the ceiling.** A fourth palette needs 608 cycles of
`MOVEM` in a 512-cycle scanline. That it's the same number Spectrum 512
reached is not a coincidence.

## Keys

| | |
| --- | --- |
| Space / Return | next picture |
| ← / → | nudge the beam phase |
| Esc | restore the desktop and quit |

## Status

**`IMAGE4K1.TOS` is the solid one.** Under Hatari it renders the picture
exactly (RMS 0.00 against the converter's reference) on both ST and STE.

`IMAGE4K2` and `IMAGE4K3` are experimental and will show scattered colour
artefacts. The engines themselves are exact: `tools/rastertest/solve_offset.py`
shows the emulator reproducing the reference with *zero* error at every
phase, once you know where the mid-row change-over landed. The problem is
that it doesn't land in the same place twice: the beam lock only resolves
the start of the display to within a poll iteration, so the bands wander
by up to ~20 pixels between runs, while the picture data is dithered
against one fixed assumption.

One palette a row is immune, because its write only has to land somewhere
in a 130-cycle border. Two and three are not, because their writes land
*on the picture*.

**This is what these builds are for.** A `.TOS` you can run on a real ST
in a minute is a far better instrument than an emulator for settling
whether that wander is a real hardware property or an artefact of
Hatari's `stop` timing. If ← / → finds a phase where the artefacts clean
up on real hardware — and whether that phase stays put across resets —
that's the answer.

## Requirements

Colour monitor, low resolution, PAL. 512 KB is enough (the largest build
is ~156 KB plus a 32 KB screen). Built with `vasm`/`vlink` via
[atarist-toolkit-docker](https://github.com/sidecartridge/atarist-toolkit-docker).

## Source

- `image4k.s`: the viewer.
- `raster.s`: the per-scanline palette engine. The Hatari harness
  assembles the same file, so what's tested is what runs.
- `pictures/1`, `pictures/2`, `pictures/3`: the converted pictures, one
  set per engine, because the pixels are dithered against the palettes.
- `photos/`: where the source photographs go. They aren't committed; see
  [photos/README.md](photos/README.md).
- `tools/`: everything used to make and check the pictures, below.

## Tools

These run on the host rather than under `stcmd`, and need Python 3 with
numpy and Pillow. The Hatari ones also need
[Hatari](https://www.hatari-emulator.org) and a TOS ROM image (set
`HATARI` and `TOS_ROM` if they aren't found).

**Pictures.** `tools/convert.py` turns a photograph into a `.scr` screen
and `.pal` palette table for 1, 2 or 3 palettes a row: per-row k-means,
Floyd-Steinberg dithering against the palette that's live at each pixel,
and an STE palette encoding that degrades gracefully on a plain ST.
`tools/pictures.sh` runs it over the photographs in `photos/` to
regenerate `pictures/`:

```sh
src/image4k/tools/pictures.sh        # all three engines
src/image4k/tools/pictures.sh 1      # just one
```

**Validation.** `tools/rastertest/` builds a harness `.TOS` that
includes `raster.s` verbatim, sweeps the phase under Hatari, and scores
each screenshot against the exact image the converter says the ST should
show. A good result is RMS 0.00 with 0 bad rows; re-run it after any
change to `raster.s`:

```sh
src/image4k/tools/rastertest/sweep.sh balloons       # STE
src/image4k/tools/rastertest/sweep.sh balloons st    # plain ST
```

**Calibration.** With more than one palette a row, the converter has to
know the pixel where each palette entry changes over (`SEGMENT_SWITCH_X`
in `convert.py`). `tools/rastertest/calibrate.py 2` (or `3`) measures it
under Hatari, and `tools/rastertest/solve_offset.py` reports how far a
sweep's bands landed from where the converter assumed.

Everything they build goes in `obj/rastertest`.
