; raster.s -- image4k per-scanline palette engine.
;
; Copyright (C) 2026 Neil Rackett
; SPDX-License-Identifier: GPL-3.0-or-later
;
; Re-programs all 16 shifter palette registers once per scanline, in the
; horizontal border, so every row of a 320x200 low-res picture gets its
; own 16 colours. 200 rows x 16 entries = up to 3200 colour slots drawn
; from the STE's 4096 (a plain ST sees the RGB333 truncation of the same
; palette words -- see encode_palette_word in tools/convert.py).
;
; This file is shared VERBATIM between two programs:
;   - image4k.s                       the viewer
;   - tools/rastertest/rastertest.s   a harness used to validate the
;                                     timing under Hatari
; so what gets tested in the emulator is literally what runs on the ST.
;
; --- How the timing works -------------------------------------------
;
; A PAL ST scanline is exactly 512 CPU cycles at 8 MHz (8,000,000 /
; 15,625). In low resolution the shifter displays for 320 of them and
; the remaining ~192 are left/right border and hblank. The 68000 is NOT
; slowed by the shifter on the ST (unlike the Amiga, video and CPU get
; their own interleaved bus slots), so a cycle-counted loop stays locked
; to the beam for a whole frame.
;
; Writing a palette register takes effect at the beam position where the
; write lands, so all 16 writes have to complete inside the border, i.e.
; AFTER the current row's pixels are drawn and BEFORE the next row's.
; A pair of MOVEMs is the only way to fit:
;
;     movem.l (a2)+, d0-d7          ; 12 + 8*8 = 76 cycles  (load 16 words)
;     movem.l d0-d7, (a1)           ;  8 + 8*8 = 72 cycles  (store to $8240)
;
; 148 cycles for a whole 16-colour palette, comfortably inside a ~192
; cycle border. The rest of the loop is padding that makes the body
; exactly one scanline long:
;
;     movem.l (a2)+, d0-d7           76
;     movem.l d0-d7, (a1)            72
;     87 x nop                      348
;     cmpa.l  a3, a2                  6
;     bne.w   raster_line            10   (taken)
;                                  ----
;                                   512   = one PAL scanline
;
; Because the body is exactly 512 cycles there is no per-line resync:
; the loop is phase-locked once at the top of the frame and free-runs
; down the screen. Interrupts MUST be masked at level 7 by the caller
; (a single IRQ would shift every remaining row).
;
; --- Phase locking ---------------------------------------------------
;
; $FFFF8209 is the low byte of the shifter's video address counter. It
; advances while the shifter is fetching pixels and FREEZES during the
; borders and vertical blank, so "sample it, then spin until it changes"
; lands on the first fetch of the next displayed row. (This works only
; because the screen base is 256-byte aligned and a screen is exactly
; 125 * 256 bytes: the counter's low byte ends every frame at 0 and
; reloads to 0, so the reload is not mistaken for the first fetch.)
;
; From there a nop sled positions the first MOVEM pair so it lands in
; the border. The sled is entered via `jmp (a4)`, so the phase is a
; RUNTIME value, not an assembly-time one -- the picture can be nudged
; left/right on real hardware without rebuilding (image4k.s nudges it
; with the cursor keys).

RASTER_LINES          equ 200                 ; displayed rows
RASTER_PAL_BYTES      equ 32                  ; 16 words = one palette
RASTER_SEG_BYTES      equ RASTER_PAL_BYTES    ; ...per segment

; Table sizes. One-segment mode is 200 palettes; two-segment mode is
; 200 pairs (A then B, row-major) and three-segment mode 200 triples,
; each walked with the matching stride.
RASTER_TABLE1_BYTES   equ (RASTER_LINES * RASTER_PAL_BYTES)       ; 6400
RASTER_TABLE2_BYTES   equ (RASTER_LINES * RASTER_PAL_BYTES * 2)   ; 12800
RASTER_TABLE3_BYTES   equ (RASTER_LINES * RASTER_PAL_BYTES * 3)   ; 19200

; Body padding. MUST satisfy:
;   76 + 72 + 4*RASTER_LOOP_PAD_NOPS + 6 + 10 = 512
RASTER_LOOP_PAD_NOPS  equ 87

; Two-segment padding. The body is
;   load A 76 | store A 72 | load B 76 | padM | store B 72 | padE | ctrl 16
; and MUST satisfy 312 + 4*(PAD_MID + PAD_END) = 512, i.e. the two pads
; add up to 50 nops. Splitting them is what positions the second store:
; store A ends just before the row's first pixel, and store B lands
; 4*PAD_MID pixels further on. Where exactly is MEASURED, not derived --
; tools/rastertest/calibrate.py reports it, and PAD_MID is then chosen to
; centre the change-over. At PAD_MID = 27 entry j switches at pixel
; 129 + 4j, i.e. a 60-pixel band centred on the middle of the row.
;
; Note this moves with the phase: one step of phase is one nop is four
; pixels. Recalibrate (and reconvert the pictures) if the phase has to be
; changed on real hardware -- or keep the band where it is by moving a
; nop from PAD_END to PAD_MID for every step the phase goes down.
RASTER2_PAD_MID       equ 27
RASTER2_PAD_END       equ 23

; The two-segment engine needs its own, much longer sled. Its lock wakes
; on the HBL -- which the shifter asserts near the END of a line -- and
; the first store then has to be held off until the border before the row
; AFTER next, the best part of a full scanline away. One-segment's
; 128-nop sled cannot reach. Phases are therefore not comparable between
; the two engines.
RASTER2_SLED_NOPS     equ 256
RASTER2_PHASE_DEFAULT equ 128

; Three-segment padding. Three full palettes is 444 cycles of MOVEM, so
; the line is all but saturated:
;   load A 76 | store A 72 | load B 76 | pad1 | store B 72
;                          | load C 76 | pad2 | store C 72 | padE | ctrl 16
; 460 + 4*(pad1 + pad2 + padE) = 512 leaves just 13 nops to share. With
; pad1 = pad2 = 0 the two mid-row stores land as early as they can, at
; pixels 76..148 and 224..296, which is the only placement that fits
; segment C's last entry (pixel ~292) inside the row at all. In other
; words the change-over positions at three segments are essentially
; FIXED -- there is no room left to move them. All 13 nops go on the end.
;
; The two stores are 148 cycles apart and each takes 60 pixels to work
; through its sixteen entries, so the middle pure zone is pinned at 88
; pixels whatever you do; the phase default is then chosen to balance the
; outer two at ~56 pixels each rather than leaving segment A governing
; almost nothing.
;
; 48 colours a row, which is not a coincidence: it is the same ceiling
; Spectrum 512 hit, for the same reason.
RASTER3_PAD_MID1      equ 0
RASTER3_PAD_MID2      equ 0
RASTER3_PAD_END       equ 13
RASTER3_SLED_NOPS     equ 256
RASTER3_PHASE_DEFAULT equ 139

; Phase sled. RASTER_SLED_NOPS is the maximum phase.
;
; Measured under Hatari with tools/rastertest (which runs THIS file and
; scores the emulator's screenshots against the picture the converter
; says the ST should be showing):
;
;     machine   phases rendering the picture exactly
;     STE       54 .. 90
;     ST        58 .. 88
;
; Below the window the writes land in the current row's pixels; above it
; they spill into the next row's. The default is the centre of the
; overlap, which leaves ~14 nops (~56 cycles) of margin on each side --
; comfortably more than the +/-22 cycles of jitter the phase-lock poll
; below can contribute, since a `cmp.b`/`beq.s` pair only resolves the
; counter change to within one 22-cycle iteration.
RASTER_SLED_NOPS      equ 128
RASTER_PHASE_DEFAULT  equ 72

RASTER_VIDCNT_LOW     equ $FFFF8209           ; video address counter, low byte
RASTER_PALETTE_BASE   equ $FFFF8240           ; 16 shifter palette words
RASTER_MFP_IMRA       equ $FFFFFA13           ; MFP interrupt mask A / B
RASTER_MFP_IMRB       equ $FFFFFA15


;--------------------------------------------------------------------
; raster_run -- paint one frame's worth of per-scanline palettes.
;
; In:   A2   = base of the palette table.
;       D0.w = phase, 0..RASTER_SLED_NOPS (out of range -> default).
;       D1.w = segments per row: 1, 2 or 3 (anything else -> 1).
;       SR   = interrupts masked at level 7. NOT done here: the caller
;              usually has other things to mask/restore around this.
;
; Out:  nothing. Clobbers D0-D7 / A1-A4.
;
; Must be entered during the vertical blank or the top border -- it
; applies row 0's palette immediately, then locks onto row 0's first
; pixel fetch and free-runs rows 1..199 from there. Returns while the
; beam is still on the last row, leaving the bottom border and vblank
; (~113 lines, ~58,000 cycles) free for the caller.
;--------------------------------------------------------------------
raster_run:
    cmp.w   #3, d1
    beq     raster_run3
    cmp.w   #2, d1
    beq     raster_run2
    ; fall through to the one-segment engine

;--------------------------------------------------------------------
; raster_run1 -- one palette per row, written in the horizontal border.
;--------------------------------------------------------------------
raster_run1:
    lea     RASTER_PALETTE_BASE.w, a1

    ; Resolve the phase into a landing address inside the nop sled.
    ; Each nop is 2 bytes, so entering at (sled_end - 2*phase) executes
    ; exactly `phase` of them.
    lea     raster_sled_end(pc), a4
    cmp.w   #RASTER_SLED_NOPS, d0
    bls.s   raster_phase_ok
    moveq   #RASTER_PHASE_DEFAULT, d0
raster_phase_ok:
    add.w   d0, d0
    suba.w  d0, a4

    ; Row 0's palette goes up now, while the beam is still above the
    ; display area -- the free-running loop below is always one row
    ; ahead of itself, so it never gets a chance to write this one.
    movem.l (a2)+, d0-d7
    movem.l d0-d7, (a1)

    ; A3 = one past the last row's entry. A2 already points at row 1,
    ; so this is 199 iterations.
    lea     (RASTER_PAL_BYTES*(RASTER_LINES-1))(a2), a3

    ; Phase-lock: spin on the frozen video counter until the shifter
    ; starts fetching row 0.
    move.b  RASTER_VIDCNT_LOW.w, d0
raster_sync:
    cmp.b   RASTER_VIDCNT_LOW.w, d0
    beq.s   raster_sync

    jmp     (a4)                        ; 8 cycles, into the sled

raster_sled:
    rept    RASTER_SLED_NOPS
    nop
    endr
raster_sled_end:

    ; --- the beam-locked body: exactly 512 cycles ------------------
raster_line:
    movem.l (a2)+, d0-d7                ; 76  next row's 16 colours
    movem.l d0-d7, (a1)                 ; 72  -> $FFFF8240..$FFFF825E
    rept    RASTER_LOOP_PAD_NOPS
    nop                                 ; 348 total
    endr
    cmpa.l  a3, a2                      ;  6
    bne.w   raster_line                 ; 10 taken (forced .w: the body
                                        ;    is ~184 bytes, out of reach
                                        ;    of a short branch, and .w
                                        ;    costs the same when taken)
    rts


;--------------------------------------------------------------------
; raster_run2 -- TWO palettes per row: one in the border as before, and
; a second written across the middle of the row.
;
; A palette register takes effect at the beam position where it is
; written, so the second store is not a clean edge: MOVEM.L puts a
; register out every 8 cycles (two word writes of 4), which makes entry
; j change over at pixel (store_start + 8 + 4j). Pixels left of that see
; segment A's colour for entry j, pixels right of it see segment B's.
;
; That 60-pixel band is not wasted -- it is simply a region where the
; live palette is a known mix of A and B, and the converter models it
; exactly (see SEGMENT_SWITCH_X in tools/convert.py, which is
; calibrated against Hatari rather than assumed). Up to 32 colours per
; row, 6400 per picture.
;
; Table layout is row-major pairs: A0 B0 A1 B1 ... A199 B199.
;
; Row 0 gets segment A only. The loop is always a row ahead of itself --
; it writes row k's palettes from inside row k-1 -- so there is no
; iteration positioned to write B0, and B0's table slot is skipped.
; The converter fits row 0 with a single palette to match.
;--------------------------------------------------------------------
raster_run2:
    lea     RASTER_PALETTE_BASE.w, a1

    lea     raster2_sled_end(pc), a4
    cmp.w   #RASTER2_SLED_NOPS, d0
    bls.s   raster2_phase_ok
    move.w  #RASTER2_PHASE_DEFAULT, d0
raster2_phase_ok:
    add.w   d0, d0
    suba.w  d0, a4

    ; Rows 0 and 1's palette, while the beam is still above the display.
    movem.l (a2)+, d0-d7
    movem.l d0-d7, (a1)

    ; Skip B0, A1 and B1 -- the stabilised lock below costs a row, so
    ; rows 0 and 1 both run on the palette just written. A3 = one past
    ; the table, 198 iterations covering rows 2..199.
    lea     (RASTER_SEG_BYTES*3)(a2), a2
    lea     (RASTER_SEG_BYTES*2*(RASTER_LINES-2))(a2), a3

    bsr     raster_lock

    jmp     (a4)                        ; 8 cycles, into the sled

raster2_sled:
    rept    RASTER2_SLED_NOPS
    nop
    endr
raster2_sled_end:

    ; --- the beam-locked body: exactly 512 cycles ------------------
raster2_line:
    movem.l (a2)+, d0-d7                ; 76  next row, segment A
    movem.l d0-d7, (a1)                 ; 72  -> lands in the border
    movem.l (a2)+, d0-d7                ; 76  next row, segment B
    rept    RASTER2_PAD_MID
    nop                                 ; 48
    endr
    movem.l d0-d7, (a1)                 ; 72  -> lands across the row
    rept    RASTER2_PAD_END
    nop                                 ; 152
    endr
    cmpa.l  a3, a2                      ;  6
    bne.w   raster2_line                ; 10
    rts


;--------------------------------------------------------------------
; raster_lock -- phase-lock to the beam with no frame-to-frame jitter.
;
; The video-counter poll on its own only resolves the start of the
; display to within one poll iteration, and where inside that iteration
; it lands moves from frame to frame. Measured against Hatari, the whole
; engine slides by up to ~20 pixels between frames.
;
; One palette change per row does not care: the write just has to land
; somewhere in a ~130-cycle-wide border, and raster_run1 is left on the
; plain poll for exactly that reason -- it is the validated path and
; there is nothing to gain by changing it. Two changes per row care very
; much, because the second one lands ON the picture and the pixel data
; is dithered against where it lands. Twenty pixels of slop would make
; the change-over crawl about and shimmer.
;
; So the poll is demoted to finding the right line, and the actual lock
; is a `stop` woken by the horizontal blank. With the CPU halted there is
; no in-flight instruction for the interrupt to wait on, so the latency
; from the HBL to the instruction after `stop` is constant -- the classic
; Atari "stabiliser". `stop` loads SR and halts as one indivisible step,
; which is why the mask is not lowered with a separate MOVE first: an HBL
; arriving in between would waste the line and leave us unstabilised.
;
; The HBL is the only interrupt allowed through: the MFP is masked off
; around the stop (and restored), and the VBL cannot fire here because
; the beam is at the top of the display, sixty-odd lines past it.
;
; The caller must have a bare-RTE handler on the HBL vector ($68).
; image4k.s and the harness both install their own.
;
; Costs one scanline -- the wake is the NEXT line boundary, not this one.
;
; Clobbers D0. Returns with interrupts masked at level 7.
;--------------------------------------------------------------------
raster_lock:
    ; Coarse: spin on the frozen video counter until the shifter starts
    ; fetching. That puts us on a known line, within a poll iteration.
    move.b  RASTER_VIDCNT_LOW.w, d0
raster_lock_sync:
    cmp.b   RASTER_VIDCNT_LOW.w, d0
    beq.s   raster_lock_sync

    ; Fine: halt, and let the next HBL wake us at a fixed cycle.
    move.b  RASTER_MFP_IMRA.w, d0
    lsl.w   #8, d0
    move.b  RASTER_MFP_IMRB.w, d0
    clr.b   RASTER_MFP_IMRA.w
    clr.b   RASTER_MFP_IMRB.w

    stop    #$2100                      ; woken by the HBL, exactly
    move.w  #$2700, sr

    move.b  d0, RASTER_MFP_IMRB.w
    lsr.w   #8, d0
    move.b  d0, RASTER_MFP_IMRA.w
    rts


;--------------------------------------------------------------------
; raster_run3 -- THREE palettes per row: one in the border and two
; written across the row. 48 colours a row, ~9600 a picture.
;
; Same model as raster_run2 -- entry j of each segment takes effect at
; the pixel the MOVEM reaches it, and the bands between are a known mix,
; which the converter dithers against. There are simply two of them now,
; and no room left to move either (see RASTER3_PAD_*).
;
; Table layout is row-major triples: A0 B0 C0 A1 B1 C1 ... and, as in
; raster_run2, rows 0 and 1 get segment A only.
;--------------------------------------------------------------------
raster_run3:
    lea     RASTER_PALETTE_BASE.w, a1

    lea     raster3_sled_end(pc), a4
    cmp.w   #RASTER3_SLED_NOPS, d0
    bls.s   raster3_phase_ok
    move.w  #RASTER3_PHASE_DEFAULT, d0
raster3_phase_ok:
    add.w   d0, d0
    suba.w  d0, a4

    ; Rows 0 and 1's palette, while the beam is still above the display.
    movem.l (a2)+, d0-d7
    movem.l d0-d7, (a1)

    ; Skip B0/C0 and the whole of row 1, then A3 = one past the table.
    lea     (RASTER_SEG_BYTES*5)(a2), a2
    lea     (RASTER_SEG_BYTES*3*(RASTER_LINES-2))(a2), a3

    bsr     raster_lock

    jmp     (a4)                        ; 8 cycles, into the sled

raster3_sled:
    rept    RASTER3_SLED_NOPS
    nop
    endr
raster3_sled_end:

    ; --- the beam-locked body: exactly 512 cycles ------------------
raster3_line:
    movem.l (a2)+, d0-d7                ; 76  next row, segment A
    movem.l d0-d7, (a1)                 ; 72  -> lands in the border
    movem.l (a2)+, d0-d7                ; 76  segment B
    ifne    RASTER3_PAD_MID1
    rept    RASTER3_PAD_MID1
    nop
    endr
    endc
    movem.l d0-d7, (a1)                 ; 72  -> ~1/4 across the row
    movem.l (a2)+, d0-d7                ; 76  segment C
    ifne    RASTER3_PAD_MID2
    rept    RASTER3_PAD_MID2
    nop
    endr
    endc
    movem.l d0-d7, (a1)                 ; 72  -> ~3/4 across the row
    rept    RASTER3_PAD_END
    nop                                 ; 52
    endr
    cmpa.l  a3, a2                      ;  6
    bne.w   raster3_line                ; 10
    rts
