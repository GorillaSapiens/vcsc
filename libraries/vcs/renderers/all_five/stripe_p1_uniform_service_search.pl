# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# P1 service-pair timing when the three-pair window has one known activity mode.
#
# The rolling planner may choose a three-pair window where P1 is known active on
# all three pairs or inactive on all three pairs.  With the mode known once for
# the window, each service pair avoids the per-pair height compare/branch.
# Direct addressing of the known Ball/mask row recovers a cycle; the active path
# spends that cycle deliberately with an absolute GRP1 store, while the inactive
# path uses real 2/3-cycle fillers.  Both implementations therefore finish at
# the ordinary GRP1 phase and leave the following P0 scanline unchanged.

use strict;
use warnings;

my $line0=[
   ['sta GRP0',3],
   ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
   ['ldy.z stripe_cache+1',3], ['sty PF1',3],
   ['ldy.z stripe_cache+2',3], ['sty PF2',3],
   # Service window is unrolled at a known mask row: direct shift is 5 cycles.
   ['lsr.z object_masks_service_ball',5],
   ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
   ['dec.z player1_y',5], ['sta PF0',3],
   ['ldy.z stripe_cache+4',3], ['sty PF1',3],
   ['ldy.z stripe_cache+5',3], ['sty PF2',3],
];

return {
   name=>'all_five uniform-P1 service pair',
   description=>'Known-active and known-inactive P1 service bodies both stage one PF byte and retain the ordinary following-line phase.',
   line_cycles=>76,
   horizon=>85,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>[
      {
         id=>'line0_pf', earliest=>2, latest_end=>60,
         description=>'P1 scanline PF/object body with direct service-row Ball mask shift',
         asm=>$line0,
         events=>[
            {name=>'PF0L',offset=>13,windows=>[[15,15]]},
            {name=>'PF1L',offset=>19,windows=>[[21,21]]},
            {name=>'PF2L',offset=>25,windows=>[[27,27]]},
            # direct mask shift advances the right half one cycle
            {name=>'PF0R',offset=>46,windows=>[[48,48]]},
            {name=>'PF1R',offset=>52,windows=>[[54,54]]},
            {name=>'PF2R',offset=>58,windows=>[[60,60]]},
         ],
      },
      {
         id=>'p1_service', after=>['line0_pf'], earliest=>61, latest_end=>84,
         description=>'stage one raw next-stripe PF byte while producing a known-mode P1 sprite',
         implementations=>[
            {
               name=>'known_active',
               asm=>[
                  ['ldy.z player1_y',3],
                  ['lda.iy (player1_graphics),y',5],
                  ['ldy.a next_stripe_pf',4], ['sty.z inactive_pf',3],
                  ['lsr.z object_masks_service_p1',5],
                  # Absolute addressing is intentionally one cycle slower here.
                  ['sta.a GRP1',4],
               ],
               events=>[{name=>'GRP1',offset=>23,windows=>[[84,84]]}],
            },
            {
               name=>'known_inactive',
               asm=>[
                  ['lda #0',2],
                  ['ldy.a next_stripe_pf',4], ['sty.z inactive_pf',3],
                  ['lsr.z object_masks_service_p1',5],
                  ['sta GRP1',3],
                  ['nop.z timing_scratch',3], ['nop',2], ['nop',2],
               ],
               events=>[{name=>'GRP1',offset=>16,windows=>[[77,77]]}],
            },
         ],
      },
   ],
};
