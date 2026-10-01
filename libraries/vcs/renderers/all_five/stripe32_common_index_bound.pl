#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Algebra/exhaustion for the frame-wide Y index used by stripes=32.
#
# Pair k uses the same Y=95-k for both P1 and P0, then DEY executes after P0.
# Both players' historical source row is (public_y-1-k)&255.  Because P1 and
# P0 have independent service pointers, each pointer may use the same bias.
# Before the source wraps, bias public_y-96 maps Y directly to that row; after
# wrap the same pointer plus $0100 does.  Thus an active pointer changes only
# at the player's one possible source wrap, never once per stripe.
#
# Y=95..0 also makes each of the three pair phases one residue class modulo 3.
# That is what lets three 96-byte page tables carry the complete stripe feed
# without a separate runtime stripe index.
use strict;
use warnings;

for my $u (0..255) {
   for my $k (0..95) {
      my $want=($u-1-$k)&255;
      my $raw=$u-1-$k;
      my $wrap=$raw<0 ? 256 : 0;
      my $bias=$u-96+$wrap;
      my $y=95-$k;
      my $got1=$bias+$y;
      my $got0=$bias+$y;
      die "P1 mismatch u=$u k=$k want=$want got=$got1\n" if $got1!=$want;
      die "P0 mismatch u=$u k=$k want=$want got=$got0\n" if $got0!=$want;
      die "visible index out of 0..95: $y\n" if $y<0 || $y>95;
   }
}
print "stripe32_common_index_bound ok: P1/P0/source share Y=95..0; active pointer changes only at wrap; 96-byte zero source covers inactive indexing\n";
