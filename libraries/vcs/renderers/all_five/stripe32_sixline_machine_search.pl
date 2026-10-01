# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Six-scanline rolling stripe service for the 192-line all_five renderer.
#
# This is the zero-slack stripes=32 timing target.  It composes three copies of
# the authoritative 152-cycle visible pair, but P0/P1 are fed through service
# pointers with local indices 2,1,0 instead of mutating the caller's public Y
# coordinates.  Every pair copies two PF bytes into the inactive buffer.  The
# first two pairs also copy the next stripe's COLUPF/COLUBK bytes.
#
# X is allowed to carry the even PF byte after M1 has consumed the packed-row
# index.  The 6502 stack pointer shadows that row index during visible drawing;
# TSX restores it before M0.  No stack access occurs in the raster, so a future
# emitted implementation need only save SP before visible drawing and restore
# it before RTS.
#
# After the required PF/color/player work there are still four real five-cycle
# memory-RMW slots plus one real three-cycle store slot: 23 cycles per stripe.
# Those are deliberately named rolling-preparation work, not idle time.  They
# are the budget for preparing the next stripe's player-pointer state.

use strict;
use warnings;

my @ops;
my @even=(0,2,4);
my @odd =(1,3,5);
my @idx =(2,1,0);

for my $p (0..2) {
   my $b=$p*152;
   my $tag="p${p}_";
   my $prev=$p ? "p".($p-1)."_p0_feed" : undef;

   my @a=(
      ['sta GRP0',3],
      ['lda.z stripe_cache+0',3], ['adc #0',2], ['sta ENAM0',3], ['sta PF0',3],
      ['ldy.z stripe_cache+1',3], ['sty PF1',3],
      ['ldy.z stripe_cache+2',3], ['sty PF2',3],
      ['lsr.zx object_masks+24,x',6],
      ['lda.z stripe_cache+3',3], ['adc #0',2], ['sta ENABL',3],
   );
   if ($p < 2) {
      # Four-cycle ROM color load replaces four of the old five P1-Y cycles;
      # the absolute PF0 store contributes the fifth cycle.  Use A for the two
      # right PF loads so Y carries the color into the following P1 slot.
      push @a,
         ["ldy.a next_stripe_color+$p",4], ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } else {
      # Pair 2 has no third color byte.  Preserve A (the right PF0 value) while
      # spending the complete five-cycle hole on rolling-state preparation.
      push @a,
         ['dec.z rolling_prepare_a',5], ['sta PF0',3],
         ['ldy.z stripe_cache+4',3], ['sty PF1',3],
         ['ldy.z stripe_cache+5',3], ['sty PF2',3];
   }
   push @ops, {
      id=>$tag.'a_visible',
      description=>"pair $p scanline A fixed cadence; public P1 Y is not mutated",
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
   push @p1,["sty.z next_color_slot+$p",3] if $p < 2;
   push @p1,["ldy #$idx[$p]",2], ['lda.iy (p1_service_ptr),y',5];
   push @p1,['sta.z rolling_prepare_p1',3] if $p==2;
   # M1 must consume X while it is still the packed-row index.  Only then may X
   # become the even PF byte that survives across the B line.
   push @p1,
      ['lsr.zx object_masks+25,x',6],
      ["ldx.a next_stripe_pf+$even[$p]",4],
      ['sta GRP1',3];
   push @ops, {
      id=>$tag.'p1_feed',
      description=>"pair $p pointer-fed P1 plus even-PF/color staging",
      after=>[$tag.'a_visible'], earliest=>$b+60, latest_end=>$b+82,
      asm=>\@p1,
      events=>[{name=>'GRP1',offset=>22,windows=>[[$b+82,$b+82]]}],
   };

   push @ops, {
      id=>$tag.'b_left',
      description=>"pair $p scanline B fixed left-half TIA cadence",
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
      description=>"pair $p odd-PF copy plus five-cycle rolling-preparation slot",
      after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      asm=>[
         ["lda.a next_stripe_pf+$odd[$p]",4],
         ["sta.z inactive_pf+$odd[$p]",3],
         ["dec.z rolling_prepare_p0_$p",5],
         ['lda.z stripe_cache+3',3], ['sta PF0',3],
      ],
      events=>[{name=>'PF0R',offset=>17,windows=>[[$b+123,$b+123]]}],
   };

   push @ops, {
      id=>$tag.'b_right',
      description=>"pair $p scanline B fixed right PF1/PF2 cadence",
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
      description=>"pair $p commit even PF, pointer-fed P0, restore packed-row X from SP",
      after=>[$tag.'b_right'], earliest=>$b+136, latest_end=>$b+151,
      asm=>[
         ["stx.z inactive_pf+$even[$p]",3],
         ['lda.iy (p0_service_ptr),y',5],
         ['tsx',2],
         ['lsr.zx object_masks+26,x',6],
      ],
   };
}

return {
   name=>'all_five stripes32 six-scanline rolling machine',
   description=>'Three exact 152-cycle pairs copy six PF bytes and two arbitrary colors while pointer-fed P0/P1 leave public Y untouched; 23 cycles remain as real rolling-preparation instructions.',
   line_cycles=>76,
   phase_origin=>2,
   horizon=>456,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};
