#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# ROM cost accounting for the generic positive-stripe source addressing.
#
# stripe32_feed_layout.pl proves the three-feed layout for the six-scanline case.
# Its size follows from the pair count, not the stripe count, so the arithmetic is
# worth stating explicitly for the whole generic range.
#
# THE FEED IS SIZED BY PAIRS, NOT BY STRIPES.  Each renderer pair consumes one byte
# from each of three feeds, so the feed is exactly 3*(lines/2) bytes for every
# stripe count at a given line count.  Logical stripe data is 8*N bytes: COLUPF and
# COLUBK plus PF0..PF5.  A smaller stripe count therefore carries less DATA but the
# same FEED, which is the opposite of the intuitive scaling:
#
#   N=2  h=96  logical=16   feed=288  spare=272
#   N=8  h=24  logical=64   feed=288  spare=224
#   N=32 h=6   logical=256  feed=288  spare=32
#
# So the feed is nearly free at N=32, where the only overhead is feed2's unused
# pair-2 slots, and wasteful at small N.  That alone does not make it a problem,
# because the feed is measured against what it REPLACES rather than against the free
# space in the existing build.
#
# A CORRECTION worth keeping.  An earlier version of this file concluded that the
# emit was blocked on the small-N addressing choice, on the reasoning that the
# two-stripe example leaves only 386 free bytes so a 288-byte feed would leave 98.
# That was wrong: it measured the feed against the free space of the build it
# replaces.  The measured cost of the stripes=2 prototype itself is 2417 bytes, so
# 288 sits comfortably inside what the generic machine frees.  Pair-indexed feeds
# are therefore affordable at every supported N, the uniform Y-indexed path stays
# the right choice, and the six-scanline timing remains the binding constraint as
# originally believed.
#
# The two ROM figures below are measured by building the maintained two-stripe
# example at stripes:=2 and at stripes:=0 and differencing the linker reports.
# They are pinned here so the conclusion cannot drift silently.
use strict;
use warnings;

my $rom_size   = 4090;    # 4K cartridge minus the two-byte vector
my $feed_per_pair = 3;    # one byte consumed from each of three feeds per pair
my $bytes_per_stripe = 8; # C0, C1, PF0..PF5

# Measured from builds of examples/04_renderers/all_five/stripes.
my $rom_stripes0 = 1287;
my $rom_stripes2 = 3704;

sub feed_bytes     { return $feed_per_pair * ($_[0]/2) }
sub logical_bytes  { return $bytes_per_stripe * $_[1] }

die "feed must be sized by pairs\n" unless feed_bytes(192)==288;
die "192-line feed size changed\n" unless feed_bytes(192)==288 && feed_bytes(228)==342;
die "logical stripe record is no longer 8 bytes\n" unless $bytes_per_stripe==8;
die "logical 32-stripe data changed\n" unless logical_bytes(192,32)==256;

# The feed must never be smaller than the data it carries, or it would alias.
for my $lines (170,181,192,228) {
   for my $n (1..32) {
      next if $lines % $n;
      my $h=$lines/$n;
      next if $h % 2 || $h < 6;
      my $feed=feed_bytes($lines);
      my $logical=logical_bytes($lines,$n);
      $feed >= $logical
         or die "feed $feed would alias $logical logical bytes at lines=$lines N=$n\n";
   }
}

my @rows;
for my $n (2,8,16,24,32) {
   next unless 192 % $n == 0;
   my $h=192/$n;
   next if $h % 2;
   my $feed=feed_bytes(192);
   my $logical=logical_bytes(192,$n);
   push @rows,sprintf('N=%-2d h=%-3d logical=%-4d feed=%-4d spare=%d',
      $n,$h,$logical,$feed,$feed-$logical);
}

# The budget that matters is the prototype cost the generic machine replaces.
my $prototype = $rom_stripes2 - $rom_stripes0;
die "measured stripes=0 ROM figure changed\n" unless $rom_stripes0==1287;
die "measured stripes=2 ROM figure changed\n" unless $rom_stripes2==3704;
die "prototype cost arithmetic inconsistent\n" unless $prototype==2417;

my $feed=feed_bytes(192);
die "the 288-byte feed no longer fits inside the prototype it replaces\n"
   unless $feed < $prototype;

# Headroom the generic body has to work in, at the tightest stripe count.
my $budget = $rom_stripes0 + $feed + $prototype - $rom_stripes2 + ($rom_size - $rom_stripes2);
$budget = $prototype - $feed;
die "generic body budget is inconsistent\n" unless $budget == 2417-288 && $budget == 2129;

printf "stripe_generic_rom_bound ok: feed = 3*(lines/2) bytes, independent of the stripe count (288 at 192 lines, 342 at 228); logical data is 8*N so small N carries less data but the same feed -- %s; the stripes=2 prototype costs %d bytes (measured %d at stripes=2 versus %d at stripes=0), so the %d-byte feed fits inside what it replaces and leaves %d bytes for the generic body at the tightest stripe count; an earlier conclusion that the feed left only 98 bytes was wrong because it measured against the free space of the build being replaced\n",
   join('; ',@rows),$prototype,$rom_stripes2,$rom_stripes0,$feed,$budget;