# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exact six-line rolling refill with preclassified P0/P1 activity patterns.
#
# The service-window planner supplies one three-bit activity pattern for each
# player.  That classification is intentionally outside this six-line timing
# proof: no height compare or activity branch is charged per pair here.  The
# eight P0 patterns and eight P1 patterns are all exercised by the regression.
#
# Each pair stages two next-stripe PF bytes without a sprite cache:
#   * the P1 service computes/zeros GRP1, loads one raw PF byte into X, shifts
#     the known M1 mask byte directly, and hands off at P0 cycle 5;
#   * the P0 line replaces its 11-cycle LDY/DEY/CPY/STY bookkeeping with a
#     five-cycle DEC, spending the recovered six cycles plus the one-cycle
#     zero-page PF0 timing knob on the second raw PF copy;
#   * the P0 tail commits X, computes/zeros GRP0 in an equal eight-cycle body,
#     shifts the known M0 mask directly, and closes at next P1 cycle 1.
#
# X is therefore payload, not the packed-mask index, for all three service
# pairs. Ball/M1/M0 use direct known-row shifts. The final four-cycle timing
# slot restores the known packed-row X seed with LDX-immediate plus a two-cycle NOP.

use strict;
use warnings;

sub pattern {
   my($name)=@_;
   my $s=defined($ENV{$name}) ? $ENV{$name} : '0';
   $s =~ /\A(?:0x)?([0-7])\z/i or die "$name must be 0..7\n";
   return hex($1);
}

my $p0pat=pattern('VCSC_P0_PATTERN');
my $p1pat=pattern('VCSC_P1_PATTERN');
my @ops;
my $PAIR=152;

for my $p (0..2) {
   my $b=$p*$PAIR;
   my $p1active=($p1pat >> $p) & 1;
   my $p0active=($p0pat >> $p) & 1;
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

   my $p1_service;
   my $grp1_event;
   if ($p1active) {
      $p1_service=[
         ['ldy.z player1_y',3], ['lda.iy (player1_graphics),y',5],
         ["ldx.a next_stripe_pf+$even",4],
         ["lsr.z object_masks_service_m1_$p",5],
         ['sta GRP1',3],
      ];
      $grp1_event=$b+80;
   } else {
      $p1_service=[
         ['lda #0',2],
         ["ldx.a next_stripe_pf+$even",4],
         ["lsr.z object_masks_service_m1_$p",5],
         ['bit.a $00',4],
         ['sta GRP1',3],
         ['nop',2],
      ];
      $grp1_event=$b+78;
   }
   push @ops, {
      id=>"p${p}_p1_service", earliest=>$b+61, latest_end=>$b+80,
      after=>["p${p}_p1_line"],
      description=>"pair $p preclassified P1 " . ($p1active?'active':'inactive') . " body carrying PF byte $even in X",
      asm=>$p1_service,
      events=>[{name=>'GRP1',offset=>$grp1_event-($b+61),windows=>[[$grp1_event,$grp1_event]]}],
   };

   push @ops, {
      id=>"p${p}_p0_line", earliest=>$b+81, latest_end=>$b+133,
      after=>["p${p}_p1_service"],
      description=>"pair $p P0 scanline stages PF byte $odd while X retains byte $even",
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['dec.z player0_y',5],
         ["lda.a next_stripe_pf+$odd",4], ["sta.z inactive_pf+$odd",3],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ],
      events=>[
         {name=>'PF0L',offset=>10,windows=>[[$b+91,$b+91]]},
         {name=>'PF1L',offset=>16,windows=>[[$b+97,$b+97]]},
         {name=>'PF2L',offset=>22,windows=>[[$b+103,$b+103]]},
         {name=>'PF0R',offset=>40,windows=>[[$b+121,$b+121]]},
         {name=>'PF1R',offset=>46,windows=>[[$b+127,$b+127]]},
         {name=>'PF2R',offset=>52,windows=>[[$b+133,$b+133]]},
      ],
   };

   my @p0sprite = $p0active
      ? (['ldy.z player0_y',3], ['lda.iy (player0_graphics),y',5])
      : (['lda #0',2], ['bit.a $00',4], ['nop',2]);
   my @finish = $p==2
      ? (['ldx #service_resume_x',2], ['nop',2])
      : (['bit.a $00',4]);
   push @ops, {
      id=>"p${p}_p0_tail", earliest=>$b+134, latest_end=>$b+153,
      after=>["p${p}_p0_line"],
      description=>"pair $p preclassified P0 " . ($p0active?'active':'inactive') . " tail commits PF byte $even and preserves M0 carry",
      asm=>[
         ["stx.z inactive_pf+$even",3],
         @p0sprite,
         ["lsr.z object_masks_service_m0_$p",5],
         @finish,
      ],
   };
}

return {
   name=>sprintf('all_five mixed P0/P1 three-pair service p0=%u p1=%u',$p0pat,$p1pat),
   description=>'Preclassified three-bit player activity patterns stage all six PF bytes in six scanlines with no sprite cache or per-pair height test.',
   line_cycles=>76,
   horizon=>458,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
