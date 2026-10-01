#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Packing proof for the stripes=32 common-Y runtime source.
#
# Three page-contained 96-byte tables are enough. For current stripe s and
# next stripe n=(s+1)&31, pair Y values are 95-3s,94-3s,93-3s. The tables map:
#   feed0: pair0 C0,  pair1 C1,  pair2 PF4
#   feed1: pair0 PF0, pair1 PF2, pair2 PF5
#   feed2: pair0 PF1, pair1 PF3, pair2 unused
# Every timing-critical source is therefore an absolute,Y load with Y<=95 and
# a page-contained 96-byte object, so the read is fixed at four cycles.
use strict;
use warnings;

my @record;
for my $s (0..31) {
   # Unique symbolic-byte identities make accidental aliasing visible.
   $record[$s]=[ map { $s*8+$_ } 0..7 ];
}
my @feed=( [(undef)x96], [(undef)x96], [(undef)x96] );
my %seen;
for my $s (0..31) {
   my $n=($s+1)&31;
   my @y=(95-3*$s,94-3*$s,93-3*$s);
   my @map=(
      [0,$y[0],0], [1,$y[0],2], [2,$y[0],3],
      [0,$y[1],1], [1,$y[1],4], [2,$y[1],5],
      [0,$y[2],6], [1,$y[2],7],
   );
   for my $m (@map) {
      my ($t,$i,$f)=@$m;
      die "feed index out of range t=$t i=$i\n" if $i<0 || $i>95;
      die "duplicate feed slot t=$t i=$i\n" if $seen{"$t:$i"}++;
      $feed[$t][$i]=$record[$n][$f];
   }
}
for my $i (0..95) {
   die "feed0 hole at $i\n" unless defined $feed[0][$i];
   die "feed1 hole at $i\n" unless defined $feed[1][$i];
   # feed2's pair-2 residue is intentionally spare.
   if (($i%3)==0) {
      die "feed2 pair2 slot unexpectedly used at $i\n" if defined $feed[2][$i];
      $feed[2][$i]=0;
   } else {
      die "feed2 source hole at $i\n" unless defined $feed[2][$i];
   }
}
# Re-read every logical next-stripe field through the exact runtime addressing.
for my $s (0..31) {
   my $n=($s+1)&31;
   my ($y0,$y1,$y2)=(95-3*$s,94-3*$s,93-3*$s);
   my @got=(
      $feed[0][$y0], $feed[0][$y1],
      $feed[1][$y0], $feed[2][$y0],
      $feed[1][$y1], $feed[2][$y1],
      $feed[0][$y2], $feed[1][$y2],
   );
   for my $f (0..7) {
      die "roundtrip mismatch stripe=$s next=$n field=$f got=$got[$f] want=$record[$n][$f]\n"
         if $got[$f] != $record[$n][$f];
   }
}
print "stripe32_feed_layout ok: 3x96=288 bytes; Y=95..0 directly indexes all 256 logical stripe bytes; feed2 has 32 spare pair2 slots\n";
