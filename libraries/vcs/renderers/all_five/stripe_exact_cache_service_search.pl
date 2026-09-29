# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Six-line refill with exact P1 and P0 bytes staged in beam-dead scratch.
#
# A fixed three-pair service window needs no uniform-player selector.  VBLANK
# computes the exact visible byte (graphics or zero) for both players at each
# of the three service pairs.  Those six bytes live in storage that already
# exists: scratch-lane bytes and reclaimed rolling-service state.  The hot
# service therefore has no height test, no sprite pointer, and no candidate
# dispatch.  It still refills all six inactive PF bytes plus both colors in
# the same three-pair cadence as the proven P1-pointer/P0-cache service.

use strict;
use warnings;

my @ops;
my $PAIR=152;

for my $p (0..2) {
   my $b=$p*$PAIR;
   my $even=2*$p;
   my $odd=$even+1;
   my @entry=$p==0 ? (['nop',2]) : ();

   push @ops, {
      id=>"p${p}_p1_line", earliest=>$b, latest_end=>$b+60,
      after=>$p ? ["p".($p-1)."_p0_tail"] : [],
      description=>"pair $p P1 line with direct known-row Ball shift",
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
      description=>"pair $p exact cached P1 byte carrying PF byte $even in X",
      asm=>[
         ["lda.z p1_service_byte+$p",3],
         ['nop',2], ['nop',2],
         ["ldx.a next_stripe_pf+$even",4],
         ["lsr.z object_masks_service_m1_$p",5],
         ['sta GRP1',3],
      ],
      events=>[{name=>'GRP1',offset=>16,windows=>[[$b+77,$b+77]]}],
   };

   push @ops, {
      id=>"p${p}_p0_line", earliest=>$b+80, latest_end=>$b+132,
      after=>["p${p}_p1_service"],
      description=>"pair $p P0 line stages PF byte $odd",
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
         ['nop',2];
   } else {
      push @tail_extra,
         ['ldx.z service_resume_x',3],
         ['jmp (service_resume_ptr)',5];
   }

   push @ops, {
      id=>"p${p}_p0_tail", earliest=>$b+133, latest_end=>$b+153,
      after=>["p${p}_p0_line"],
      description=>"pair $p commits PF byte $even and exact cached P0",
      asm=>[
         ["stx.z inactive_pf+$even",3],
         ["lda.z p0_service_byte+$p",3],
         ["lsr.z object_masks_service_m0_$p",5],
         @tail_extra,
      ],
   };
}

return {
   name=>'all_five exact-cache fixed three-pair service',
   description=>'Six exact staged sprite bytes remove uniform-window planning while preserving the proven six-line refill cadence.',
   line_cycles=>76,
   horizon=>458,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
