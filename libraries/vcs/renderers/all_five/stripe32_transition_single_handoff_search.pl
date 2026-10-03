# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Five-pair timing proof for a one-player stripes=32 transition handoff.
#
# Only the player whose activity/wrap state changes is exact-cached across the
# three-pair special stripe.  One additional exact P0 byte in the following
# handoff pair buys the five contiguous cycles needed to install a precomputed
# packed-row shadow after the handoff temporarily skips the BL mask shift.
# This makes the cache cost four bytes per player-event incidence, including
# isolated one-player events; the dual-player proof lives in
# stripe32_transition_handoff_search.pl.
#
# VCSC_STRIPE_TRANSITION_PLAYER selects p1 or p0 (default p1).

use strict;
use warnings;

my $which=lc($ENV{VCSC_STRIPE_TRANSITION_PLAYER}//'p1');
die "VCSC_STRIPE_TRANSITION_PLAYER must be p1 or p0\n"
   unless $which eq 'p1' || $which eq 'p0';

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

sub add_pair {
   my ($p,$mode)=@_; # mode=special or ordinary
   my $b=$p*152;
   my $tag="p${p}_";
   my $prev=$p ? "p".($p-1)."_p0_feed" : undef;
   my $q=$p%3;
   my $is_special=$mode eq 'special';

   my @a=(
      ['sta GRP0',3],
      ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
      ['lda.z stripe_cache+1',3], ['sta PF1',3],
      ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ['lsr.zx object_masks+24,x',6],
      ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
   );
   if ($q<2) {
      push @a,["ldx.ay $color_src[$q],y",4], ['sta.a PF0',4],
              ['lda.z stripe_cache+4',3], ['sta PF1',3],
              ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } elsif ($is_special) {
      my $lo=$which eq 'p1' ? 'next_p1_ptr_lo' : 'next_p0_ptr_lo';
      push @a,["ldx.z $lo",3], ['nop',2], ['sta PF0',3],
              ['lda.z stripe_cache+4',3], ['sta PF1',3],
              ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } else {
      push @a,['bit.z timing_scratch',3], ['nop',2], ['sta PF0',3],
              ['lda.z stripe_cache+4',3], ['sta PF1',3],
              ['lda.z stripe_cache+5',3], ['sta PF2',3];
   }
   push @ops, {
      id=>$tag.'a_visible', after=>defined($prev)?[$prev]:[], earliest=>$b, latest_end=>$b+59,
      description=>"$mode pair $p A cadence",
      asm=>\@a, events=>[add_events_a($b)],
   };

   my @p1;
   push @p1,["stx.z next_color_slot+$q",3] if $q<2;
   if ($is_special && $which eq 'p1') {
      push @p1,["lda.z special_p1+$p",3];
      if ($p==2) { push @p1,['stx.z p1_service_ptr',3], ['nop',2]; }
      else { push @p1,['nop',2]; }
   } else {
      push @p1,['lda.iy (p1_service_ptr),y',5];
      if ($is_special && $which eq 'p0' && $p==2) {
         push @p1,['stx.z p0_service_ptr',3];
      } elsif ($p==2) {
         push @p1,['bit.z timing_scratch',3];
      }
   }
   push @p1,['tsx',2], ['lsr.zx object_masks+25,x',6],
            ["ldx.ay $even_src[$q],y",4], ['sta GRP1',3];
   push @ops, {
      id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      description=>"$mode pair $p P1 feed",
      asm=>\@p1, events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };

   push @ops, {
      id=>$tag.'b_left', after=>[$tag.'p1_feed'], earliest=>$b+83, latest_end=>$b+105,
      description=>"$mode pair $p B-left",
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ], events=>[add_events_bleft($b)],
   };
   push @ops, {
      id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      description=>"$mode pair $p PF commit",
      asm=>[
         ["lda.ay $odd_src[$q],y",4], ["sta.z inactive_pf+$odd[$q]",3],
         ["stx.z inactive_pf+$even[$q]",3], ['tsx',2],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
      ], events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };
   push @ops, {
      id=>$tag.'b_right', after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      description=>"$mode pair $p B-right",
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_bright($b)],
   };

   my @p0;
   if ($is_special && $which eq 'p0') {
      push @p0,["lda.z special_p0+$p",3];
      if ($p<2) {
         push @p0,["sta.z special_prepare_p0_$p",3], ['nop',2],
                  ['lsr.zx object_masks+26,x',6], ['dey',2];
      } else {
         push @p0,['lsr.zx object_masks+26,x',6], ['dey',2],
                  ['ldx.z next_p0_ptr_hi',3], ['nop',2];
      }
   } else {
      push @p0,['lda.iy (p0_service_ptr),y',5];
      if ($is_special && $which eq 'p1' && $p==2) {
         push @p0,['lsr.zx object_masks+26,x',6], ['ldx.z next_p1_ptr_hi',3], ['dey',2];
      } else {
         push @p0,["sta.z rolling_prepare_p0_$p",3],
                  ['lsr.zx object_masks+26,x',6], ['dey',2];
      }
   }
   push @ops, {
      id=>$tag.'p0_feed', after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      description=>"$mode pair $p P0 feed",
      asm=>\@p0,
   };
}

add_pair($_,'special') for 0..2;

# First pair after the special stripe.  X carries the changing player's high
# pointer byte from pair2.  The BL shift is replaced by a precombined byte;
# one exact P0 read at the tail creates the five-cycle slot that installs the
# precomputed row alias and restores S before ordinary pair4 resumes.
{
   my $p=3; my $b=456; my $tag='p3_';
   my $ptr=$which eq 'p1' ? 'p1_service_ptr+1' : 'p0_service_ptr+1';
   push @ops, {
      id=>$tag.'a_visible', after=>['p2_p0_feed'], earliest=>$b, latest_end=>$b+59,
      description=>"$which-only handoff commits high pointer and substitutes BL composite",
      asm=>[
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ["stx.z $ptr",3], ['tsx',2], ['bit.z timing_scratch',3],
         ['lda.z handoff_ball_pf0',3], ['sta ENABL',3],
         ['ldx.ay stripe_feed0,y',4], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_a($b)],
   };
   push @ops, {
      id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      description=>'handoff pair ordinary P1 feed after pointer commit',
      asm=>[
         ['stx.z next_color_slot+0',3], ['lda.iy (p1_service_ptr),y',5],
         ['tsx',2], ['lsr.zx object_masks+25,x',6],
         ['ldx.ay stripe_feed1,y',4], ['sta GRP1',3],
      ], events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };
   push @ops, {
      id=>$tag.'b_left', after=>[$tag.'p1_feed'], earliest=>$b+83, latest_end=>$b+105,
      description=>'handoff pair ordinary B-left',
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ], events=>[add_events_bleft($b)],
   };
   push @ops, {
      id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      description=>'handoff pair PF commit',
      asm=>[
         ['lda.ay stripe_feed2,y',4], ['sta.z inactive_pf+1',3],
         ['stx.z inactive_pf+0',3], ['tsx',2],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
      ], events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };
   push @ops, {
      id=>$tag.'b_right', after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      description=>'handoff pair ordinary B-right',
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[add_events_bright($b)],
   };
   push @ops, {
      id=>$tag.'p0_feed', after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      description=>'one exact P0 byte installs row alias and restores S',
      asm=>[
         ['lda.z handoff_p0',3], ['lsr.zx object_masks+26,x',6], ['dey',2],
         ['ldx.z handoff_row_shadow',3], ['txs',2],
      ],
   };
}

add_pair(4,'ordinary');

return {
   name=>"all_five stripes32 $which-only transition handoff",
   description=>'A one-player special stripe exact-caches only the changing player; one exact P0 handoff byte supplies row-shadow restoration, giving four exact bytes per player-event incidence.',
   line_cycles=>76,
   phase_origin=>2,
   horizon=>760,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
