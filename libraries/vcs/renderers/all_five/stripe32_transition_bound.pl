#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Bound the exceptional player-state work for fixed 32 x 3-pair stripes.
#
# A player's activity is `q < height` for a uint8 q that decrements once per
# two-scanline pair.  Across 96 pairs, a three-pair stripe is "mixed" only when
# one of the two activity transitions falls inside that stripe.  Exhaustion of
# all 256x256 q/height states proves a single player can therefore require at
# most two mixed stripes.  Two independent players require at most four stripe
# indices in their union.  The other >=28 stripes can use one uniform service
# pointer per player for all three pairs.
use strict;
use warnings;
my $worst_one=0;
my @masks;
my %seen;
for my $q0 (0..255) {
   for my $h (0..255) {
      my $mask="\0" x 4;
      my $mixed=0;
      for my $s (0..31) {
         my @a=map { ((($q0-(3*$s+$_))&255) < $h) ? 1 : 0 } 0..2;
         if (!($a[0]==$a[1] && $a[1]==$a[2])) {
            vec($mask,$s,1)=1;
            ++$mixed;
         }
      }
      die "one player exceeds two mixed stripes q=$q0 h=$h mixed=$mixed\n" if $mixed>2;
      $worst_one=$mixed if $mixed>$worst_one;
      $seen{unpack('H8',$mask)}=1;
   }
}
$worst_one==2 or die "single-player mixed-stripe worst case changed: $worst_one\n";
@masks=map { pack('H8',$_) } keys %seen;
my $worst_union=0;
for my $a (@masks) {
   for my $b (@masks) {
      my $u=$a | $b;
      my $n=unpack('%32b*',$u);
      die "two players exceed four mixed stripes: $n\n" if $n>4;
      $worst_union=$n if $n>$worst_union;
   }
}
$worst_union==4 or die "dual-player mixed-stripe worst case changed: $worst_union\n";
print "stripe32_transition_bound ok: one<=2 union<=4 uniform>=28 stripes\n";
