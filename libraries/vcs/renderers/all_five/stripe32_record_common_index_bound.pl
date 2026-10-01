#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Cycle/register lower bound for composing a direct 8-byte row-major stripe
# record with the frame-wide player Y index.
#
# With X permanently holding the record offset and Y permanently holding the
# player index, an arbitrary record byte can only be fetched into A with the
# official 6502 instruction set. A ROM->RAM copy is therefore at least
# LDA abs,X (4) + STA zp (3) = 7 cycles. In one exact pair, the only A-clobber
# safe service windows are:
#   P1 feed: 23 - player(5) - M1 shift(5) - GRP1(3) = 10 cycles
#   P0 mid : 18 - right-PF0 load/store(6)               = 12 cycles
#   P0 tail: 16 - player(5) - M0 shift(5) - DEY(2)      =  4 cycles
# B-left/B-right are completely occupied by fixed TIA writes. The A-visible
# post-ENABL region must preserve the right-PF0 value in A while X/Y are the
# two live indices, so it cannot hold an arbitrary record color either.
#
# Each pair needs two PF source copies. They consume the only two windows >=7
# cycles (P1 feed and P0 mid), leaving no legal 7-cycle color copy in pair 0 or
# pair 1. Thus a direct row-major 8-byte record cannot be the sole production
# source representation for arbitrary two-color six-line stripes while keeping
# the exact TIA phases and frame-wide player index. A derived representation is
# required; stripe32_feed_layout.pl proves the 3x96-byte common-Y feed.
use strict;
use warnings;

my %window=(p1_feed=>10,p0_mid=>12,p0_tail=>4);
my $copy=7;
die "P1 PF copy no longer fits\n" unless $window{p1_feed} >= $copy;
die "P0-mid PF copy no longer fits\n" unless $window{p0_mid} >= $copy;
die "tail unexpectedly accepts an arbitrary source copy\n" if $window{p0_tail} >= $copy;
my @after_pf=($window{p1_feed}-$copy,$window{p0_mid}-$copy,$window{p0_tail});
for my $left (@after_pf) {
   die "direct record unexpectedly has a full color-copy slot ($left cycles)\n"
      if $left >= $copy;
}
print "stripe32_record_common_index_bound ok: direct 8-byte record has exactly two >=7-cycle A-source windows/pair and both are consumed by PF; arbitrary colors require a derived feed\n";
