# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Maximum-run timing proof for the hybrid stripes=32 transition policy.
#
# Three complete cached continuation stripes (nine pairs) are followed by the
# already-proved final dual-pointer transition handoff (five pairs).  This is
# the reachable worst run length of four union-special stripes.  Intermediate
# stripes exact-cache both players and intentionally defer all pointer changes;
# only the final stripe installs the two final 16-bit service pointers.
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

my @ops;
my @even=(0,2,4);
my @odd =(1,3,5);
my @color_src=('stripe_feed0','stripe_feed0');
my @even_src =('stripe_feed1','stripe_feed1','stripe_feed0');
my @odd_src  =('stripe_feed2','stripe_feed2','stripe_feed1');
sub ev_a { my($b)=@_; return (
 {name=>'GRP0',offset=>2,windows=>[[$b+2,$b+2]]},{name=>'ENAM0',offset=>10,windows=>[[$b+10,$b+10]]},
 {name=>'PF0L',offset=>13,windows=>[[$b+13,$b+13]]},{name=>'PF1L',offset=>19,windows=>[[$b+19,$b+19]]},
 {name=>'PF2L',offset=>25,windows=>[[$b+25,$b+25]]},{name=>'ENABL',offset=>39,windows=>[[$b+39,$b+39]]},
 {name=>'PF0R',offset=>47,windows=>[[$b+47,$b+47]]},{name=>'PF1R',offset=>53,windows=>[[$b+53,$b+53]]},
 {name=>'PF2R',offset=>59,windows=>[[$b+59,$b+59]]}); }
sub ev_l { my($b)=@_; return (
 {name=>'ENAM1',offset=>7,windows=>[[$b+90,$b+90]]},{name=>'PF0L',offset=>10,windows=>[[$b+93,$b+93]]},
 {name=>'PF1L',offset=>16,windows=>[[$b+99,$b+99]]},{name=>'PF2L',offset=>22,windows=>[[$b+105,$b+105]]}); }
sub ev_r { my($b)=@_; return (
 {name=>'PF1R',offset=>5,windows=>[[$b+129,$b+129]]},{name=>'PF2R',offset=>11,windows=>[[$b+135,$b+135]]}); }

for my $p (0..2) {
   my $b=$p*152; my $q=$p%3; my $tag="c${p}_";
   my $prev=$p ? 'c'.($p-1).'_p0_feed' : undef;
   my @a=(
      ['sta GRP0',3],['lda.z stripe_cache+0',3],['adc #0',2],['sta ENAM0',3],['sta PF0',3],
      ['lda.z stripe_cache+1',3],['sta PF1',3],['lda.z stripe_cache+2',3],['sta PF2',3],
      ['lsr.zx object_masks+24,x',6],['lda.z stripe_cache+3',3],['adc #0',2],['sta ENABL',3],
   );
   if ($q<2) {
      push @a,["ldx.ay $color_src[$q],y",4],['sta.a PF0',4],
              ['lda.z stripe_cache+4',3],['sta PF1',3],['lda.z stripe_cache+5',3],['sta PF2',3];
   } else {
      push @a,['bit.z run_continue_a',3],['nop',2],['sta PF0',3],
              ['lda.z stripe_cache+4',3],['sta PF1',3],['lda.z stripe_cache+5',3],['sta PF2',3];
   }
   push @ops,{id=>$tag.'a_visible',after=>defined($prev)?[$prev]:[],earliest=>$b,latest_end=>$b+59,
      description=>'cached-run continuation A',asm=>\@a,events=>[ev_a($b)]};
   my @p1;
   push @p1,["stx.z next_color_slot+$q",3] if $q<2;
   push @p1,["lda.z run_p1+$p",3];
   if ($q<2) { push @p1,['nop',2]; }
   else { push @p1,['bit.z run_continue_p1',3],['nop',2]; }
   push @p1,['tsx',2],['lsr.zx object_masks+25,x',6],["ldx.ay $even_src[$q],y",4],['sta GRP1',3];
   push @ops,{id=>$tag.'p1_feed',after=>[$tag.'a_visible'],earliest=>$b+60,latest_end=>$b+82,
      description=>'cached-run continuation exact P1',asm=>\@p1,
      events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}]};
   push @ops,{id=>$tag.'b_left',after=>[$tag.'p1_feed'],earliest=>$b+83,latest_end=>$b+105,
      description=>'cached-run continuation B-left',asm=>[
       ['lda.z stripe_cache+0',3],['adc #0',2],['sta ENAM1',3],['sta PF0',3],
       ['lda.z stripe_cache+1',3],['sta PF1',3],['lda.z stripe_cache+2',3],['sta PF2',3]],events=>[ev_l($b)]};
   push @ops,{id=>$tag.'p0_mid',after=>[$tag.'b_left'],earliest=>$b+106,latest_end=>$b+123,
      description=>'cached-run continuation PF commit',asm=>[
       ["lda.ay $odd_src[$q],y",4],["sta.z inactive_pf+$odd[$q]",3],["stx.z inactive_pf+$even[$q]",3],
       ['tsx',2],['lda.z stripe_cache+3',3],['sta PF0',3]],
      events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}]};
   push @ops,{id=>$tag.'b_right',after=>[$tag.'p0_mid'],earliest=>$b+124,latest_end=>$b+135,
      description=>'cached-run continuation B-right',asm=>[
       ['lda.z stripe_cache+4',3],['sta PF1',3],['lda.z stripe_cache+5',3],['sta PF2',3]],events=>[ev_r($b)]};
   push @ops,{id=>$tag.'p0_feed',after=>[$tag.'b_right'],earliest=>$b+136,latest_end=>$b+151,
      description=>'cached-run continuation exact P0',asm=>[
       ["lda.z run_p0+$p",3],['bit.z run_continue_p0',3],['nop',2],
       ['lsr.zx object_masks+26,x',6],['dey',2]]};
}


return {
 name=>'all_five stripes32 cached transition-run continuation stripe',
 description=>'One complete both-player cached stripe preserves every ordinary TIA appointment, leaves service pointers untouched, and ends on the same pair boundary, so it may repeat before the separately proved final handoff.',
 line_cycles=>76,phase_origin=>2,horizon=>456,
 idle_fillers=>[{text=>'nop',cycles=>2},{text=>'bit.z timing_scratch',cycles=>3}],
 operations=>\@ops,
};
