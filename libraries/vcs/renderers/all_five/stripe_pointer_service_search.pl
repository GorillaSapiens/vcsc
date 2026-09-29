# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exact six-line refill using P1 pointers in the inactive PF buffer.
#
# Before the service window, each two-byte inactive-buffer slot is an exact P1
# sprite pointer. Active P1 slots point directly at the required graphics byte;
# inactive slots point at the permanent zero byte. Each pair consumes one
# pointer and overwrites those two bytes with the next stripe's PF payload.
#
# X remains the known packed-row seed ($e8) throughout all three pairs. An
# indexed-indirect LDA uses a pair-specific zero-page operand so (operand,X)
# lands on B+0/B+2/B+4 without changing X. Y carries PF bytes 0/2/4 into the
# following P0 scanline. Removing pointer metadata saves the three-cycle BIT;
# those cycles pay the normal live P0 height CPY on the next line. Carry then
# survives the PF loads/stores and selects an equal eight-cycle active/inactive
# P0 tail. Thus P0 needs no preclassification at all.
#
# The P0 pattern below only chooses which equal-time branch outcome the solver
# certifies for each pair; it is not stored or consulted by emitted code. The
# remaining producer problem is generating three exact P1 pointers before this
# window without extra RAM.

use strict;
use warnings;

sub pattern {
   my $s=defined($ENV{VCSC_P0_PATTERN}) ? $ENV{VCSC_P0_PATTERN} : '0';
   $s =~ /\A(?:0x)?([0-7])\z/i or die "VCSC_P0_PATTERN must be 0..7\n";
   return hex($1);
}

my $p0pat=pattern();
my @ops;
my $PAIR=152;
my $XSEED=0xe8;

for my $p (0..2) {
   my $b=$p*$PAIR;
   my $even=2*$p;
   my $odd=$even+1;

   push @ops, {
      id=>"p${p}_p1_line", earliest=>$b+2, latest_end=>$b+60,
      after=>$p ? ["p".($p-1)."_p0_tail"] : [],
      description=>"pair $p P1 scanline with direct known-row Ball shift",
      asm=>[
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['ldy.z stripe_cache+1',3], ['sty PF1',3],
         ['ldy.z stripe_cache+2',3], ['sty PF2',3],
         ["lsr.z object_masks_service_ball_$p",5],
         ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
         ['dec.z player1_y',5], ['sta PF0',3],
         ['ldy.z stripe_cache+4',3], ['sty PF1',3],
         ['ldy.z stripe_cache+5',3], ['sty PF2',3],
      ],
      events=>[
         {name=>'PF0L',offset=>13,windows=>[[$b+15,$b+15]]},
         {name=>'PF1L',offset=>19,windows=>[[$b+21,$b+21]]},
         {name=>'PF2L',offset=>25,windows=>[[$b+27,$b+27]]},
         {name=>'PF0R',offset=>46,windows=>[[$b+48,$b+48]]},
         {name=>'PF1R',offset=>52,windows=>[[$b+54,$b+54]]},
         {name=>'PF2R',offset=>58,windows=>[[$b+60,$b+60]]},
      ],
   };

   # X remains $e8. Adding $18 to the operand cancels that index modulo 256;
   # the pair offset then selects B+0, B+2, or B+4.
   push @ops, {
      id=>"p${p}_p1_service", earliest=>$b+61, latest_end=>$b+86,
      after=>["p${p}_p1_line"],
      description=>"pair $p load exact P1 pointer, carry PF byte $even in Y, and materialize M1",
      asm=>[
         [sprintf('lda.ix (inactive_pf+$18+%u,x) ; X=$%02x -> inactive_pf+%u',$even,$XSEED,$even),6],
         ["ldy.a next_stripe_pf+$even",4],
         ["lsr.z object_masks_service_m1_$p",5],
         ['sta GRP1',3],
         ['lda.z stripe_cache+0',3], ['adc #1',2], ['sta ENAM1',3],
      ],
      events=>[{name=>'GRP1',offset=>17,windows=>[[$b+78,$b+78]]}],
   };

   push @ops, {
      id=>"p${p}_p0_line", earliest=>$b+87, latest_end=>$b+140,
      after=>["p${p}_p1_service"],
      description=>"pair $p P0 scanline overwrites consumed pointer with PF bytes and live-classifies P0 in carry",
      asm=>[
         ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ["sty.z inactive_pf+$even",3],
         ['ldy.z player0_y',3], ['dey',2], ['cpy.z player0_height',3], ['sty.z player0_y',3],
         ["lda.a next_stripe_pf+$odd",4], ["sta.z inactive_pf+$odd",3],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ],
      events=>[
         {name=>'PF0L',offset=>2,windows=>[[$b+89,$b+89]]},
         {name=>'PF1L',offset=>8,windows=>[[$b+95,$b+95]]},
         {name=>'PF2L',offset=>14,windows=>[[$b+101,$b+101]]},
         {name=>'PF0R',offset=>41,windows=>[[$b+128,$b+128]]},
         {name=>'PF1R',offset=>47,windows=>[[$b+134,$b+134]]},
         {name=>'PF2R',offset=>53,windows=>[[$b+140,$b+140]]},
      ],
   };

   my $p0active=($p0pat >> $p) & 1;
   my $p0select=$p0active
      ? [
           ['bcc.same activeP0',3],
           ['lda.iy (player0_graphics),y',5],
        ]
      : [
           ['bcc.same activeP0 ; not taken',2],
           ['lda.z permanent_zero',3],
           ['bcs.same readyP0',3],
        ];
   push @ops, {
      id=>"p${p}_p0_tail", earliest=>$b+141, latest_end=>$b+153,
      after=>["p${p}_p0_line"],
      description=>"pair $p P0 " . ($p0active?'active':'inactive') . " live-CPY carry path and direct known-row M0 shift",
      asm=>[ @$p0select, ["lsr.z object_masks_service_m0_$p",5] ],
   };
}

return {
   name=>sprintf('all_five exact-P1-pointer/live-P0 three-pair service p0=%u',$p0pat),
   description=>'Inactive PF buffer holds three exact P1 pointers; each pair consumes one pointer, replaces it with two PF bytes, and live-classifies P0 with CPY.',
   line_cycles=>76,
   horizon=>458,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
