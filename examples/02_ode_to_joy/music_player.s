; Cycle-bounded TIA channel-0 music player for ode_to_joy.n.
;
; music_index is a byte offset into the packed four-byte MusicStep table.
; The normal path is short, and even the note-change/wrap path is comfortably
; below the 30-scanline overscan budget established by TIM64T in main().

.import music
.import music_index
.import music_counter
.export music_apply_current
.export music_tick

.def AUDC0 $15
.def AUDF0 $17
.def AUDV0 $19

.segment "CODE"

.proc music_apply_current
    ldx music_index
    lda.ax music,x
    sta AUDV0
    lda.ax music+1,x
    sta AUDF0
    lda.ax music+2,x
    sta AUDC0
    rts
.endproc

.proc music_tick
    inc music_counter
    ldx music_index
    lda music_counter
    cmp.ax music+3,x
    bcc @done
    beq @done

    lda #0
    sta music_counter
    txa
    clc
    adc #4
    cmp #128
    bcc @no_wrap
    lda #0
@no_wrap:
    sta music_index
    tax

    lda.ax music,x
    sta AUDV0
    lda.ax music+1,x
    sta AUDF0
    lda.ax music+2,x
    sta AUDC0
@done:
    rts
.endproc
