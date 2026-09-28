# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exact active-path scheduling model for an ordinary all_five stripes pair.
#
# Unlike stripe_stage_search.pl (a broad six-line bandwidth proof), this model
# transcribes the current unrolled active-player pair from all_five.c26.  The six
# PF writes on each scanline are pinned to the currently certified phases.  P1
# and P0 sprite production are semantic jobs with two implementations: the
# current dynamic lookup, or a precomputed byte.  The P1 semantic job also must stage one ROM->RAM PF byte.  Its self-hosted
# implementation is the current refill-probe trick: the inactive PF byte first
# holds the P1 sprite byte, then is overwritten by the next PF byte after Y saves
# the sprite value.  A successful schedule therefore reproduces the proven
# one-byte-per-pair refill against exact PF phases.  The next search target is a
# second staged byte in the P0 scanline, including previous/next-pair tail work.

use strict;
use warnings;

my @ops=(
 {
   id=>'line0_pf',
   description=>'P1 scanline: GRP0/object enables and six certified PF writes',
   asm=>[
     ['sta GRP0',3],
     ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
     ['ldy.z stripe_cache+1',3], ['sty PF1',3],
     ['ldy.z stripe_cache+2',3], ['sty PF2',3],
     ['lsr.zx object_masks+24,x',6],
     ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
     ['dec.z player1_y',5], ['sta PF0',3],
     ['ldy.z stripe_cache+4',3], ['sty PF1',3],
     ['ldy.z stripe_cache+5',3], ['sty PF2',3],
   ],
   earliest=>2,
   latest_end=>61,
   events=>[
     {name=>'PF0L',offset=>13,windows=>[[15,15]]},
     {name=>'PF1L',offset=>19,windows=>[[21,21]]},
     {name=>'PF2L',offset=>25,windows=>[[27,27]]},
     {name=>'PF0R',offset=>47,windows=>[[49,49]]},
     {name=>'PF1R',offset=>53,windows=>[[55,55]]},
     {name=>'PF2R',offset=>59,windows=>[[61,61]]},
   ],
 },
 {
   id=>'p1_sprite',
   description=>'produce P1, stage one PF byte, advance mask, and commit GRP1',
   after=>['line0_pf'],
   latest_end=>98,
   implementations=>[
     {
       name=>'dynamic_plus_stage',
       asm=>[
         ['ldy.z player1_y',3], ['cpy.z object_masks+15',3],
         ['bcc.same activeP1',3], ['lda.iy (player1_graphics),y',5],
         ['sta.z object_masks+43',3],
         ['lda.a next_stripe_pf+0',4], ['sta.z inactive_pf+0',3],
         ['lda.z object_masks+43',3],
         ['lsr.zx object_masks+25,x',6], ['sta GRP1',3],
       ],
       events=>[{name=>'GRP1',offset=>35,windows=>[[76,98]]}],
     },
     {
       name=>'self_hosted',
       asm=>[
         ['ldy.z inactive_pf+0 ; saved P1 byte',3],
         ['lda.a next_stripe_pf+0',4], ['ora #1',2],
         ['sta.z inactive_pf+0',3], ['tya',2],
         ['lsr.zx object_masks+25,x',6], ['sta GRP1',3],
       ],
       events=>[{name=>'GRP1',offset=>22,windows=>[[76,98]]}],
     },
   ],
 },
 {
   id=>'line1_pf',
   description=>'P0 scanline: object enable/bookkeeping and six certified PF writes; PF0R addressing mode is an intentional +1-cycle timing choice',
   after=>['p1_sprite'],
   latest_end=>137,
   implementations=>[
     {
       name=>'pf0r_absolute_plus1',
       asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['ldy.z player0_y',3], ['dey',2], ['cpy.z object_masks+11',3], ['sty.z player0_y',3],
         ['lda.z stripe_cache+3',3], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
       ],
       events=>[
         {name=>'PF0L',offset=>10,windows=>[[95,95]]},
         {name=>'PF1L',offset=>16,windows=>[[101,101]]},
         {name=>'PF2L',offset=>22,windows=>[[107,107]]},
         {name=>'PF0R',offset=>40,windows=>[[125,125]]},
         {name=>'PF1R',offset=>46,windows=>[[131,131]]},
         {name=>'PF2R',offset=>52,windows=>[[137,137]]},
       ],
     },
     {
       name=>'pf0r_zeropage',
       asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['ldy.z player0_y',3], ['dey',2], ['cpy.z object_masks+11',3], ['sty.z player0_y',3],
         ['lda.z stripe_cache+3',3], ['sta.z PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
       ],
       events=>[
         {name=>'PF0L',offset=>10,windows=>[[95,95]]},
         {name=>'PF1L',offset=>16,windows=>[[101,101]]},
         {name=>'PF2L',offset=>22,windows=>[[107,107]]},
         {name=>'PF0R',offset=>39,windows=>[[125,125]]},
         {name=>'PF1R',offset=>45,windows=>[[131,131]]},
         {name=>'PF2R',offset=>51,windows=>[[137,137]]},
       ],
     },
   ],
 },
 {
   id=>'p0_tail',
   description=>'produce staged P0 byte for next pair and finish mask/pair cadence',
   after=>['line1_pf'],
   latest_end=>153,
   implementations=>[
     {
       name=>'dynamic',
       asm=>[
         ['bcc.same activeP0',3], ['lda.iy (player0_graphics),y',5],
         ['lsr.zx object_masks+26,x',6], ['nop',2],
       ],
     },
     {
       name=>'cached',
       asm=>[
         ['lda.z next_grp0',3], ['lsr.zx object_masks+26,x',6], ['nop',2],
       ],
     },
   ],
 },

);

return {
  name=>'all_five exact ordinary pair with one self-hosted PF stage',
  description=>'Exact certified PF phases from the current active-player unrolled pair; P1 must also perform one self-hosted ROM-to-RAM PF staging copy.',
  line_cycles=>76,
  horizon=>154, # pair begins at cycle 2 and its staged P0 tail ends at cycle 153
  # Every solver-created hole must be real 6502 code.  Two- and three-cycle
  # NOP forms make every gap >=2 representable; a one-cycle hole is rejected.
  idle_fillers=>[
    {text=>'nop',cycles=>2},
    {text=>'nop.z timing_scratch',cycles=>3},
  ],
  operations=>\@ops,
};
