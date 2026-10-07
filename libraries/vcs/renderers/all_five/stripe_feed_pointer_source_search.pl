# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Is the direct stripe record usable as the raster's next-stripe source?
#
# stripe32_record_common_index_bound.pl rejected ONE record-based form: X holding
# the record offset permanently, so that an arbitrary record byte could only be
# fetched with LDA abs,X while Y held the frame-wide player index.  A zero-page
# record pointer needs neither X nor a stripe index: the field offset is a
# compile-time constant in the unrolled body, so the read is LDY #off plus
# LDA/LDX (zp),Y.  That form was never searched, and it is the obvious way to
# avoid the pair-indexed feed, so this file searches it.
#
# It searches three single-read variants of the authoritative six-line machine
# (stripe32_sixline_machine_search.pl), selected with
# VCSC_STRIPE_POINTER_SOURCE:
#
#   color  the pair colour read in a_visible becomes LDY #p + LDY (rec),y
#   even   the even PF read in p1_feed becomes LDY #off + LDX (rec),y
#   odd    the odd PF read in p0_mid becomes LDY #off + LDA (rec),y
#
# The record field each variant reads is the SAME byte the pair-indexed feed would
# have supplied at that point: pair p takes colour field p, and PF fields 3p+2 and
# 3p+3 (stripe_generic_feed_source_bound.pl owns that layout).  So the comparison
# is faithful -- it swaps only the addressing, not the data.
#
# Each variant replaces exactly ONE absolute four-cycle feed read, so a failure
# is attributable to that read alone rather than to the sum.  All three fail,
# which is why the feed is load-bearing and not merely a convenience: the fixed
# 152-cycle pair cadence has no slack in any of the three windows a record read
# would have to occupy.
#
# Set VCSC_STRIPE_POINTER_SOURCE to a name; the scheduler is expected to report
# that the corresponding operation cannot fit.  See
# stripe_generic_feed_source_bound.pl, which owns the conclusion.
use strict;
use warnings;

my $which=$ENV{VCSC_STRIPE_POINTER_SOURCE}
   or die "VCSC_STRIPE_POINTER_SOURCE must be color, even or odd\n";
die "unknown VCSC_STRIPE_POINTER_SOURCE '$which'\n"
   unless $which eq 'color' || $which eq 'even' || $which eq 'odd';

# Real 6502 costs.  LDY #imm is 2; LDY (zp),Y and LDX (zp),Y are 6 because the
# indirect vector page is unknown at link time; LDA (zp),Y is 5.  The absolute
# reads they replace are 4 in the authoritative machine's model.
my %slot=(
   color => { off=>sub { $_[0] },     text=>['ldy.iy (rec_ptr),y',6] },
   even  => { off=>sub { 3*$_[0]+2 }, text=>['ldx.iy (rec_ptr),y',6] },
   odd   => { off=>sub { 3*$_[0]+3 }, text=>['lda.iy (rec_ptr),y',5] },
);
my $sel=$slot{$which};

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
      # The colour must reach PF0R on its ordinary cycle, so its read owns the
      # window between ENABL and PF0R.
      if ($which eq 'color') {
         push @a,['ldy #'.$sel->{off}->($p),2], $sel->{text};
      }
      else {
         push @a,["ldy.a next_stripe_color+$p",4];
      }
      push @a,
         ['sta.a PF0',4],
         ['lda.z stripe_cache+4',3], ['sta PF1',3],
         ['lda.z stripe_cache+5',3], ['sta PF2',3];
   } else {
      push @a,
         ['dec.z rolling_prepare_a',5], ['sta PF0',3],
         ['ldy.z stripe_cache+4',3], ['sty PF1',3],
         ['ldy.z stripe_cache+5',3], ['sty PF2',3];
   }
   push @ops, {
      id=>$tag.'a_visible',
      description=>"pair $p scanline A fixed cadence",
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
   # M1 must consume X while it is still the packed-row index; only then may the
   # even PF byte take X across to its commit at the end of the pair.
   push @p1,['lsr.zx object_masks+25,x',6];
   if ($which eq 'even') {
      push @p1,['ldy #'.$sel->{off}->($p),2], $sel->{text};
   }
   else {
      push @p1,["ldx.a next_stripe_pf+$even[$p]",4];
   }
   push @p1,['sta GRP1',3];
   push @ops, {
      id=>$tag.'p1_feed',
      description=>"pair $p pointer-fed P1 plus even-PF staging",
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

   my @m;
   if ($which eq 'odd') {
      push @m,['ldy #'.$sel->{off}->($p),2], $sel->{text};
   }
   else {
      push @m,["lda.a next_stripe_pf+$odd[$p]",4];
   }
   push @m,
      ["sta.z inactive_pf+$odd[$p]",3],
      ['dec.z rolling_prepare_p0',5],
      ['lda.z stripe_cache+3',3], ['sta PF0',3];
   push @ops, {
      id=>$tag.'p0_mid',
      description=>"pair $p odd-PF copy plus five-cycle rolling-preparation slot",
      after=>[$tag.'b_left'], earliest=>$b+106, latest_end=>$b+123,
      asm=>\@m,
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
   name=>"all_five stripes32 record-pointer $which source",
   description=>'One pair-indexed feed read replaced by a zero-page record pointer read with a compile-time field offset.',
   line_cycles=>76,
   phase_origin=>2,
   horizon=>456,
   idle_fillers=>[
      {text=>'nop',cycles=>2},
      {text=>'bit.z timing_scratch',cycles=>3},
   ],
   operations=>\@ops,
};