# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Six-scanline stripes=32 ordinary-path event-selection timing proof.
#
# Y starts at 95 for visible pair zero.  P1 and P0 deliberately consume the
# same Y value, then the pair tail decrements it once.  The two service pointers
# are independent, so VBLANK may bias both against Y=95 while still mapping the
# effective address to the historical public_y-1-pair source byte.  Y therefore
# runs 95..0 through the 96 visible pairs; the final tail DEY may wrap only
# after the last P0 feed, when visible code no longer consumes it.  Neither service pointer needs a per-stripe -3 adjustment; pointer
# changes are needed only at the real activity/wrap transitions bounded by
# stripe32_transition_bound.pl.
#
# The runtime stripe source no longer needs X for indexing, so the ordinary
# packed BL/M1/M0 row state may stay in X/SP.  P0-mid commits the already
# staged even PF byte and then TSX restores the packed-mask row before the
# right-half tail.  That lets P1 and P0 share one Y value while preserving the
# proven packed-mask machinery and still leaves seventeen real preparation
# cycles per stripe.
#
# The runtime stripe source is three page-contained 96-byte tables indexed by
# that same Y.  Pair phase is Y mod 3, so one table location is consumed per
# pair and no separate stripe index exists.  feed0 interleaves C0/C1/PF4,
# feed1 interleaves PF0/PF2/PF5, and feed2 interleaves PF1/PF3/unused.  All
# timing-critical loads remain fixed four-cycle absolute,Y reads.
#
# Pair 2 uses the otherwise-five-cycle A preparation slot for CPY.z + NOP.
# Carry survives the following PF stores and P1 load, so the otherwise-three-
# cycle P1 preparation slot can be a taken BCS to the ordinary continuation.
# At the target stripe the BCS falls through in two cycles, recovering one
# additional cycle for the special path.  stripe32_event_threshold_bound.pl
# proves threshold=97-3*event fires exactly one stripe early; stripe zero is selected by VBLANK entry.

use strict;
use warnings;

my @ops;
my @even=(0,2,4);
my @odd =(1,3,5);
my @color_src=('stripe_feed0','stripe_feed0');
my @even_src =('stripe_feed1','stripe_feed1','stripe_feed0');
my @odd_src  =('stripe_feed2','stripe_feed2','stripe_feed1');

for my $p (0..2) {
   my $b=$p*152;
   my $tag="p${p}_";
   my $prev=$p ? "p".($p-1)."_p0_feed" : undef;

   my @a=(
      ['sta GRP0',3],
      ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
      # Preserve the persistent player Y: PF1/PF2 use A, not Y.
      ['lda.z stripe_cache+1',3], ['sta PF1',3],
      ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ['lsr.zx object_masks+24,x',6],
      ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
   );
   if ($p < 2) {
      # X may carry the color because Ball has already consumed row X.  The
      # absolute PF0 store preserves the historical PF0R write phase.
      push @a,
         ["ldx.ay $color_src[$p],y",4], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } else {
      push @a,
         ['cpy.z next_event_threshold',3], ['nop',2], ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   }
   push @ops, {
      id=>$tag.'a_visible',
      description=>"pair $p fixed A cadence; persistent player Y survives PF writes",
      after=>defined($prev)?[$prev]:[], earliest=>$b, latest_end=>$b+59,
      asm=>\@a,
      events=>[
         {name=>'GRP0', offset=>2, windows=>[[$b+2,$b+2]]},
         {name=>'ENAM0',offset=>10,windows=>[[$b+10,$b+10]]},
         {name=>'PF0L', offset=>13,windows=>[[$b+13,$b+13]]},
         {name=>'PF1L', offset=>19,windows=>[[$b+19,$b+19]]},
         {name=>'PF2L', offset=>25,windows=>[[$b+25,$b+25]]},
         {name=>'ENABL',offset=>39,windows=>[[$b+39,$b+39]]},
         {name=>'PF0R', offset=>47,windows=>[[$b+47,$b+47]]},
         {name=>'PF1R', offset=>53,windows=>[[$b+53,$b+53]]},
         {name=>'PF2R', offset=>59,windows=>[[$b+59,$b+59]]},
      ],
   };

   my @p1;
   push @p1,["stx.z next_color_slot+$p",3] if $p < 2;
   push @p1,['lda.iy (p1_service_ptr),y',5];
   # Pair 2 has no color store, so its otherwise-identical feed owns one
   # genuine three-cycle preparation slot.  TSX restores the packed-mask row
   # before M1 is shifted; the even-PF source then reuses X as staging data.
   push @p1,['bcs.same ordinary_stripe_continue',3] if $p==2;
   push @p1,
      ['tsx',2],
      ['lsr.zx object_masks+25,x',6],
      ["ldx.ay $even_src[$p],y",4],
      ['sta GRP1',3];
   push @ops, {
      id=>$tag.'p1_feed',
      description=>"pair $p same-index P1 feed, packed-M1 shift, and even-PF/color staging",
      after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      asm=>\@p1,
      events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };

   push @ops, {
      id=>$tag.'b_left',
      description=>"pair $p fixed B-left cadence; persistent Y is untouched",
      after=>[$tag.'p1_feed'], earliest=>$b+83, latest_end=>$b+105,
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ],
      events=>[
         {name=>'ENAM1',offset=>7, windows=>[[$b+90,$b+90]]},
         {name=>'PF0L', offset=>10,windows=>[[$b+93,$b+93]]},
         {name=>'PF1L', offset=>16,windows=>[[$b+99,$b+99]]},
         {name=>'PF2L', offset=>22,windows=>[[$b+105,$b+105]]},
      ],
   };

   push @ops, {
      id=>$tag.'p0_mid',
      description=>"pair $p odd/even PF commit plus packed-row TSX restore",
      after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      asm=>[
         ["lda.ay $odd_src[$p],y",4],
         ["sta.z inactive_pf+$odd[$p]",3],
         ["stx.z inactive_pf+$even[$p]",3],
         ['tsx',2],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
      ],
      events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };

   push @ops, {
      id=>$tag.'b_right',
      description=>"pair $p fixed B-right cadence",
      after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ],
      events=>[
         {name=>'PF1R',offset=>5, windows=>[[$b+129,$b+129]]},
         {name=>'PF2R',offset=>11,windows=>[[$b+135,$b+135]]},
      ],
   };

   push @ops, {
      id=>$tag.'p0_feed',
      description=>"pair $p same-index P0 feed; pair-tail DEY advances the frame-wide index",
      after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      asm=>[
         ['lda.iy (p0_service_ptr),y',5],
         ["sta.z rolling_prepare_p0_$p",3],
         ['lsr.zx object_masks+26,x',6],
         ['dey',2],
      ],
   };
}

return {
   name=>'all_five stripes32 ordinary event-select machine',
   description=>'Ordinary stripes32 path embeds CPY+BCS event selection in the existing 5+3 preparation slots without moving TIA appointments; carry survives the intervening PF/player loads.',
   line_cycles=>76,
   phase_origin=>2,
   horizon=>456,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
