# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Zero-cadence-cost candidate dispatch for the dual-uniform service window.
#
# A planner supplies X = one chosen start from 1,3,5,9,11.  In the
# two known packed rows around the rolling-service region the mask shifts can
# use direct addresses instead of the ordinary six-cycle indexed form.  On a
# candidate pair, direct Ball/M1/M0 shifts and the removed pair-tail NOP fund
# the selector.  The non-selected path is exactly the old 20-cycle mask/tail
# budget.  The selected path deliberately lasts 22 cycles: its final JMP to
# the one shared service body consumes the two idle cycles that body otherwise
# needs at the start of its first pair.  Thus the first service STA GRP0 still
# begins at pair cycle 2, without any branch-range assumption or duplicated
# service body.
#
# BNE targets only the immediately following non-selected continuation.  The
# far transfer is an unconditional JMP, so candidate-to-service distance does
# not constrain the layout.

use strict;
use warnings;

return {
   name=>'all_five dual-uniform shared-service candidate dispatch tail',
   description=>'Non-selected path is the old 20-cycle budget; selected path spends the service body initial two idle cycles on a far JMP.',
   line_cycles=>76,
   horizon=>22,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
   ],
   operations=>[
      {
         id=>'candidate_tail', earliest=>0, latest_end=>21,
         description=>'local conditional plus range-free JMP to one shared service body',
         implementations=>[
            {
               name=>'selected',
               asm=>[
                  ['lsr.z object_masks_service_ball',5],
                  ['lsr.z object_masks_service_m1',5],
                  ['cpx #candidate_start',2],
                  ['bne.same not_selected ; not taken',2],
                  ['lsr.z object_masks_service_m0',5],
                  ['jmp shared_service',3],
               ],
            },
            {
               name=>'not_selected',
               asm=>[
                  ['lsr.z object_masks_service_ball',5],
                  ['lsr.z object_masks_service_m1',5],
                  ['cpx #candidate_start',2],
                  ['bne.same not_selected ; taken',3],
                  ['lsr.z object_masks_service_m0',5],
               ],
            },
         ],
      },
   ],
};
