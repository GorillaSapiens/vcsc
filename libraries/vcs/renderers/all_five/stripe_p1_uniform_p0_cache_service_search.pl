# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Six-line refill with one uniform P1 pointer and three exact cached P0 bytes.
#
# A rolling planner chooses one of three starts in a single known packed row:
# 0, 2, or 4.  P1 is guaranteed uniform for one of those three-pair windows,
# so one branchless service pointer supplies either its three graphics bytes or
# a three-byte ROM zero run.  P0 need not be uniform: before the window the
# planner computes its three exact graphics bytes (active byte or zero) into
# scratch-lane bytes that are dead during visible drawing.
#
# The service keeps local Y=2,1,0 across both scanlines of each pair.  P1 PF
# stores use A rather than Y so they do not destroy that local index.  X carries
# PF bytes 0/2/4 across the P0 scanline.  The P0 tail commits X, loads the exact
# cached P0 byte in three cycles, shifts the direct known-row M0 mask, and uses
# the remaining budget either to copy one next color plus DEY or to restore X
# and jump through the rolling resume vector on the last pair.
#
# The first LDY #2 occupies the service body's normal two-cycle entry idle.
# The DEY in pair 0/1 occupies the next pair's two-cycle entry idle, so the
# maintained PF and object write phases do not move.

use strict;
use warnings;

my @ops;
my $PAIR=152;

for my $p (0..2) {
   my $b=$p*$PAIR;
   my $even=2*$p;
   my $odd=$even+1;

   my @entry = $p==0 ? (['ldy #2',2]) : ();
   push @ops, {
      id=>"p${p}_p1_line", earliest=>$b, latest_end=>$b+60,
      after=>$p ? ["p".($p-1)."_p0_tail"] : [],
      description=>"pair $p P1 scanline preserves local service Y and uses direct known-row Ball shift",
      asm=>[
         @entry,
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ["lsr.z object_masks_service_ball_$p",5],
         ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
         ['dec.z player1_y',5], ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ],
      events=>[
         {name=>'PF0L',offset=>13+($p==0?2:0),windows=>[[$b+15,$b+15]]},
         {name=>'PF1L',offset=>19+($p==0?2:0),windows=>[[$b+21,$b+21]]},
         {name=>'PF2L',offset=>25+($p==0?2:0),windows=>[[$b+27,$b+27]]},
         {name=>'PF0R',offset=>46+($p==0?2:0),windows=>[[$b+48,$b+48]]},
         {name=>'PF1R',offset=>52+($p==0?2:0),windows=>[[$b+54,$b+54]]},
         {name=>'PF2R',offset=>58+($p==0?2:0),windows=>[[$b+60,$b+60]]},
      ],
   };

   push @ops, {
      id=>"p${p}_p1_service", earliest=>$b+61, latest_end=>$b+79,
      after=>["p${p}_p1_line"],
      description=>"pair $p branchless uniform P1 pointer load carrying PF byte $even in X",
      asm=>[
         ['lda.iy (p1_service_ptr),y',5],
         ["ldx.a next_stripe_pf+$even",4],
         ["lsr.z object_masks_service_m1_$p",5],
         ['sta GRP1',3],
      ],
      events=>[{name=>'GRP1',offset=>16,windows=>[[$b+77,$b+77]]}],
   };

   push @ops, {
      id=>"p${p}_p0_line", earliest=>$b+80, latest_end=>$b+132,
      after=>["p${p}_p1_service"],
      description=>"pair $p P0 scanline stages PF byte $odd while Y keeps the local service index",
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
         ["stx.a next_color_slot+$p",4],
         ['dey',2];
   } else {
      push @tail_extra,
         ['ldx.z service_resume_x',3],
         ['jmp (service_resume_ptr)',5];
   }

   push @ops, {
      id=>"p${p}_p0_tail", earliest=>$b+133, latest_end=>$b+153,
      after=>["p${p}_p0_line"],
      description=>"pair $p commits PF byte $even, loads exact cached P0, then advances rolling state",
      asm=>[
         ["stx.z inactive_pf+$even",3],
         ["lda.z p0_service_byte+$p",3],
         ["lsr.z object_masks_service_m0_$p",5],
         @tail_extra,
      ],
   };
}

return {
   name=>'all_five P1-uniform/P0-cache three-pair service',
   description=>'One uniform P1 pointer plus three exact cached P0 bytes refill six PF bytes and both colors in one fixed packed row.',
   line_cycles=>76,
   horizon=>458,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
