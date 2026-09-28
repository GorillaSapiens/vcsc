# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Cycle-search input for the first stripes staging question.
#
# This is intentionally a *mechanism demonstration*, not yet an assertion that
# these are the final all_five instruction blocks.  It asks the scheduling tool
# the bandwidth question we care about: can six independent 7-cycle ROM->RAM
# copies be interleaved across three two-scanline kernel iterations while six
# beam-critical PF writes per scanline retain legal windows and the tail of each
# pair is available to prepare the following pair?
#
# The PF blocks include representative load+store assembly so the search input
# remains auditable as 6502 code rather than becoming a bag of anonymous cycle
# lengths.  Tightening this file to the exact generated all_five assembly is the
# next step after the generic solver itself is locked down.

use strict;
use warnings;

my $LINE = 76;
my @ops;

# Six scanlines = three two-line pairs.  The deliberately broad windows here
# express the TIA ordering constraints without freezing the current hand-tuned
# phase.  Each line gets left PF0/PF1/PF2 and right PF0/PF1/PF2 in order.
# The rightmost PF2 deadline leaves the scanline tail available for staging or
# next-pair setup.
for my $line (0..5) {
   my $base=$line*$LINE;
   my @spec=(
      [ pf0l => 'left PF0',  [20,34], 'lda stripe_pf0l', 'sta PF0' ],
      [ pf1l => 'left PF1',  [26,40], 'lda stripe_pf1l', 'sta PF1' ],
      [ pf2l => 'left PF2',  [32,46], 'lda stripe_pf2l', 'sta PF2' ],
      [ pf0r => 'right PF0', [45,57], 'lda stripe_pf0r', 'sta PF0' ],
      [ pf1r => 'right PF1', [51,63], 'lda stripe_pf1r', 'sta PF1' ],
      [ pf2r => 'right PF2', [57,69], 'lda stripe_pf2r', 'sta PF2' ],
   );
   my $prev;
   for my $s (@spec) {
      my($suffix,$desc,$win,$load,$store)=@$s;
      my $id="l${line}_$suffix";
      push @ops, {
         id=>$id,
         description=>"scanline $line $desc write",
         asm=>[ [$load,3], [$store,3] ],
         after=>defined($prev)?[$prev]:[],
         earliest=>$base,
         latest_end=>$base+75,
         events=>[{
            name=>uc($suffix),
            offset=>5,
            windows=>[[ $base+$win->[0], $base+$win->[1] ]],
         }],
      };
      $prev=$id;
   }
}

# One byte per scanline.  Each block is the real seven-cycle copy shape we want
# to hide: absolute ROM load plus zero-page RAM store.  The copy for scanline N
# may occur anywhere after that line's PF duties start and before the end of the
# line.  This deliberately permits pair-tail work: e.g. line 1's copy can sit at
# cycles 140..146 and thereby prepare state consumed by the pair beginning at
# cycle 152.
for my $line (0..5) {
   my $base=$line*$LINE;
   push @ops, {
      id=>"stage$line",
      description=>"stage inactive PF byte $line while scanline $line is live",
      asm=>[
         ["lda next_stripe_pf+$line",4],
         ["sta inactive_pf+$line",3],
      ],
      earliest=>$base,
      latest_end=>$base+75,
   };
}

return {
   name=>'all_five six-scanline stripe staging bandwidth',
   description=>
      'Three two-line iterations with six beam-critical PF writes per line and one 7-cycle staging copy per scanline. Pair-tail cycles may prepare the following pair.',
   line_cycles=>$LINE,
   horizon=>6*$LINE,
   operations=>\@ops,
};
