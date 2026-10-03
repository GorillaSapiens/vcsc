# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Six-scanline stripes=32 boundary-color cadence with ordinary event selection.
#
# The first two pairs consume all six next-stripe PF bytes: three feed values
# per pair.  Pair 2 therefore performs no PF refill.  Its P1 feed keeps X as
# the packed-mask row, omits TSX/feed staging, commits GRP1 at the very end of
# the old visible line, then reads C0/C1 directly from the two otherwise-free
# pair-2 feed slots and writes COLUPF/COLUBK in the new line's horizontal blank.
# B-left begins five cycles later than the ordinary cadence; pair-2 P0-mid is
# correspondingly five cycles shorter, so PF0R and every later appointment
# return to the ordinary phase.  This is the bridge from the proof-only 3x96
# source walk to a real six-scanline PF+color handoff.

use strict;
use warnings;

my @ops;
my @pf0=(0,3);
my @pf1=(1,4);
my @pf2=(2,5);

sub a_events {
   my($b)=@_;
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
sub bleft_events {
   my($b,$shift)=@_;
   return (
      {name=>'ENAM1',offset=>7, windows=>[[$b+90+$shift,$b+90+$shift]]},
      {name=>'PF0L', offset=>10,windows=>[[$b+93+$shift,$b+93+$shift]]},
      {name=>'PF1L', offset=>16,windows=>[[$b+99+$shift,$b+99+$shift]]},
      {name=>'PF2L', offset=>22,windows=>[[$b+105+$shift,$b+105+$shift]]},
   );
}
sub bright_events {
   my($b)=@_;
   return (
      {name=>'PF1R',offset=>5, windows=>[[$b+129,$b+129]]},
      {name=>'PF2R',offset=>11,windows=>[[$b+135,$b+135]]},
   );
}

for my $p (0..2) {
   my $b=$p*152;
   my $tag="p${p}_";
   my $prev=$p ? 'p'.($p-1).'_p0_feed' : undef;

   my @a=(
      ['sta GRP0',3],
      ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
      ['lda.z stripe_cache+1',3], ['sta PF1',3],
      ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ['lsr.zx object_masks+24,x',6],
      ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
   );
   if ($p < 2) {
      # First payload for this pair.  It is committed at the start of P1 feed.
      push @a,
         ["ldx.ay stripe_feed0,y",4], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } else {
      # Pair 2 spends the five-cycle preparation slot on event selection.
      push @a,
         ['cpy.z next_event_threshold',3], ['nop',2], ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   }
   push @ops, {
      id=>$tag.'a_visible',
      description=>"pair $p A cadence",
      after=>defined($prev)?[$prev]:[], earliest=>$b, latest_end=>$b+59,
      asm=>\@a, events=>[a_events($b)],
   };

   if ($p < 2) {
      my @p1=(
         ["stx.z inactive_pf+$pf0[$p]",3],
         ['lda.iy (p1_service_ptr),y',5],
         ['tsx',2], ['lsr.zx object_masks+25,x',6],
         ['ldx.ay stripe_feed1,y',4], ['sta GRP1',3],
      );
      push @ops, {
         id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
         description=>"pair $p P1 service plus second PF payload",
         asm=>\@p1,
         events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
      };
   } else {
      # 14 cycles to commit P1, then 14 cycles to switch both colors.  GRP1
      # lands on physical cycle 75 of the old line (phase origin 2); the color
      # stores land in the following line's horizontal blank.
      push @ops, {
         id=>$tag.'p1_feed', after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+90,
         description=>'pair 2 ordinary-event branch, boundary P1, and direct feed color handoff',
         asm=>[
            ['bcs.same ordinary_boundary',3],
            ['lda.iy (p1_service_ptr),y',5],
            ['lsr.zx object_masks+25,x',6],
            ['sta GRP1',3],
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

   my $shift=$p==2 ? 8 : 0;
   push @ops, {
      id=>$tag.'b_left', after=>[$tag.'p1_feed'], earliest=>$b+83+$shift, latest_end=>$b+105+$shift,
      description=>"pair $p B-left".($shift?' after color handoff':''),
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
      ], events=>[bleft_events($b,$shift)],
   };

   if ($p < 2) {
      push @ops, {
         id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
         description=>"pair $p third PF payload, second PF commit, packed-row restore",
         asm=>[
            ['lda.ay stripe_feed2,y',4], ["sta.z inactive_pf+$pf2[$p]",3],
            ["stx.z inactive_pf+$pf1[$p]",3], ['tsx',2],
            ['lda.z stripe_cache+3',3], ['sta PF0',3],
         ], events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
      };
   } else {
      # Starts eight cycles late, but needs only ten cycles and therefore
      # rejoins the ordinary PF0R phase exactly at b+123.
      push @ops, {
         id=>$tag.'p0_mid', after=>[$tag.'b_left'], earliest=>$b+114, latest_end=>$b+123,
         description=>'pair 2 short P0-mid repays eight-cycle boundary/event shift',
         asm=>[
            ['bit.z boundary_prepare0',3],
            ['lda.z stripe_cache+3',3], ['sta.a PF0',4],
         ], events=>[{name=>'PF0R',offset=>9,windows=>[[$b+123,$b+123]]}],
      };
   }

   push @ops, {
      id=>$tag.'b_right', after=>[$tag.'p0_mid'], earliest=>$b+124, latest_end=>$b+135,
      description=>"pair $p B-right restored to ordinary phase",
      asm=>[
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ], events=>[bright_events($b)],
   };

   push @ops, {
      id=>$tag.'p0_feed', after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      description=>"pair $p P0 feed and frame-wide Y advance",
      asm=>[
         ['lda.iy (p0_service_ptr),y',5],
         ["sta.z rolling_prepare_p0_$p",3],
         ['lsr.zx object_masks+26,x',6], ['dey',2],
      ],
   };
}

return {
   name=>'all_five stripes32 six-line PF+color boundary machine',
   description=>'Pairs 0/1 stage six PF bytes; pair2 selects the ordinary event path, switches colors in hblank after GRP1, and repays the eight-cycle B-left displacement before PF0R.',
   line_cycles=>76,
   phase_origin=>2,
   horizon=>456,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
