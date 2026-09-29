# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Zero-tax gate for one fixed rolling-service row before the first stripe
# boundary.
#
# The ordinary A-side row-offset seed is $e8 and advances by four per packed
# row.  Rebase it to $6c and add $7c to every indexed mask operand: modulo 256,
# every effective mask address is unchanged.  Row-end X values are then
# $70,$74,$78,$7c,$80,$84.  The first four are positive ordinary rows; $80 is
# the one service-row entrance and $84 is the following boundary-row entrance.
#
# Ordinary rows replace INX/BEQ/JMP with INX/BEQ/BPL for the same seven-cycle
# tail.  Both negative special entrances fall through one cycle earlier, but
# an absolute STA GRP0 costs four cycles instead of the ordinary three.  Thus
# the first object commit remains at the identical ten-cycle offset on normal,
# service, and boundary paths.  The two special values can be distinguished
# later with CPX #$84 after the common left-PF writes, where the comparison no
# longer perturbs their established phases.

use strict;
use warnings;

my $old_seed=0xe8;
my $new_seed=0x6c;
my $operand_delta=0x7c;
for my $row (0..5) {
   my $old=($old_seed+4*$row)&255;
   my $new=($new_seed+4*$row)&255;
   (($new+$operand_delta)&255)==$old
      or die "row $row mask rebase mismatch\n";
   # Verify the identity for every possible zero-page operand, not merely the
   # current renderer constants.
   for my $op (0..255) {
      (($op+$old)&255)==((($op+$operand_delta)&255)+$new)%256
         or die "row $row operand $op rebase mismatch\n";
   }
}
my @ends=map { ($new_seed+4*($_+1))&255 } 0..5;
for my $row (0..3) {
   ($ends[$row]&0x80)==0 && $ends[$row]!=0
      or die "ordinary row $row no longer takes BPL gate\n";
}
$ends[4]==0x80 or die "service-row sentinel is not \$80\n";
$ends[5]==0x84 or die "boundary-row sentinel is not \$84\n";

return {
   name=>'all_five P1-cache fixed service-row gate',
   description=>'A-side X rebasing makes ordinary rows branch through unchanged while service and boundary entrances share an absolute GRP0 compensation.',
   line_cycles=>76,
   horizon=>10,
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
                  ['beq.same boundary ; not taken',2],
                  ['bpl.same transition ; taken',3],
                  ['sta GRP0',3],
               ],
            },
            {
               name=>'gated_service',
               asm=>[
                  ['inx ; X=$80',2],
                  ['beq.same boundary ; not taken',2],
                  ['bpl.same transition ; not taken',2],
                  ['sta.a GRP0',4],
               ],
            },
            {
               name=>'gated_boundary',
               asm=>[
                  ['inx ; X=$84',2],
                  ['beq.same boundary ; not taken',2],
                  ['bpl.same transition ; not taken',2],
                  ['sta.a GRP0',4],
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
   ],
};
