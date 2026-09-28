# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exact three-pair / six-scanline stripe-refill cadence search.
#
# This problem deliberately models three consecutive two-scanline kernel pairs
# as one 458-cycle horizon.  That matters because the final two cycles of a pair
# are physically the first two cycles of the next pair; setup is allowed to
# cross that boundary instead of pretending each pair is an isolated box.
#
# The search asks a narrow but useful question: if the service path has a saved
# P1 byte and a precomputed next-pair P0 byte available, can the real certified
# all_five PF phases move all six inactive-buffer bytes in exactly six visible
# scanlines with no cadence growth?  The answer should be yes.  The two PF0
# source bytes need the renderer's hidden +1 enable baseline, so those more
# expensive 9-cycle copies live on P1 scanlines where the sprite is preserved
# in Y.  P0 tails stage only raw PF1/PF2 bytes before producing the P0 value
# that must survive in A into the next pair.
#
# This is NOT yet the complete rolling-refill proof.  Supplying the three
# `next_grp0` bytes without stripe-count-scaled storage is the next scheduling
# problem.  Keeping that prerequisite explicit is intentional: this input
# proves the six-byte beam schedule without hiding the remaining producer cost.

use strict;
use warnings;

my @ops;
my $PAIR=152;

sub pf_events0 {
   my($b)=@_;
   return [
      {name=>'PF0L',offset=>13,windows=>[[$b+15,$b+15]]},
      {name=>'PF1L',offset=>19,windows=>[[$b+21,$b+21]]},
      {name=>'PF2L',offset=>25,windows=>[[$b+27,$b+27]]},
      {name=>'PF0R',offset=>47,windows=>[[$b+49,$b+49]]},
      {name=>'PF1R',offset=>53,windows=>[[$b+55,$b+55]]},
      {name=>'PF2R',offset=>59,windows=>[[$b+61,$b+61]]},
   ];
}
sub pf_events1 {
   my($b)=@_;
   return [
      {name=>'PF0L',offset=>10,windows=>[[$b+95,$b+95]]},
      {name=>'PF1L',offset=>16,windows=>[[$b+101,$b+101]]},
      {name=>'PF2L',offset=>22,windows=>[[$b+107,$b+107]]},
      {name=>'PF0R',offset=>40,windows=>[[$b+125,$b+125]]},
      {name=>'PF1R',offset=>46,windows=>[[$b+131,$b+131]]},
      {name=>'PF2R',offset=>52,windows=>[[$b+137,$b+137]]},
   ];
}

my @p1_byte=(0,3,4); # PF0L, PF0R, PF1R: PF0 copies get +1 on P1 side
my @p0_byte=(1,2,5); # raw PF1L/PF2L/PF2R bytes fit the P0 rolling producer

for my $p (0..2) {
   my $b=$p*$PAIR;
   my $prev_tail=$p ? "p".($p-1)."_p0_tail_stage" : undef;
   push @ops, {
      id=>"p${p}_line0_pf",
      description=>"pair $p P1 scanline certified PF/object body",
      after=>defined($prev_tail)?[$prev_tail]:[],
      earliest=>$b+2,
      latest_end=>$b+61,
      asm=>[
         ['sta GRP0',3],
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
         ['ldy.z stripe_cache+1',3], ['sty PF1',3],
         ['ldy.z stripe_cache+2',3], ['sty PF2',3],
         ['lsr.zx object_masks+24,x',6],
         ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
         ['dec.z player1_y',5], ['sta PF0',3],
         ['ldy.z stripe_cache+4',3], ['sty PF1',3],
         ['ldy.z stripe_cache+5',3], ['sty PF2',3],
      ],
      events=>pf_events0($b),
   };
   push @ops, {
      id=>"p${p}_p1_stage",
      description=>"pair $p P1 service path stages inactive PF byte $p1_byte[$p]",
      after=>["p${p}_line0_pf"],
      earliest=>$b+62,
      latest_end=>$b+84,
      asm=>[
         ['ldy.z saved_grp1',3],
         ['lda.a next_stripe_pf+'.$p1_byte[$p],4],
         ($p1_byte[$p]==0 || $p1_byte[$p]==3 ? (['ora #1',2]) : ()),
         ['sta.z inactive_pf+'.$p1_byte[$p],3], ['tya',2],
         ['lsr.zx object_masks+25,x',6], ['sta GRP1',3],
      ],
      events=>[{name=>'GRP1',offset=>($p1_byte[$p]==0 || $p1_byte[$p]==3 ? 22 : 20),windows=>[[$b+84,$b+84]]}],
   };
   push @ops, {
      id=>"p${p}_line1_pf",
      description=>"pair $p P0 scanline certified PF/object body; absolute PF0R supplies the required +1 cycle",
      after=>["p${p}_p1_stage"],
      earliest=>$b+85,
      latest_end=>$b+137,
      asm=>[
         ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM1',3], ['sta PF0',3],
         ['lda.z stripe_cache+1',3], ['sta PF1',3],
         ['lda.z stripe_cache+2',3], ['sta PF2',3],
         ['ldy.z player0_y',3], ['dey',2], ['cpy.z object_masks+11',3], ['sty.z player0_y',3],
         ['lda.z stripe_cache+3',3], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3],
      ],
      events=>pf_events1($b),
   };
   push @ops, {
      id=>"p${p}_p0_tail_stage",
      description=>"pair $p tail stages raw inactive PF byte $p0_byte[$p] and loads precomputed P0 for the next pair",
      after=>["p${p}_line1_pf"],
      earliest=>$b+138,
      latest_end=>$b+153,
      asm=>[
         ['lda.a next_stripe_pf+'.$p0_byte[$p],4],
         ['sta.z inactive_pf+'.$p0_byte[$p],3],
         ['lda.z next_grp0',3],
         ['lsr.zx object_masks+26,x',6],
      ],
   };
}

return {
   name=>'all_five exact three-pair six-byte staging cadence',
   description=>'Three consecutive exact pairs stage all six PF bytes in six scanlines. Pair tails may cross into the next pair and deliberately prepare its GRP0 value.',
   line_cycles=>76,
   horizon=>458,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'nop.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
