; rastertest.s -- test harness for the image4k raster engine.
;
; Copyright (C) 2026 Neil Rackett
; SPDX-License-Identifier: GPL-3.0-or-later
;
; A plain .TOS program that displays one image4k picture using the SAME
; raster core the viewer uses (../../raster.s, included verbatim), so the
; cycle-exact beam timing can be validated in Hatari -- which emulates the
; shifter, and mid-line palette writes, accurately -- without an ST on
; the desk.
;
; It sweeps the phase (where in the scanline the 16 palette writes land)
; across a range, holding each value for a few frames and taking a Hatari
; screenshot of each, then quits the emulator. run.sh drives the sweep
; and collects the PNGs; the right phase is the one whose picture has no
; colour "bleeding" into the left edge of each row.
;
; On real hardware it is still useful interactively: left/right arrow
; nudge the phase, Esc restores the screen and exits.
;
; Screenshots and quit go through Hatari's XBIOS hooks (run Hatari with
; --bios-intercept on):
;   XBIOS 20  Scrdmp()            -> save a screenshot
;   XBIOS 255 HatariControl(str)  -> "hatari-shortcut quit"

; Sweep bounds. Overridable from run.sh with vasm -D so a run can zoom in
; on the edges of the clean window without editing this file.
    ifnd  PHASE_START
PHASE_START           equ 60
    endc
    ifnd  PHASE_END
PHASE_END             equ 116
    endc
    ifnd  PHASE_STEP
PHASE_STEP            equ 4
    endc
    ifnd  SEGMENTS
SEGMENTS              equ 1
    endc
FRAMES_PER_PHASE      equ 3

SCANCODE_ESC          equ $01
SCANCODE_LEFT         equ $4B
SCANCODE_RIGHT        equ $4D

    text

start:
    ; Give the rest of the TPA back so nothing else is disturbed -- not
    ; strictly needed, but keeps the program well behaved on hardware.
    move.l  4(sp), a5                   ; basepage
    move.l  $0C(a5), d0                 ; text length
    add.l   $14(a5), d0                 ; + data
    add.l   $1C(a5), d0                 ; + bss
    add.l   #$100, d0                   ; + basepage
    move.l  d0, -(sp)
    move.l  a5, -(sp)
    clr.w   -(sp)
    move.w  #$4A, -(sp)                 ; Mshrink
    trap    #1
    lea     12(sp), sp

    clr.l   -(sp)                       ; Super(0)
    move.w  #$20, -(sp)
    trap    #1
    addq.l  #6, sp
    move.l  d0, old_ssp

    move.w  #2, -(sp)                   ; Physbase()
    trap    #14
    addq.l  #2, sp
    move.l  d0, old_phys

    move.w  #4, -(sp)                   ; Getrez()
    trap    #14
    addq.l  #2, sp
    move.w  d0, old_rez

    ; The two-segment engine stabilises itself with a `stop` woken by
    ; the HBL, so $68 has to be a bare RTE and nothing else -- TOS's own
    ; handler would add work (and possibly branches) between the wake and
    ; the return.
    move.l  $68.w, old_hbl
    lea     test_hbl(pc), a0
    move.l  a0, $68.w

    lea     $FFFF8240.w, a0             ; save the palette
    lea     old_pal, a1
    moveq   #15, d0
.save_pal:
    move.w  (a0)+, (a1)+
    dbra    d0, .save_pal

    ; The raster engine's phase lock reads the video address counter and
    ; relies on it being back at 0 when the frame wraps, which needs a
    ; 256-byte aligned screen (see raster.s).
    lea     screen+255, a0
    move.l  a0, d0
    and.l   #$FFFFFF00, d0
    move.l  d0, scr_base

    move.w  #0, -(sp)                   ; Setscreen(log, phys, LOW_RES)
    move.l  scr_base, -(sp)
    move.l  scr_base, -(sp)
    move.w  #5, -(sp)
    trap    #14
    lea     12(sp), sp

    movea.l scr_base, a1                ; blit the picture in -- AFTER
    lea     picture, a0                 ; Setscreen, which clears the
    move.w  #(32000/4)-1, d0            ; screen when the rez changes
.copy:
    move.l  (a0)+, (a1)+
    dbra    d0, .copy

    move.w  #PHASE_START, phase

phase_loop:
    move.w  #FRAMES_PER_PHASE, frames

frame_loop:
    move.w  #37, -(sp)                  ; Vsync() -- returns at the top of
    trap    #14                         ; the vertical blank, ~63 lines
    addq.l  #2, sp                      ; before the first displayed row

    move.w  #$2700, sr                  ; the beam-locked loop cannot take
    lea     linepal, a2                 ; a single interrupt
    move.w  phase, d0
    move.w  #SEGMENTS, d1
    bsr     raster_run
    move.w  #$2300, sr

    bsr     poll_key
    tst.w   d0
    bmi     done                        ; Esc

    subq.w  #1, frames
    bne     frame_loop

    move.w  #20, -(sp)                  ; Scrdmp() -> Hatari screenshot
    trap    #14
    addq.l  #2, sp

    move.w  phase, d0
    add.w   #PHASE_STEP, d0
    move.w  d0, phase
    cmp.w   #PHASE_END, d0
    ble     phase_loop

    pea     quit_cmd                    ; ask Hatari to quit; on real
    move.w  #255, -(sp)                 ; hardware XBIOS 255 is a no-op
    trap    #14                         ; and we just fall through
    addq.l  #6, sp

done:
    move.w  #0, -(sp)                   ; restore the desktop screen
    move.l  old_phys, -(sp)
    move.l  old_phys, -(sp)
    move.w  #5, -(sp)
    trap    #14
    lea     12(sp), sp

    move.l  old_hbl, $68.w

    lea     old_pal, a0
    lea     $FFFF8240.w, a1
    moveq   #15, d0
.restore_pal:
    move.w  (a0)+, (a1)+
    dbra    d0, .restore_pal

    move.l  old_ssp, -(sp)              ; Super(old_ssp)
    move.w  #$20, -(sp)
    trap    #1
    addq.l  #6, sp

    clr.w   -(sp)                       ; Pterm0()
    trap    #1


;--------------------------------------------------------------------
; poll_key -- non-blocking key read.
; Out: D0.w = -1 to quit, 0 otherwise. Arrow keys nudge `phase`.
;--------------------------------------------------------------------
poll_key:
    move.w  #2, -(sp)                   ; Bconstat(CON)
    move.w  #1, -(sp)
    trap    #13
    addq.l  #4, sp
    tst.w   d0
    beq.s   .none

    move.w  #2, -(sp)                   ; Bconin(CON)
    move.w  #2, -(sp)
    trap    #13
    addq.l  #4, sp

    swap    d0                          ; scancode -> low byte
    cmp.b   #SCANCODE_ESC, d0
    beq.s   .quit
    cmp.b   #SCANCODE_LEFT, d0
    beq.s   .left
    cmp.b   #SCANCODE_RIGHT, d0
    beq.s   .right
.none:
    moveq   #0, d0
    rts
.left:
    subq.w  #1, phase
    bpl.s   .none
    clr.w   phase
    bra.s   .none
.right:
    addq.w  #1, phase
    bra.s   .none
.quit:
    moveq   #-1, d0
    rts


test_hbl:
    rte


    include "raster.s"


    data

phase:
    dc.w    PHASE_START
frames:
    dc.w    0

quit_cmd:
    dc.b    "hatari-shortcut quit", 0
    even

picture:
    incbin  "picture.scr"
    even
linepal:
    incbin  "picture.pal"
    even


    bss

old_ssp:
    ds.l    1
old_hbl:
    ds.l    1
old_phys:
    ds.l    1
scr_base:
    ds.l    1
old_rez:
    ds.w    1
old_pal:
    ds.w    16
screen:
    ds.b    32768+256

    end
