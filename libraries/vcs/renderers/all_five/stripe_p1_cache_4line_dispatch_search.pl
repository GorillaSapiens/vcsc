# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Zero-cadence-cost late dispatch for the four-line PF-only service.
#
# The planner chooses start 4, 5, or 6 in one known eight-pair row. Candidate
# 4 is dispatched from pair 3 and candidate 5 from pair 4 using temporary
# vectors in the inactive PF buffer. If neither selects service, pair 5 falls
# through to the guaranteed start-6 service. Direct Ball/M1/M0 mask shifts
# save one cycle apiece versus indexed shifts: three direct shifts plus a
# five-cycle indirect JMP exactly replace the ordinary 20-cycle mask/NOP tail.
# The start-6 fallback uses a two-cycle NOP plus an absolute JMP for the same
# exact budget.

use strict;
use warnings;

return {
   name=>'all_five P1-cache four-line late dispatch',
   description=>'Starts 4 and 5 use inactive-buffer vectors and start 6 is an unconditional fallback; all predecessor tails remain 20 cycles.',
   line_cycles=>76,
   horizon=>60,
   idle_fillers=>[{text=>'nop',cycles=>2}],
   operations=>[
      {
         id=>'candidate4_tail', earliest=>0, latest_end=>19,
         description=>'pair-3 candidate 4: direct masks fund the indirect jump exactly',
         asm=>[
            ['lsr.z service_row_ball',5],
            ['lsr.z service_row_m1',5],
            ['lsr.z service_row_m0',5],
            ['jmp (candidate4_ptr)',5],
         ],
      },
      {
         id=>'candidate5_tail', earliest=>20, latest_end=>39,
         after=>['candidate4_tail'],
         description=>'pair-4 candidate 5: second inactive-buffer vector has the same exact budget',
         asm=>[
            ['lsr.z service_row_ball',5],
            ['lsr.z service_row_m1',5],
            ['lsr.z service_row_m0',5],
            ['jmp (candidate5_ptr)',5],
         ],
      },
      {
         id=>'candidate6_tail', earliest=>40, latest_end=>59,
         after=>['candidate5_tail'],
         description=>'pair-5 fallback 6: direct masks plus NOP and absolute JMP stay at 20 cycles',
         asm=>[
            ['lsr.z service_row_ball',5],
            ['lsr.z service_row_m1',5],
            ['lsr.z service_row_m0',5],
            ['nop',2],
            ['jmp shared_service',3],
         ],
      },
   ],
};
