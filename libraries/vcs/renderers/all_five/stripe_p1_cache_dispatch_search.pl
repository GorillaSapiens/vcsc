# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Zero-cadence-cost dispatch for the single-row P1-uniform/P0-cache service.
#
# The planner chooses one of starts 0,2,4.  The entire known packed row uses
# direct Ball/M1/M0 mask shifts, so X is irrelevant until the shared service
# restores the generic row offset at its dynamic resume.
#
# Candidate 0 replaces the preceding row's ordinary pair-7 mask/backedge
# envelope (three indexed shifts + INX + untaken BEQ + JMP = 25 cycles) with
# three direct shifts, five cycles of inert fill, and JMP (candidate0_ptr).
# Candidate 2 replaces pair 1's three indexed shifts + NOP (20 cycles) with
# three direct shifts + JMP (candidate2_ptr).  If neither pointer selects the
# service, start 4 is the guaranteed fallback: pair 3 replaces its indexed
# shifts + INX with direct shifts + NOP + an absolute JMP to the shared body.

use strict;
use warnings;

return {
   name=>'all_five P1-cache three-candidate dispatch',
   description=>'Starts 0,2 use temporary indirect pointers and start 4 is an unconditional fallback; every predecessor keeps its original cadence.',
   line_cycles=>76,
   horizon=>65,
   idle_fillers=>[{text=>'nop',cycles=>2}],
   operations=>[
      {
         id=>'candidate0_tail', earliest=>0, latest_end=>24,
         description=>'row-backedge candidate 0: exact old 25-cycle mask/control envelope',
         asm=>[
            ['lsr.z service_row_ball',5],
            ['lsr.z service_row_m1',5],
            ['lsr.z service_row_m0',5],
            ['bit.z timing_scratch',3],
            ['nop',2],
            ['jmp (candidate0_ptr)',5],
         ],
      },
      {
         id=>'candidate2_tail', earliest=>25, latest_end=>44,
         after=>['candidate0_tail'],
         description=>'pair-1 candidate 2: direct masks fund the indirect jump exactly',
         asm=>[
            ['lsr.z service_row_ball',5],
            ['lsr.z service_row_m1',5],
            ['lsr.z service_row_m0',5],
            ['jmp (candidate2_ptr)',5],
         ],
      },
      {
         id=>'candidate4_tail', earliest=>45, latest_end=>64,
         after=>['candidate2_tail'],
         description=>'pair-3 fallback 4: omitted INX plus direct masks fund NOP/JMP exactly',
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
