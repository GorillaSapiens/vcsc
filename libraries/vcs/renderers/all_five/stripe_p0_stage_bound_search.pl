# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Lower-bound model for the remaining rolling-refill bottleneck.
#
# Start at the ordinary P0 scanline entry (absolute pair cycle 85).  Keep all
# six currently certified PF write phases.  After the PF/object body, stage one
# ROM byte into the inactive PF buffer, dynamically compute the P0 byte needed
# by the following pair, and perform the mask shift.  A must finish holding that
# P0 byte, therefore the staging copy must precede the graphics lookup.
#
# The best current official-opcode spelling ends at absolute cycle 158.  The
# maintained pair cadence ends at 153, so this is a concrete five-cycle deficit.
# This fixture exists to make future instruction rearrangements beat a measured
# target rather than an informal timing estimate.

use strict;
use warnings;

return {
   name=>'all_five P0 rolling-refill five-cycle bound',
   description=>'Exact P0 PF phases plus one staged PF byte and a fully dynamic next-pair P0 lookup. Current shape ends five cycles beyond the 152-cycle pair cadence.',
   line_cycles=>76,
   horizon=>159,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>[
      {
         id=>'line1_pf', earliest=>85, latest_end=>137,
         description=>'current P0 scanline PF/object body with certified phases',
         asm=>[
            ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
            ['lda.z stripe_cache+1',3], ['sta PF1',3],
            ['lda.z stripe_cache+2',3], ['sta PF2',3],
            ['ldy.z player0_y',3], ['dey',2], ['cpy.z object_masks+11',3], ['sty.z player0_y',3],
            ['lda.z stripe_cache+3',3], ['sta.a PF0',4],
            ['lda.z stripe_cache+4',3], ['sta PF1',3],
            ['lda.z stripe_cache+5',3], ['sta PF2',3],
         ],
         events=>[
            {name=>'PF0L',offset=>10,windows=>[[95,95]]},
            {name=>'PF1L',offset=>16,windows=>[[101,101]]},
            {name=>'PF2L',offset=>22,windows=>[[107,107]]},
            {name=>'PF0R',offset=>40,windows=>[[125,125]]},
            {name=>'PF1R',offset=>46,windows=>[[131,131]]},
            {name=>'PF2R',offset=>52,windows=>[[137,137]]},
         ],
      },
      {
         id=>'stage', after=>['line1_pf'], latest_end=>144,
         description=>'copy one next-stripe PF byte while A may still be clobbered',
         asm=>[
            ['lda.a next_stripe_pf',4],
            ['sta.z inactive_pf',3],
         ],
      },
      {
         id=>'next_grp0', after=>['stage'], latest_end=>152,
         description=>'dynamic next-pair P0 selection; leaves sprite byte in A',
         asm=>[
            ['bcc.same activeP0',3],
            ['lda.iy (player0_graphics),y',5],
         ],
      },
      {
         id=>'mask_shift', after=>['next_grp0'], latest_end=>158,
         description=>'finish pair while preserving A for next pair GRP0 commit',
         asm=>[
            ['lsr.zx object_masks+26,x',6],
         ],
      },
   ],
};
