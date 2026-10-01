#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Algebra/exhaustion for the frame-wide Y index used by stripes=32.
#
# Pair k uses Y=96-k for P1, then DEY, so P0 uses Y=95-k.  Both players'
# historical source row is (public_y-1-k)&255.  Before that source wraps, fixed
# service-pointer biases map the common Y onto the exact source address; after
# wrap the same pointer plus $0100 does.  Thus an active pointer changes only
# at the player's one possible source wrap, never once per stripe.
use strict;
use warnings;

for my $u (0..255) {
   for my $k (0..95) {
      my $want=($u-1-$k)&255;
      my $raw=$u-1-$k;
      my $wrap=$raw<0 ? 256 : 0;
      my $p1_bias=$u-97+$wrap;
      my $p0_bias=$u-96+$wrap;
      my $y1=96-$k;
      my $y0=95-$k;
      my $got1=$p1_bias+$y1;
      my $got0=$p0_bias+$y0;
      die "P1 mismatch u=$u k=$k want=$want got=$got1\n" if $got1!=$want;
      die "P0 mismatch u=$u k=$k want=$want got=$got0\n" if $got0!=$want;
      die "P1 index out of 1..96: $y1\n" if $y1<1 || $y1>96;
      die "P0 index out of 0..95: $y0\n" if $y0<0 || $y0>95;
   }
}
print "stripe32_common_index_bound ok: Y=P1 96..1 P0 95..0; active pointer changes only at wrap; 97-byte zero source covers inactive indexing\n";
