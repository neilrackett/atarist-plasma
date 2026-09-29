; image4k.s -- per-scanline palette picture viewer for the Atari ST/STE,
; using the MD/4000 raster engine.
;
; Copyright (C) 2026 Neil Rackett
; SPDX-License-Identifier: GPL-3.0-or-later
;
; A plain .TOS program. No cartridge, no SidecarTridge, no hard disk --
; the pictures are baked in and the whole thing is the raster engine plus
; about a hundred instructions of housekeeping.
;
; This exists because none of what MD/4000 does to the SHIFTER needs the
; cartridge: per-scanline palettes are pure m68k. What needs the
; cartridge is generating content faster than an ST can. A still picture
; isn't that, so a still picture belongs here.
;
; The palette engine is raster.s, a VERBATIM copy of MD/4000's
; target/atarist/src/inc/raster.s -- the same file the microfirmware
; assembles and the same file the Hatari harness validates.
;
; Build one .TOS per engine with -DSEGMENTS=1|2|3 (see the Makefile):
;   1 -> 16 colours a row, 3200 a picture   (the validated engine)
;   2 -> 32 colours a row, 6400 a picture   (experimental)
;   3 -> 48 colours a row, 9600 a picture   (experimental)
;
; Three palettes a row is only possible here. It needs a 19200-byte
; palette table, which overruns the cartridge's shared region but is
; nothing at all in ST RAM.
;
; Keys:
;   Space / Return   next picture
;   Left / Right     nudge the beam phase (see raster.s)
;   Esc              restore the desktop and quit

    ifnd  SEGMENTS
SEGMENTS              equ 1
    endc

PIC_BYTES             equ 32000                       ; 320x200, 4 planes
PAL_BYTES             equ (200 * 32 * SEGMENTS)       ; 16 words per segment

SCANCODE_ESC          equ $01
SCANCODE_LEFT         equ $4B
SCANCODE_RIGHT        equ $4D
SCANCODE_SPACE        equ $39
SCANCODE_RETURN       equ $1C

    text

start:
    move.l  4(sp), a5                   ; basepage: give back the rest of
    move.l  $0C(a5), d0                 ; the TPA so we sit in as little
    add.l   $14(a5), d0                 ; memory as we actually need
    add.l   $1C(a5), d0
    add.l   #$100, d0
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

    lea     $FFFF8240.w, a0             ; save the palette
    lea     old_pal, a1
    moveq   #15, d0
.save_pal:
    move.w  (a0)+, (a1)+
    dbra    d0, .save_pal

    ; The engines above one segment stabilise themselves with a `stop`
    ; woken by the HBL, so $68 must be a bare RTE and nothing else --
    ; TOS's own handler would put work, and possibly branches, between
    ; the wake and the return.
    move.l  $68.w, old_hbl
    lea     view_hbl(pc), a0
    move.l  a0, $68.w

    ; raster.s locks onto the video address counter, which only behaves
    ; if the screen base is 256-byte aligned (see the comments there).
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

    move.w  #RASTER_PHASE, phase
    clr.w   picture
    bsr     load_picture

main_loop:
    ; Smoke-test hook: with -DAUTOSHOT=n, hold each picture for n frames,
    ; screenshot it through Hatari's Scrdmp (XBIOS 20), and quit after the
    ; last one. Nothing is emitted in a normal build.
    ifd   AUTOSHOT
    addq.w  #1, frames
    cmp.w   #AUTOSHOT, frames
    blt.s   .no_shot
    clr.w   frames
    move.w  #20, -(sp)                  ; Scrdmp()
    trap    #14
    addq.l  #2, sp
    move.w  picture, d0
    addq.w  #1, d0
    cmp.w   #PIC_COUNT, d0
    bge.s   .auto_done
    move.w  d0, picture
    bsr     load_picture
    bra.s   .no_shot
.auto_done:
    pea     quit_cmd                    ; ask Hatari to quit
    move.w  #255, -(sp)
    trap    #14
    addq.l  #6, sp
    bra     done
.no_shot:
    endc

    move.w  #37, -(sp)                  ; Vsync() -- returns at the top of
    trap    #14                         ; the vertical blank, ~63 lines
    addq.l  #2, sp                      ; above the first displayed row

    move.w  #$2700, sr                  ; the beam-locked loop cannot take
    movea.l pal_ptr, a2                 ; a single interrupt
    move.w  phase, d0
    move.w  #SEGMENTS, d1
    bsr     raster_run
    move.w  #$2300, sr

    bsr     poll_key
    tst.w   d0
    beq     main_loop
    bmi     done                        ; Esc
    bra     main_loop


;--------------------------------------------------------------------
; load_picture -- put picture `picture` on screen.
;
; Blanks the palette across the copy. 32000 bytes is far longer than a
; frame, so the beam would otherwise walk through a half-written screen;
; blanking turns that into a single black frame instead of a tear.
;--------------------------------------------------------------------
load_picture:
    lea     $FFFF8240.w, a0             ; blank
    moveq   #15, d0
.blank:
    clr.w   (a0)+
    dbra    d0, .blank

    move.w  picture, d0
    lsl.w   #3, d0                      ; 8 bytes per table entry
    lea     pic_table, a0
    movea.l (a0, d0.w), a1              ; pixels
    move.l  4(a0, d0.w), pal_ptr

    movea.l scr_base, a2
    move.w  #(PIC_BYTES/4)-1, d0
.copy:
    move.l  (a1)+, (a2)+
    dbra    d0, .copy
    rts


;--------------------------------------------------------------------
; poll_key -- non-blocking key read.
; Out: D0.w = -1 quit, +1 something changed, 0 nothing happened.
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
    cmp.b   #SCANCODE_SPACE, d0
    beq.s   .next
    cmp.b   #SCANCODE_RETURN, d0
    beq.s   .next
.none:
    moveq   #0, d0
    rts
.changed:
    moveq   #1, d0
    rts
.left:
    tst.w   phase
    beq.s   .changed
    subq.w  #1, phase
    bra.s   .changed
.right:
    addq.w  #1, phase
    bra.s   .changed
.next:
    move.w  picture, d0
    addq.w  #1, d0
    cmp.w   #PIC_COUNT, d0
    blt.s   .store
    moveq   #0, d0
.store:
    move.w  d0, picture
    bsr     load_picture
    bra.s   .changed
.quit:
    moveq   #-1, d0
    rts


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


view_hbl:
    rte


    include "raster.s"

; Per-engine default phase. raster.s documents why these are not on the
; same scale: the multi-segment engines lock on the HBL rather than the
; video counter, and need most of a scanline of sled to reach the border
; before the row they are painting.
    ifeq  SEGMENTS-1
RASTER_PHASE          equ RASTER_PHASE_DEFAULT
    endc
    ifeq  SEGMENTS-2
RASTER_PHASE          equ RASTER2_PHASE_DEFAULT
    endc
    ifeq  SEGMENTS-3
RASTER_PHASE          equ RASTER3_PHASE_DEFAULT
    endc


    data

    ifd   AUTOSHOT
quit_cmd:
    dc.b    "hatari-shortcut quit", 0
    even
    endc

pic_table:
    dc.l    pic0_scr, pic0_pal
    dc.l    pic1_scr, pic1_pal
    dc.l    pic2_scr, pic2_pal
PIC_COUNT             equ 3

; Picked up from pictures/SEGMENTS/, which the Makefile puts on the
; include path -- the pixels are dithered against the palettes, so each
; engine has its own conversion of the same three photographs.
pic0_scr:
    incbin  "balloons.scr"
pic0_pal:
    incbin  "balloons.pal"
pic1_scr:
    incbin  "braies.scr"
pic1_pal:
    incbin  "braies.pal"
pic2_scr:
    incbin  "spectrum.scr"
pic2_pal:
    incbin  "spectrum.pal"
    even


    bss

old_ssp:
    ds.l    1
old_phys:
    ds.l    1
old_hbl:
    ds.l    1
scr_base:
    ds.l    1
pal_ptr:
    ds.l    1
old_rez:
    ds.w    1
picture:
    ds.w    1
frames:
    ds.w    1
phase:
    ds.w    1
old_pal:
    ds.w    16
screen:
    ds.b    32768+256

    end
