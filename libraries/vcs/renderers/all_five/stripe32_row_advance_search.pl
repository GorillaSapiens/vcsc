# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Timing proof for the three deterministic packed-mask row-boundary positions
# inside the stripes=32 24-pair supercycle.
#
# VCSC_STRIPE32_ROW_AFTER selects p0, p1, or p2: the packed BL/M1/M0 row ends
# after that pair of this six-line stripe.  The compact stripes32 mask view is
# three 12-byte lanes indexed by row X=0..11:
#   object_masks+0,x   BL
#   object_masks+12,x  M1
#   object_masks+24,x  M0
# S shadows X while X is borrowed for PF feed staging.
#
# p2 boundary: pair2 has no PF staging in P0-mid, so INX/TXS replace the
# three-cycle prepare BIT plus the forced-absolute PF0 store (2+2+3+3 == 10).
# M0 then uses object_masks+23,x because X is already the next row.
#
# p1 boundary: pair1 tail drops a three-cycle prepare store and uses INX,
# becoming one cycle shorter. Pair2 starts one cycle early and uses a forced
# absolute GRP0 store, so the GRP0 appointment and everything after it remain
# unchanged. Pair2's existing selector NOP becomes TXS, updating the shadow
# before M1 needs it.
#
# p0 boundary: this is the only phase that needs an exact P0 byte.  LDA zp,X
# from object_masks+35,x addresses four precomputed bytes at compact row
# indices 1,4,7,10 (offsets 36,39,42,45).  The 4-cycle exact load plus
# LSR/INX/TXS/DEY is exactly the ordinary 16-cycle tail.

use strict;
use warnings;
my $after=lc($ENV{VCSC_STRIPE32_ROW_AFTER}//'p2');
die "VCSC_STRIPE32_ROW_AFTER must be p0, p1, or p2\n"
   unless $after =~ /^p[012]$/;
my $boundary_pair=substr($after,1,1)+0;

my @ops;
my @pf0=(0,3);
my @pf1=(1,4);
my @pf2=(2,5);

sub a_events_abs {
   my($b,$lead)=@_; $lead//=0;
   return (
      {name=>'GRP0', offset=>2+$lead, windows=>[[$b+2,$b+2]]},
      {name=>'ENAM0',offset=>10+$lead,windows=>[[$b+10,$b+10]]},
      {name=>'PF0L', offset=>13+$lead,windows=>[[$b+13,$b+13]]},
      {name=>'PF1L', offset=>19+$lead,windows=>[[$b+19,$b+19]]},
      {name=>'PF2L', offset=>25+$lead,windows=>[[$b+25,$b+25]]},
      {name=>'ENABL',offset=>39+$lead,windows=>[[$b+39,$b+39]]},
      {name=>'PF0R', offset=>47+$lead,windows=>[[$b+47,$b+47]]},
      {name=>'PF1R', offset=>53+$lead,windows=>[[$b+53,$b+53]]},
      {name=>'PF2R', offset=>59+$lead,windows=>[[$b+59,$b+59]]},
   );
}
sub bleft_events_abs {
   my($b,$shift)=@_;
   return (
      {name=>'ENAM1',offset=>7,windows=>[[$b+90+$shift,$b+90+$shift]]},
      {name=>'PF0L', offset=>10,windows=>[[$b+93+$shift,$b+93+$shift]]},
      {name=>'PF1L', offset=>16,windows=>[[$b+99+$shift,$b+99+$shift]]},
      {name=>'PF2L', offset=>22,windows=>[[$b+105+$shift,$b+105+$shift]]},
   );
}
sub bright_events_abs {
   my($b)=@_;
   return (
      {name=>'PF1R',offset=>5,windows=>[[$b+129,$b+129]]},
      {name=>'PF2R',offset=>11,windows=>[[$b+135,$b+135]]},
   );
}

for my $p (0..2) {
   my $b=$p*152;
   my $tag="p${p}_";
   my $prev=$p ? 'p'.($p-1).'_p0_feed' : undef;
   my $pair2_early=($after eq 'p1' && $p==2) ? 1 : 0;

   my @a;
   if ($pair2_early) { push @a,['sta.a GRP0',4]; }
   else              { push @a,['sta GRP0',3]; }
   push @a,
      ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
      ['lda.z stripe_cache+1',3], ['sta PF1',3],
      ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ['lsr.zx object_masks+0,x',6],
      ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3];
   if ($p<2) {
      push @a,
         ['ldx.ay stripe_feed0,y',4], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } else {
      push @a,
         ['cpy.z next_event_threshold',3],
         [($after eq 'p1' ? 'txs' : 'nop'),2],
         ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   }
   my $astart=$b-$pair2_early;
   push @ops, {
      id=>$tag.'a_visible', after=>defined($prev)?[$prev]:[],
      earliest=>$astart, latest_end=>$b+59,
      description=>"pair $p A cadence".($pair2_early?' starts one cycle early and repays with absolute GRP0':''),
      asm=>\@a, events=>[a_events_abs($b,$pair2_early)],
   };

   if ($p<2) {
      push @ops, {
         id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
         description=>"pair $p P1 service plus second PF payload",
         asm=>[
            ["stx.z inactive_pf+$pf0[$p]",3], ['lda.iy (p1_service_ptr),y',5],
            ['tsx',2], ['lsr.zx object_masks+12,x',6],
            ['ldx.ay stripe_feed1,y',4], ['sta GRP1',3],
         ],
         events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
      };
   } else {
      push @ops, {
         id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+90,
         description=>'pair 2 event branch, P1, and boundary colors',
         asm=>[
            ['bcs.same ordinary_boundary',3], ['lda.iy (p1_service_ptr),y',5],
            ['lsr.zx object_masks+12,x',6], ['sta GRP1',3],
            ['lda.ay stripe_feed0,y',4], ['sta COLUPF',3],
            ['lda.ay stripe_feed1,y',4], ['sta COLUBK',3],
         ],
         events=>[
            {name=>'GRP1',offset=>16,windows=>[[$b+76,$b+76]]},
            {name=>'COLUPF',offset=>23,windows=>[[$b+83,$b+83]]},
            {name=>'COLUBK',offset=>30,windows=>[[$b+90,$b+90]]},
         ],
      };
   }

   my $shift=$p==2?8:0;
   push @ops, {
      id=>$tag.'b_left', after=>[$tag.'p1_feed'], earliest=>$b+83+$shift, latest_end=>$b+105+$shift,
      description=>"pair $p B-left",
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ], events=>[bleft_events_abs($b,$shift)],
   };

   if ($p<2) {
      push @ops, {
         id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
         description=>"pair $p PF staging and row restore",
         asm=>[
            ['lda.ay stripe_feed2,y',4], ["sta.z inactive_pf+$pf2[$p]",3],
            ["stx.z inactive_pf+$pf1[$p]",3], ['tsx',2],
            ['lda.z stripe_cache+3',3], ['sta PF0',3],
         ], events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
      };
   } else {
      my @mid;
      if ($after eq 'p2') {
         @mid=(['inx',2],['txs',2],['lda.z stripe_cache+3',3],['sta PF0',3]);
      } else {
         @mid=(['bit.z boundary_prepare0',3],['lda.z stripe_cache+3',3],['sta.a PF0',4]);
      }
      push @ops, {
         id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+114, latest_end=>$b+123,
         description=>($after eq 'p2'?'pair 2 advances row X/S before old-row M0':'pair 2 short boundary P0-mid'),
         asm=>\@mid, events=>[{name=>'PF0R',offset=>9,windows=>[[$b+123,$b+123]]}],
      };
   }

   push @ops, {
      id=>$tag.'b_right', after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      description=>"pair $p B-right",
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[bright_events_abs($b)],
   };

   my @tail;
   if ($p==$boundary_pair && $after eq 'p0') {
      @tail=(
         ['lda.zx object_masks+35,x',4], # exact next-pair P0, rows 1/4/7/10
         ['lsr.zx object_masks+24,x',6], ['inx',2], ['txs',2], ['dey',2],
      );
   } elsif ($p==$boundary_pair && $after eq 'p1') {
      @tail=(
         ['lda.iy (p0_service_ptr),y',5],
         ['lsr.zx object_masks+24,x',6], ['inx',2], ['dey',2],
      );
   } elsif ($p==$boundary_pair && $after eq 'p2') {
      @tail=(
         ['lda.iy (p0_service_ptr),y',5], ['sta.z rolling_prepare_p0_2',3],
         ['lsr.zx object_masks+23,x',6], ['dey',2],
      );
   } else {
      @tail=(
         ['lda.iy (p0_service_ptr),y',5], ["sta.z rolling_prepare_p0_$p",3],
         ['lsr.zx object_masks+24,x',6], ['dey',2],
      );
   }
   my $tail_end=$b+151;
   $tail_end-- if $p==$boundary_pair && $after eq 'p1';
   push @ops, {
      id=>$tag.'p0_feed', after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$tail_end,
      description=>"pair $p P0 tail".($p==$boundary_pair?"; row boundary after $after":''),
      asm=>\@tail,
   };
}

return {
   name=>"all_five stripes32 compact-row advance after $after",
   description=>'Three deterministic row-boundary variants preserve all TIA appointments using row-index X/S and compact BL/M1/M0 lanes; only p0-after needs an exact indexed P0 cache byte.',
   line_cycles=>76,
   phase_origin=>2,
   horizon=>456,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
