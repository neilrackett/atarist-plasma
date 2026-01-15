.text
    .globl _render_scanlines_rows
    .extern _plasma_palette_rows

_render_scanlines_rows:
    move.w  %sr,-(%sp)
    move.w  #0x2700,%sr
    movem.l %d0-%d7/%a0-%a6,-(%sp)

    lea     _plasma_palette_rows,%a0
    move.l  (%a0),%a2
    lea     0xFFFF8240.w,%a1

    | PRIME FIRST LINE PALETTE DURING VBL TO AVOID TOP-LINE ARTIFACTS
    movea.l %a2,%a0
    move.w  (%a0)+,0(%a1)
    move.w  (%a0)+,2(%a1)
    move.w  (%a0)+,4(%a1)
    move.w  (%a0)+,6(%a1)
    move.w  (%a0)+,8(%a1)
    move.w  (%a0)+,10(%a1)
    move.w  (%a0)+,12(%a1)
    move.w  (%a0)+,14(%a1)
    move.w  (%a0)+,16(%a1)
    move.w  (%a0)+,18(%a1)
    move.w  (%a0)+,20(%a1)
    move.w  (%a0)+,22(%a1)
    move.w  (%a0)+,24(%a1)
    move.w  (%a0)+,26(%a1)
    move.w  (%a0)+,28(%a1)
    move.w  (%a0)+,30(%a1)

    moveq   #3,%d6
    move.w  #198,%d7

.line_loop:
    | SYNC TO SCANLINE
    move.b  0xFFFF8209.w,%d0
.sync:
    cmp.b   0xFFFF8209.w,%d0
    beq.s   .sync

    | PADDING: Wait for the beam to enter the visible area
    .rept 14
    nop
    .endr

    | BLAST ALL 16 COLORS (REPEAT ROW 10x)
    movea.l %a2,%a0
    move.w  (%a0)+,0(%a1)
    move.w  (%a0)+,2(%a1)
    move.w  (%a0)+,4(%a1)
    move.w  (%a0)+,6(%a1)
    move.w  (%a0)+,8(%a1)
    move.w  (%a0)+,10(%a1)
    move.w  (%a0)+,12(%a1)
    move.w  (%a0)+,14(%a1)
    move.w  (%a0)+,16(%a1)
    move.w  (%a0)+,18(%a1)
    move.w  (%a0)+,20(%a1)
    move.w  (%a0)+,22(%a1)
    move.w  (%a0)+,24(%a1)
    move.w  (%a0)+,26(%a1)
    move.w  (%a0)+,28(%a1)
    move.w  (%a0)+,30(%a1)

    | WAIT FOR H-BLANK
    .rept 40
    nop
    .endr

    dbra    %d6,.keep_row
    add.l   #32,%a2
    moveq   #4,%d6
.keep_row:
    dbra    %d7,.line_loop

    movem.l (%sp)+,%d0-%d7/%a0-%a6
    move.w  (%sp)+,%sr
    rts
