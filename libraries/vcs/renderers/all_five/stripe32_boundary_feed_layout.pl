#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Packing proof for the boundary-color stripes=32 source walk.
#
# A logical row is [C0,C1,PF0,PF1,PF2,PF3,PF4,PF5].  For current stripe s,
# Y pair values are 95-3s,94-3s,93-3s and every source describes stripe s+1.
# Pairs 0 and 1 consume all six PF bytes; pair 2 consumes both colors:
#   feed0: pair0 PF0, pair1 PF3, pair2 C0
#   feed1: pair0 PF1, pair1 PF4, pair2 C1
#   feed2: pair0 PF2, pair1 PF5, pair2 spare
# This makes the final pair refill-free so its shortened P1 path can switch
# COLUPF/COLUBK in horizontal blank without a separate stripe index.
use strict;
use warnings;

my @record;
for my $s (0..31) {
   $record[$s]=[ map { $s*8+$_ } 0..7 ];
}
my @feed=( [(undef)x96], [(undef)x96], [(undef)x96] );
my %seen;
for my $s (0..31) {
   my $n=($s+1)&31;
   my @y=(95-3*$s,94-3*$s,93-3*$s);
   my @map=(
      [0,$y[0],2], [1,$y[0],3], [2,$y[0],4],
      [0,$y[1],5], [1,$y[1],6], [2,$y[1],7],
      [0,$y[2],0], [1,$y[2],1],
   );
   for my $m (@map) {
      my($t,$i,$f)=@$m;
      die "feed index out of range t=$t i=$i\n" if $i<0 || $i>95;
      die "duplicate feed slot t=$t i=$i\n" if $seen{"$t:$i"}++;
      $feed[$t][$i]=$record[$n][$f];
   }
}
for my $i (0..95) {
   die "feed0 hole at $i\n" unless defined $feed[0][$i];
   die "feed1 hole at $i\n" unless defined $feed[1][$i];
   if (($i%3)==0) {
      die "feed2 pair2 slot unexpectedly used at $i\n" if defined $feed[2][$i];
      $feed[2][$i]=0;
   } else {
      die "feed2 source hole at $i\n" unless defined $feed[2][$i];
   }
}
for my $s (0..31) {
   my $n=($s+1)&31;
   my($y0,$y1,$y2)=(95-3*$s,94-3*$s,93-3*$s);
   my @got=(
      $feed[0][$y2], $feed[1][$y2],
      $feed[0][$y0], $feed[1][$y0], $feed[2][$y0],
      $feed[0][$y1], $feed[1][$y1], $feed[2][$y1],
   );
   for my $f (0..7) {
      die "roundtrip mismatch stripe=$s next=$n field=$f got=$got[$f] want=$record[$n][$f]\n"
         if $got[$f] != $record[$n][$f];
   }
}
print "stripe32_boundary_feed_layout ok: pairs0/1 carry PF0..PF5; pair2 carries C0/C1; 3x96=288 bytes; feed2 pair2 remains spare\n";
