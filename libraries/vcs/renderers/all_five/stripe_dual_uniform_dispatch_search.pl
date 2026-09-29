# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Zero-cadence-cost candidate dispatch for the dual-uniform service window.
#
# A planner supplies X = one chosen start from 1,3,5,9,11.  In the
# two known packed rows around the rolling-service region the mask shifts can
# use direct addresses instead of the ordinary six-cycle indexed form.  On a
# candidate pair, spend those recovered cycles on CPX/BEQ and remove the usual
# two-cycle pair-tail NOP.  The selected path uses a five-cycle zero-page M0
# shift; the non-selected path uses a deliberately six-cycle absolute shift.
# Both paths are therefore exactly 20 cycles, the same cost as the ordinary
# three indexed mask shifts plus tail NOP (6+6+6+2).
#
# The branch must run in the P0 tail of the pair immediately before the chosen
# three-pair service window, so a taken branch can enter that window without a
# per-pair countdown or a stripe-count-sized dispatch cache.

use strict;
use warnings;

return {
   name=>'all_five dual-uniform candidate dispatch tail',
   description=>'Candidate and non-candidate paths both replace the ordinary 20-cycle mask/tail budget exactly.',
   line_cycles=>76,
   horizon=>20,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
   ],
   operations=>[
      {
         id=>'candidate_tail', earliest=>0, latest_end=>19,
         description=>'zero-tax candidate test using direct/absolute M0 shift balance',
         implementations=>[
            {
               name=>'selected',
               asm=>[
                  ['lsr.z object_masks_service_ball',5],
                  ['lsr.z object_masks_service_m1',5],
                  ['cpx #candidate_start',2],
                  ['beq.same service_entry',3],
                  ['lsr.z object_masks_service_m0',5],
               ],
            },
            {
               name=>'not_selected',
               asm=>[
                  ['lsr.z object_masks_service_ball',5],
                  ['lsr.z object_masks_service_m1',5],
                  ['cpx #candidate_start',2],
                  ['beq.same service_entry',2],
                  ['lsr.a object_masks_service_m0',6],
               ],
            },
         ],
      },
   ],
};
