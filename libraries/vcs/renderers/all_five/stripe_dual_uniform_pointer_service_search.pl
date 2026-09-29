# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Six-line refill when P0 and P1 are each uniform for the same three pairs.
#
# A rolling planner chooses a three-pair window in which each player's three
# rows are independently all-active or all-inactive.  Before the window it
# prepares one two-byte service pointer per player:
#
#   active:   pointer -> first of the three required graphics bytes
#   inactive: pointer -> a three-byte zero run
#
# The unrolled pairs use local Y indices 2,1,0, so both modes have the same
# five-cycle (zp),Y load and need no height compare or activity branch in the
# hot window.  The active pointer is biased so +2/+1/+0 addresses the live
# graphics rows; the inactive pointer addresses the zero run directly.
#
# X carries PF bytes 0/2/4 across the P0 scanlines.  Y remains the local
# service index across each P0 line, so P0 needs no index reload in its tail.
# That saves enough time for each P0 tail to have eight real cycles after the
# sprite/mask work.  Pairs 0 and 1 use those cycles to copy COLUPF/COLUBK with
# deliberately-absolute stores (4+4 cycles); pair 2 restores the packed-mask X
# seed and uses three ordinary NOPs.  Thus six scanlines move all six PF bytes
# *and* both colors while retaining the pair cadence.
#
# Pointer construction/start dispatch is deliberately outside this proof.  A
# separate exhaustive regression proves the minimal fixed ordinary candidate
# set 1,3,5,9,11 always contains a common uniform window for both players.  The
# three-pair service therefore never crosses a packed-row edge.

use strict;
use warnings;

my @ops;
my $PAIR=152;

for my $p (0..2) {
   my $b=$p*$PAIR;
   my $idx=2-$p;
   my $even=2*$p;
   my $odd=$even+1;

   push @ops, {
      id=>"p${p}_p1_line", earliest=>$b+2, latest_end=>$b+60,
      after=>$p ? ["p".($p-1)."_p0_tail"] : [],
      description=>"pair $p P1 scanline with direct known-row Ball shift",
      asm=>[
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['ldy.z stripe_cache+1',3], ['sty PF1',3],
         ['ldy.z stripe_cache+2',3], ['sty PF2',3],
         ["lsr.z object_masks_service_ball_$p",5],
         ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
         ['dec.z player1_y',5], ['sta PF0',3],
         ['ldy.z stripe_cache+4',3], ['sty PF1',3],
         ['ldy.z stripe_cache+5',3], ['sty PF2',3],
      ],
      events=>[
         {name=>'PF0L',offset=>13,windows=>[[$b+15,$b+15]]},
         {name=>'PF1L',offset=>19,windows=>[[$b+21,$b+21]]},
         {name=>'PF2L',offset=>25,windows=>[[$b+27,$b+27]]},
         {name=>'PF0R',offset=>46,windows=>[[$b+48,$b+48]]},
         {name=>'PF1R',offset=>52,windows=>[[$b+54,$b+54]]},
         {name=>'PF2R',offset=>58,windows=>[[$b+60,$b+60]]},
      ],
   };

   push @ops, {
      id=>"p${p}_p1_service", earliest=>$b+61, latest_end=>$b+79,
      after=>["p${p}_p1_line"],
      description=>"pair $p branchless uniform-mode P1 pointer load carrying PF byte $even in X",
      asm=>[
         ["ldy #$idx",2],
         ['lda.iy (p1_service_ptr),y',5],
         ["ldx.a next_stripe_pf+$even",4],
         ["lsr.z object_masks_service_m1_$p",5],
         ['sta GRP1',3],
      ],
      events=>[{name=>'GRP1',offset=>18,windows=>[[$b+79,$b+79]]}],
   };

   push @ops, {
      id=>"p${p}_p0_line", earliest=>$b+80, latest_end=>$b+132,
      after=>["p${p}_p1_service"],
      description=>"pair $p P0 scanline stages PF byte $odd while Y keeps local pointer index $idx",
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['dec.z player0_y',5],
         ["lda.a next_stripe_pf+$odd",4], ["sta.z inactive_pf+$odd",3],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ],
      events=>[
         {name=>'PF0L',offset=>10,windows=>[[$b+90,$b+90]]},
         {name=>'PF1L',offset=>16,windows=>[[$b+96,$b+96]]},
         {name=>'PF2L',offset=>22,windows=>[[$b+102,$b+102]]},
         {name=>'PF0R',offset=>40,windows=>[[$b+120,$b+120]]},
         {name=>'PF1R',offset=>46,windows=>[[$b+126,$b+126]]},
         {name=>'PF2R',offset=>52,windows=>[[$b+132,$b+132]]},
      ],
   };

   my @tail_extra;
   if ($p < 2) {
      push @tail_extra,
         ["ldx.a next_stripe_color+$p",4],
         ["stx.a next_color_slot+$p",4];
   } else {
      push @tail_extra,
         ['ldx #service_resume_x',2],
         ['nop',2], ['nop',2], ['nop',2];
   }

   push @ops, {
      id=>"p${p}_p0_tail", earliest=>$b+133, latest_end=>$b+153,
      after=>["p${p}_p0_line"],
      description=>"pair $p commits PF byte $even, loads P0 through the uniform service pointer, and spends the eight-cycle tail on rolling state",
      asm=>[
         ["stx.z inactive_pf+$even",3],
         ['lda.iy (p0_service_ptr),y',5],
         ["lsr.z object_masks_service_m0_$p",5],
         @tail_extra,
      ],
   };
}

return {
   name=>'all_five dual-uniform-pointer three-pair service',
   description=>'A common three-pair uniform window removes both player height tests; six scanlines refill six PF bytes plus two colors with two rolling service pointers.',
   line_cycles=>76,
   horizon=>458,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
