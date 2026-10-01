# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Runtime-indexed six-scanline stripes=32 source feed.
#
# One page-aligned 256-byte table contains 32 eight-byte records:
#   COLUPF,COLUBK,PF0L,PF1L,PF2L,PF0R,PF1R,PF2R
# X is the record offset (0,8,...,248) for the stripe being prepared.  It is
# deliberately advanced in pieces after each pair's final source access:
# +3, +3, then +1 in pair-2 P1 and +1 in its tail.  Thus the next stripe's
# record index is ready with no separate +8 operation.  Operand displacements
# compensate while X is partially advanced.
#
# Y is local player index 2,1,0 only while feeding P1/P0.  The even PF source
# byte then rides in Y across the B-left TIA writes.  P0 mid stores that byte,
# copies the odd byte, and restores the local player index before P0 feed.
# Ball/M1/M0 use fixed current-mask bytes, so X never doubles as mask-row state.
# The rolling mask-byte reload is intentionally a separate remaining problem.
#
# Pair 2 uses its otherwise spare P1 cycles for the seventh X increment and
# forces STA GRP1 absolute so the write bus cycle remains at the ordinary
# appointment.  The final tail performs the eighth INX and a taken BNE inside
# the ordinary 16-cycle tail.  When X wraps before the final frame stripe, the
# not-taken branch is one cycle shorter; the emitted final-stripe entry must
# compensate that one terminal-only cycle.

use strict;
use warnings;

my @ops;
my @idx=(2,1,0);
# X displacement at the start of each pair: record base + 0,+3,+6.
my @xbase=(0,3,6);
# Record fields.
my @color=(0,1);
my @src_even=(2,4,6);
my @src_odd =(3,5,7);
my @dst_even=(0,2,4);
my @dst_odd =(1,3,5);

sub ax {
   my ($field,$xb)=@_;
   my $d=$field-$xb;
   return $d==0 ? 'stripe_record,x' :
          $d>0  ? "stripe_record+$d,x" : "stripe_record$d,x";
}

for my $p (0..2) {
   my $b=$p*152;
   my $tag="p${p}_";
   my $prev=$p ? 'p'.($p-1).'_p0_feed' : undef;

   my @a=(
      ['sta GRP0',3],
      ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
      # A, not Y, feeds PF1/PF2 so Y may carry the record-sourced color.
      ['lda.z stripe_cache+1',3], ['sta PF1',3],
      ['lda.z stripe_cache+2',3], ['sta PF2',3],
      # Forced absolute keeps the historical six-cycle Ball slot while X is
      # permanently the stripe-record offset.
      ['lsr.a current_ball_mask',6],
      ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
   );
   if ($p < 2) {
      push @a,
         ['ldy.ax '.ax($color[$p],$xbase[$p]),4],
         ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } else {
      push @a,
         ['dec.z rolling_mask_prepare',5], ['sta PF0',3],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   }
   push @ops, {
      id=>$tag.'a_visible',
      description=>"pair $p A cadence; X is runtime stripe-record offset",
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
   push @p1,['sty.z next_color_slot+'.$p,3] if $p<2;
   push @p1,
      ['ldy #'.$idx[$p],2],
      ['lda.iy (p1_service_ptr),y',5],
      # Forced absolute: fixed six-cycle slot, independent of record X.
      ['lsr.a current_m1_mask',6],
      ['ldy.ax '.ax($src_even[$p],$xbase[$p]),4];
   if ($p==2) {
      # Seventh byte of the +8 record advance.  Absolute GRP1 adds the one
      # cycle required to keep the write bus cycle identical.
      push @p1,['inx',2],['sta.a GRP1',4];
   } else {
      push @p1,['sta GRP1',3];
   }
   push @ops, {
      id=>$tag.'p1_feed',
      description=>"pair $p P1 feed; Y carries even record byte into B line",
      after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      asm=>\@p1,
      events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };

   push @ops, {
      id=>$tag.'b_left',
      description=>"pair $p B-left cadence preserves even PF byte in Y",
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

   # Pair 2 already advanced X once in P1, so its odd byte is field 7 at
   # effective displacement zero from record base+7.
   my $odd_xbase=$xbase[$p]+($p==2 ? 1 : 0);
   push @ops, {
      id=>$tag.'p0_mid',
      description=>"pair $p commits even/odd PF bytes and restores local P0 index",
      after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      asm=>[
         ["sty.z inactive_pf+$dst_even[$p]",3],
         ['lda.ax '.ax($src_odd[$p],$odd_xbase),4],
         ["sta.z inactive_pf+$dst_odd[$p]",3],
         ['ldy #'.$idx[$p],2],
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

   my @p0=(['lda.iy (p0_service_ptr),y',5]);
   if ($p<2) {
      # Direct current-mask RMW leaves six cycles: exactly three INX.
      push @p0,['lsr.z current_m0_mask',5],['inx',2],['inx',2],['inx',2];
   } else {
      # Eighth increment makes X the following record.  BNE consumes the rest
      # of the ordinary tail for the 31 steady stripe epochs.
      push @p0,['lsr.a current_m0_mask',6],['inx',2],['bne.same stripe_epoch_loop',3];
   }
   push @ops, {
      id=>$tag.'p0_feed',
      description=>"pair $p P0 feed plus in-cadence stripe-record advance",
      after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      asm=>\@p0,
   };
}

return {
   name=>'all_five stripes32 runtime-indexed record machine',
   description=>'Three exact pairs fetch one eight-byte stripe record through X, copy two colors/six PF bytes, feed local-index players, and advance X by eight inside the normal tails.',
   line_cycles=>76,
   phase_origin=>2,
   horizon=>456,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
