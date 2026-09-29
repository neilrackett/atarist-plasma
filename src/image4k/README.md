# image4k

Plain `.TOS` picture viewers for the Atari ST/STE, using the per-scanline
palette engine from MD/4000. **No cartridge, no SidecarTridge, no hard
disk** — the pictures are baked in.

MD/4000 is a SidecarTridge Multi-device microfirmware, but none of what it
does to the shifter needs the cartridge; per-scanline palettes are pure
m68k. What needs the cartridge is *generating* content faster than an ST
can, and a still picture isn't that. So the still pictures live here, and
the cartridge gets on with something it's actually needed for.

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

**Three palettes a row is only possible here.** It needs a 19,200-byte
palette table, which overruns the cartridge's shared region but is
nothing at all in ST RAM. 48 colours a row is also the ceiling — a fourth
palette needs 608 cycles of `MOVEM` in a 512-cycle scanline. That it's
the same number Spectrum 512 reached is not a coincidence.

## Keys

| | |
| --- | --- |
| Space / Return | next picture |
| ← / → | nudge the beam phase |
| Esc | restore the desktop and quit |

## Status

**`IMAGE4K1.TOS` is the solid one.** It's the engine validated at RMS 0.00
against the reference on both ST and STE, and it renders cleanly.

`IMAGE4K2` and `IMAGE4K3` are experimental and will show scattered colour
artefacts. The engines themselves are exact — MD/4000's
`tools/rastertest/solve_offset.py` shows the emulator reproducing the
reference with *zero* error at every phase, once you know where the
mid-row change-over landed. The problem is that it doesn't land in the
same place twice: the beam lock only resolves the start of the display to
within a poll iteration, so the bands wander by up to ~20 pixels between
runs, while the picture data is dithered against one fixed assumption.

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

- `image4k.s` — the viewer.
- `raster.s` — the engine: a **verbatim** copy of MD/4000's
  `target/atarist/src/inc/raster.s`, the same file the microfirmware
  assembles and the same file the Hatari harness validates. Keep it
  verbatim; to pick up engine changes, copy it over again.
- `pictures/1`, `pictures/2`, `pictures/3` — the converted pictures, one
  set per engine, because the pixels are dithered against the palettes.

The source photographs are stock images that aren't redistributed, so
the converted pictures are committed instead. To regenerate them, put the
photographs where MD/4000's `assets/source/README.md` says, then run this
on the host (it needs Python 3 with numpy and Pillow):

```sh
src/image4k/pictures.sh        # all three
src/image4k/pictures.sh 1      # just one
```

It uses MD/4000's converter, and looks for an `md-4000` checkout
alongside this one; set `MD4000` to point it somewhere else.
