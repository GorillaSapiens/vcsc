# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Four-line PF-only refill with one uniform P1 pointer and two exact P0 bytes.
#
# A rolling planner chooses a two-pair window late in one packed row. P1 is
# uniform across the window, while P0 may be arbitrary because its two exact
# graphics bytes are cached before entry. Each pair stages three next-stripe
# PF bytes: X carries the first across the P0 scanline, the P0 line stages the
# second directly, and the tail uses the former color-copy slot for the third.
# Colors are deliberately outside this proof.

use strict;
use warnings;

my @ops;
my $PAIR=152;

for my $p (0..1) {
   my $b=$p*$PAIR;
   my $pf=3*$p;

   my @entry = $p==0 ? (['ldy #2',2]) : ();
   push @ops, {
      id=>"p${p}_p1_line", earliest=>$b, latest_end=>$b+60,
      after=>$p ? ["p".($p-1)."_p0_tail"] : [],
      description=>"pair $p P1 scanline preserves local service Y",
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
      description=>"pair $p branchless uniform P1 pointer load carries PF byte $pf in X",
      asm=>[
         ['lda.iy (p1_service_ptr),y',5],
         ["ldx.a next_stripe_pf+$pf",4],
         ["lsr.z object_masks_service_m1_$p",5],
         ['sta GRP1',3],
      ],
      events=>[{name=>'GRP1',offset=>16,windows=>[[$b+77,$b+77]]}],
   };

   push @ops, {
      id=>"p${p}_p0_line", earliest=>$b+80, latest_end=>$b+132,
      after=>["p${p}_p1_service"],
      description=>"pair $p P0 scanline stages PF byte ".($pf+1),
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['dec.z player0_y',5],
         ["lda.a next_stripe_pf+".($pf+1),4], ["sta.z inactive_pf+".($pf+1),3],
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

   my @tail = (
      ["stx.z inactive_pf+$pf",3],
      ["lda.z p0_service_byte+$p",3],
   );
   push @tail, ['dey',2] if $p==0;
   push @tail,
      ["lsr.z object_masks_service_m0_$p",5],
      ["ldx.a next_stripe_pf+".($pf+2),4],
      ["stx.a inactive_pf+".($pf+2),4];
   push @tail, ['ldx #normal_x',2] if $p==1;

   push @ops, {
      id=>"p${p}_p0_tail", earliest=>$b+133, latest_end=>$b+153,
      after=>["p${p}_p0_line"],
      description=>"pair $p commits carried PF byte, exact P0, and third PF byte",
      asm=>\@tail,
   };
}

return {
   name=>'all_five P1-uniform/P0-cache two-pair PF-only service',
   description=>'One uniform P1 pointer plus two exact P0 bytes refill all six PF bytes in four scanlines; color preparation is intentionally separate.',
   line_cycles=>76,
   horizon=>306,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
