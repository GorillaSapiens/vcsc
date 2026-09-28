# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exact P0-side rolling service schedule for the six-line refill window.
#
# The executable refill probe has already measured/certified the temporary PF
# phase family: the first P0 service line is two cycles earlier than ordinary;
# the next two P0 service lines are four cycles earlier.  This input spends that
# measured phase advance instead of pretending every line has ordinary timing.
#
# Result:
#   * pair 0 uses one precomputed GRP0 seed, stages one PF byte, and has room for
#     a real three-cycle filler;
#   * pairs 1 and 2 stage one PF byte and dynamically produce the following
#     pair's GRP0 byte in the same cadence;
#   * direct zero-page mask shifts save the final cycle because these three
#     service pairs are unrolled at known mask offsets.
#
# Thus the P0 side does NOT require three precomputed service bytes.  It needs
# one seed at service-window entry and can roll itself thereafter.

use strict;
use warnings;

my @ops;
my $PAIR=152;
my @p0_byte=(1,2,5); # raw bytes only; PF0L/PF0R are staged on P1 scanlines

for my $p (0..2) {
   my $b=$p*$PAIR;
   my $advance=$p==0 ? 2 : 4;
   my $start=$b+85-$advance;
   my $end=$start+52; # 53-cycle ordinary line1 body, absolute PF0R retained
   my @events=(
      {name=>'PF0L',offset=>10,windows=>[[$b+95-$advance,$b+95-$advance]]},
      {name=>'PF1L',offset=>16,windows=>[[$b+101-$advance,$b+101-$advance]]},
      {name=>'PF2L',offset=>22,windows=>[[$b+107-$advance,$b+107-$advance]]},
      {name=>'PF0R',offset=>40,windows=>[[$b+125-$advance,$b+125-$advance]]},
      {name=>'PF1R',offset=>46,windows=>[[$b+131-$advance,$b+131-$advance]]},
      {name=>'PF2R',offset=>52,windows=>[[$b+137-$advance,$b+137-$advance]]},
   );
   push @ops, {
      id=>"p${p}_line1", earliest=>$start, latest_end=>$end,
      description=>"service pair $p P0 scanline at certified -$advance-cycle PF phase",
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['ldy.z player0_y',3], ['dey',2], ['cpy.z object_masks+11',3], ['sty.z player0_y',3],
         ['lda.z stripe_cache+3',3], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ],
      events=>\@events,
      after=>$p ? ["p".($p-1)."_tail"] : [],
   };
   if ($p==0) {
      push @ops, {
         id=>'p0_tail', after=>['p0_line1'], earliest=>$end+1, latest_end=>$b+153,
         description=>'stage odd PF byte, load one precomputed GRP0 seed, direct mask shift, and spend the remaining real 3-cycle filler',
         asm=>[
            ['lda.a next_stripe_pf+'.$p0_byte[0],4], ['sta.z inactive_pf+'.$p0_byte[0],3],
            ['lda.z service_grp0_seed',3],
            ['lsr.z object_masks_service_p0_0',5],
            ['nop.z timing_scratch',3],
         ],
      };
   } else {
      my $byte=$p0_byte[$p];
      push @ops, {
         id=>"p${p}_tail", after=>["p${p}_line1"], earliest=>$end+1, latest_end=>$b+153,
         description=>"stage odd PF byte $byte, dynamically produce next GRP0, and direct-shift the known service mask byte",
         asm=>[
            ["lda.a next_stripe_pf+$byte",4], ["sta.z inactive_pf+$byte",3],
            ['bcc.same activeP0',3], ['lda.iy (player0_graphics),y',5],
            ["lsr.z object_masks_service_p0_$p",5],
         ],
      };
   }
}

return {
   name=>'all_five P0 three-pair rolling service phase',
   description=>'Measured -2/-4/-4 service phases reduce the P0 rolling producer to one seed byte; later service pairs dynamically chain GRP0 while staging PF data.',
   line_cycles=>76,
   horizon=>458,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
