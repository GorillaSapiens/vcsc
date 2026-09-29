# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Zero-tax gate for one fixed rolling-service row before the first stripe
# boundary.
#
# Rebase the A-side row-offset seed from $e8 to $ec and subtract four from each
# indexed mask operand. Effective zero-page mask addresses are therefore
# unchanged. Row-end X values become $f0,$f4,$f8,$fc,$00,$04: four ordinary
# rows remain negative, the service entrance is zero, and the following stripe
# boundary is small positive.
#
# Pair 7 can replace INX/BEQ/JMP with INX/BPL/JMP. Ordinary negative rows keep
# the exact old seven-cycle backedge. Service/boundary take BPL to a nearby
# prefix two cycles earlier than the JMP; one NOP restores those two cycles, so
# STA GRP0 remains at the old phase. INX supplied Z=1 only for the service
# sentinel $00. NOP and STA do not alter flags, so the special continuation can
# distinguish service from boundary after that first phase-critical commit
# without a CPX.

use strict;
use warnings;

my $old_seed=0xe8;
my $new_seed=0xec;
my $operand_delta=-4;
for my $row (0..5) {
   my $old=($old_seed+4*$row)&255;
   my $new=($new_seed+4*$row)&255;
   (($new+$operand_delta)&255)==$old
      or die "row $row mask rebase mismatch\n";
   for my $op (0..255) {
      (($op+$old)&255)==((($op+$operand_delta)&255)+$new)%256
         or die "row $row operand $op rebase mismatch\n";
   }
}
my @ends=map { ($new_seed+4*($_+1))&255 } 0..5;
for my $row (0..3) {
   ($ends[$row]&0x80)!=0
      or die "ordinary row $row no longer stays negative\n";
}
$ends[4]==0x00 or die "service-row sentinel is not \$00\n";
$ends[5]==0x04 or die "boundary-row sentinel is not \$04\n";

return {
   name=>'all_five P1-cache fixed service-row gate',
   description=>'X=$ec and mask operands -4 preserve ordinary effective addresses; BPL gates only $00/$04 through a nearby NOP-compensated prefix while retaining Z for service-vs-boundary dispatch.',
   line_cycles=>76,
   horizon=>12,
   operations=>[
      {
         id=>'row_gate', earliest=>0, latest_end=>9,
         implementations=>[
            {
               name=>'old_normal_reference',
               asm=>[
                  ['inx',2],
                  ['beq.same boundary ; not taken',2],
                  ['jmp transition',3],
                  ['sta GRP0',3],
               ],
            },
            {
               name=>'gated_normal',
               asm=>[
                  ['inx',2],
                  ['bpl.same nearby_special ; not taken',2],
                  ['jmp transition',3],
                  ['sta GRP0',3],
               ],
            },
            {
               name=>'gated_service',
               asm=>[
                  ['inx ; X=$00 Z=1',2],
                  ['bpl.same nearby_special ; taken',3],
                  ['nop ; compensate skipped JMP',2],
                  ['sta GRP0 ; Z remains 1',3],
               ],
            },
            {
               name=>'gated_boundary',
               asm=>[
                  ['inx ; X=$04 Z=0',2],
                  ['bpl.same nearby_special ; taken',3],
                  ['nop ; compensate skipped JMP',2],
                  ['sta GRP0 ; Z remains 0',3],
               ],
            },
            {
               name=>'old_boundary_reference',
               asm=>[
                  ['inx',2],
                  ['beq.same boundary ; taken',3],
                  ['ldx #$e8',2],
                  ['sta GRP0',3],
               ],
            },
         ],
      },
      {
         id=>'special_discriminator', earliest=>10, latest_end=>11,
         after=>['row_gate'],
         description=>'Z from INX survives NOP/STA, so BEQ can identify only the $00 service sentinel',
         asm=>[['beq.same service ; taken only for X=$00',2]],
      },
   ],
};
