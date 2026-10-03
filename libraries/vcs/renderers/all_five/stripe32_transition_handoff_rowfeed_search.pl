# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Five-pair timing proof for a stripes=32 transition handoff with ROM,Y row-shadow restore.
#
# Pairs 0..2 are a special six-line stripe. Both players come from exact
# three-byte caches, so their ordinary service pointers are idle while the
# stripe crosses an activity/wrap transition. Pair 3 is the first pair of the
# following stripe and is also exact-cached. Three precomputed composite bytes
# remove BL/M1/M0 carry dependencies only where the handoff temporarily owns X
# and S. Pair 4 resumes the ordinary common-index machine.
#
# Four arbitrary precomputed pointer bytes are copied without moving any TIA
# appointment:
#   1) P1.lo: X load in pair2's five-cycle A slot, X store after cached P1.
#   2) P1.hi: X load after pair2 M0, carry across boundary, store in pair3 A.
#   3) P0.lo: pair3 A loads it into X then TXS; pair3 P1 TSX/STX commits it.
#   4) P0.hi: pair3 P1 loads it into X then TXS; pair3 P0 TSX/STX commits it.
# Pair3 then restores the packed-row stack shadow from a precomputed byte.
# There are no stack accesses, only TSX/TXS register transfers.

use strict;
use warnings;

my @ops;
my @even=(0,2,4);
my @odd =(1,3,5);
my @color_src=('stripe_feed0','stripe_feed0');
my @even_src =('stripe_feed1','stripe_feed1','stripe_feed0');
my @odd_src  =('stripe_feed2','stripe_feed2','stripe_feed1');

sub add_events_a {
   my ($b)=@_;
   return (
      {name=>'GRP0', offset=>2, windows=>[[$b+2,$b+2]]},
      {name=>'ENAM0',offset=>10,windows=>[[$b+10,$b+10]]},
      {name=>'PF0L', offset=>13,windows=>[[$b+13,$b+13]]},
      {name=>'PF1L', offset=>19,windows=>[[$b+19,$b+19]]},
      {name=>'PF2L', offset=>25,windows=>[[$b+25,$b+25]]},
      {name=>'ENABL',offset=>39,windows=>[[$b+39,$b+39]]},
      {name=>'PF0R', offset=>47,windows=>[[$b+47,$b+47]]},
      {name=>'PF1R', offset=>53,windows=>[[$b+53,$b+53]]},
      {name=>'PF2R', offset=>59,windows=>[[$b+59,$b+59]]},
   );
}
sub add_events_bleft {
   my ($b)=@_;
   return (
      {name=>'ENAM1',offset=>7, windows=>[[$b+90,$b+90]]},
      {name=>'PF0L', offset=>10,windows=>[[$b+93,$b+93]]},
      {name=>'PF1L', offset=>16,windows=>[[$b+99,$b+99]]},
      {name=>'PF2L', offset=>22,windows=>[[$b+105,$b+105]]},
   );
}
sub add_events_bright {
   my ($b)=@_;
   return (
      {name=>'PF1R',offset=>5, windows=>[[$b+129,$b+129]]},
      {name=>'PF2R',offset=>11,windows=>[[$b+135,$b+135]]},
   );
}

# Special stripe, pairs 0..1. Keep the common-index cadence but use exact
# player caches; the recovered two-cycle holes are real and explicitly filled.
for my $p (0..1) {
   my $b=$p*152;
   my $tag="p${p}_";
   my $prev=$p ? "p".($p-1)."_p0_feed" : undef;
   push @ops, {
      id=>$tag.'a_visible', after=>defined($prev)?[$prev]:[],
      earliest=>$b, latest_end=>$b+59,
      description=>"special pair $p A cadence",
      asm=>[
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['lsr.zx object_masks+24,x',6],
         ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
         ["ldx.ay $color_src[$p],y",4], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_a($b)],
   };
   push @ops, {
      id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      description=>"special pair $p exact P1",
      asm=>[
         ["stx.z next_color_slot+$p",3],
         ["lda.z special_p1+$p",3], ['nop',2],
         ['tsx',2], ['lsr.zx object_masks+25,x',6],
         ["ldx.ay $even_src[$p],y",4], ['sta GRP1',3],
      ], events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };
   push @ops, {
      id=>$tag.'b_left', after=>[$tag.'p1_feed'], earliest=>$b+83, latest_end=>$b+105,
      description=>"special pair $p B-left",
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ], events=>[add_events_bleft($b)],
   };
   push @ops, {
      id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      description=>"special pair $p PF commit",
      asm=>[
         ["lda.ay $odd_src[$p],y",4], ["sta.z inactive_pf+$odd[$p]",3],
         ["stx.z inactive_pf+$even[$p]",3], ['tsx',2],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
      ], events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };
   push @ops, {
      id=>$tag.'b_right', after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      description=>"special pair $p B-right",
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_bright($b)],
   };
   push @ops, {
      id=>$tag.'p0_feed', after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      description=>"special pair $p exact P0",
      asm=>[
         ["lda.z special_p0+$p",3], ['nop',2],
         ["sta.z special_prepare_p0_$p",3],
         ['lsr.zx object_masks+26,x',6], ['dey',2],
      ],
   };
}

# Special pair 2. Copy P1.low through X, then carry P1.high in X across the
# stripe boundary after M0 has consumed the packed-row index.
{
   my $p=2; my $b=304; my $tag='p2_';
   push @ops, {
      id=>$tag.'a_visible', after=>['p1_p0_feed'], earliest=>$b, latest_end=>$b+59,
      description=>'special pair 2 A cadence starts P1.low handoff',
      asm=>[
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['lsr.zx object_masks+24,x',6],
         ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
         ['ldx.z next_p1_ptr_lo',3], ['nop',2], ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_a($b)],
   };
   push @ops, {
      id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      description=>'special pair 2 exact P1 commits P1.low',
      asm=>[
         ['lda.z special_p1+2',3], ['stx.z p1_service_ptr',3], ['nop',2],
         ['tsx',2], ['lsr.zx object_masks+25,x',6],
         ['ldx.ay stripe_feed0,y',4], ['sta GRP1',3],
      ], events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };
   push @ops, {
      id=>$tag.'b_left', after=>[$tag.'p1_feed'], earliest=>$b+83, latest_end=>$b+105,
      description=>'special pair 2 B-left',
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ], events=>[add_events_bleft($b)],
   };
   push @ops, {
      id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      description=>'special pair 2 final PF commit',
      asm=>[
         ['lda.ay stripe_feed1,y',4], ['sta.z inactive_pf+5',3],
         ['stx.z inactive_pf+4',3], ['tsx',2],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
      ], events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };
   push @ops, {
      id=>$tag.'b_right', after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      description=>'special pair 2 B-right',
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_bright($b)],
   };
   push @ops, {
      id=>$tag.'p0_feed', after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      description=>'special pair 2 exact P0; carry P1.high in X across stripe boundary',
      asm=>[
         ['lda.z special_p0+2',3],
         ['lsr.zx object_masks+26,x',6],
         ['dey',2], ['ldx.z next_p1_ptr_hi',3], ['nop',2],
      ],
   };
}

# Pair 3: first pair after the special stripe. P1/P0 are still exact-cached.
# BL and M1 carries are replaced by composite bytes while S carries the two P0
# pointer source bytes. P1.high arrives in X from pair2.
{
   my $b=456; my $tag='p3_';
   push @ops, {
      id=>$tag.'a_visible', after=>['p2_p0_feed'], earliest=>$b, latest_end=>$b+59,
      description=>'handoff pair A stores carried P1.high and puts P0.low in S',
      asm=>[
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['stx.z p1_service_ptr+1',3],
         ['ldx.z next_p0_ptr_lo',3], ['txs',2],
         ['lda.z handoff_ball_pf0',3], ['sta ENABL',3],
         ['ldx.ay stripe_feed0,y',4], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_a($b)],
   };
   push @ops, {
      id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      description=>'handoff pair exact P1 commits P0.low then carries P0.high in S',
      asm=>[
         ['stx.z next_color_slot+0',3],
         ['lda.z handoff_p1',3],
         ['tsx',2], ['stx.z p0_service_ptr',3],
         ['ldx.z next_p0_ptr_hi',3], ['txs',2],
         ['ldx.ay stripe_feed1,y',4], ['sta GRP1',3],
      ], events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };
   push @ops, {
      id=>$tag.'b_left', after=>[$tag.'p1_feed'], earliest=>$b+83, latest_end=>$b+105,
      description=>'handoff pair uses precombined M1/PF0L byte',
      asm=>[
         ['lda.z handoff_m1_pf0',3], ['nop',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ], events=>[add_events_bleft($b)],
   };
   push @ops, {
      id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      description=>'handoff pair PF commit while S retains P0.high source',
      asm=>[
         ['lda.ay stripe_feed2,y',4], ['sta.z inactive_pf+1',3],
         ['stx.z inactive_pf+0',3], ['nop',2],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
      ], events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };
   push @ops, {
      id=>$tag.'b_right', after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      description=>'handoff pair B-right',
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_bright($b)],
   };
   push @ops, {
      id=>$tag.'p0_feed', after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      description=>'handoff pair exact P0 commits P0.high and restores packed-row S',
      asm=>[
         ['lda.z handoff_p0',3], ['dey',2],
         ['tsx',2], ['stx.z p0_service_ptr+1',3],
         ['ldx.ay packed_row_shadow,y',4], ['txs',2],
      ],
   };
}

# Pair 4: ordinary service pointers are live again. Pair3 skipped the M0 shift,
# so the first ENAM0/PF0L value is precombined; after that the ordinary BL/M1/M0
# cadence is fully restored.
{
   my $p=4; my $b=608; my $tag='p4_';
   push @ops, {
      id=>$tag.'a_visible', after=>['p3_p0_feed'], earliest=>$b, latest_end=>$b+59,
      description=>'ordinary resume pair with one precombined prior-M0/PF0L byte',
      asm=>[
         ['sta GRP0',3],
         ['lda.z handoff_m0_pf0',3], ['nop',2], ['sta ENAM0',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['lsr.zx object_masks+24,x',6],
         ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
         ['ldx.ay stripe_feed0,y',4], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_a($b)],
   };
   push @ops, {
      id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      description=>'ordinary resume P1 pointer feed',
      asm=>[
         ['stx.z next_color_slot+1',3], ['lda.iy (p1_service_ptr),y',5],
         ['tsx',2], ['lsr.zx object_masks+25,x',6],
         ['ldx.ay stripe_feed1,y',4], ['sta GRP1',3],
      ], events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };
   push @ops, {
      id=>$tag.'b_left', after=>[$tag.'p1_feed'], earliest=>$b+83, latest_end=>$b+105,
      description=>'ordinary resume B-left',
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ], events=>[add_events_bleft($b)],
   };
   push @ops, {
      id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      description=>'ordinary resume PF commit',
      asm=>[
         ['lda.ay stripe_feed2,y',4], ['sta.z inactive_pf+3',3],
         ['stx.z inactive_pf+2',3], ['tsx',2],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
      ], events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };
   push @ops, {
      id=>$tag.'b_right', after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      description=>'ordinary resume B-right',
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_bright($b)],
   };
   push @ops, {
      id=>$tag.'p0_feed', after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      description=>'ordinary resume P0 pointer feed',
      asm=>[
         ['lda.iy (p0_service_ptr),y',5], ['sta.z ordinary_prepare',3],
         ['lsr.zx object_masks+26,x',6], ['dey',2],
      ],
   };
}

return {
   name=>'all_five stripes32 transition handoff',
   description=>'Three cached transition pairs plus one cached handoff pair copy all four arbitrary service-pointer bytes, restore the packed-row stack shadow from a page-contained ROM,Y table, and resume the ordinary common-index cadence without moving TIA appointments.',
   line_cycles=>76,
   phase_origin=>2,
   horizon=>760,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
