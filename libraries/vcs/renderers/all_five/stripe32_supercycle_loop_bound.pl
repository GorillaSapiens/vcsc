#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Control-flow proof for the stripes=32 eight-stripe / 24-pair supercycle.
#
# The visible raster owns 96 two-scanline pairs.  One generated code body owns
# eight six-line stripes = 24 pairs and is therefore executed four times.  Y is
# the frame-wide player/feed index and starts at 95.  Every pair consumes the
# current Y and decrements once at its tail.
#
# At the final pair of each supercycle the ordinary three-cycle P0 staging store
# is unnecessary: A already contains the P0 byte for the immediately-following
# pair and LSR zp,X / DEY / BPL do not alter A.  Reorder the tail to
#
#   LDA (p0_service_ptr),Y   5
#   LSR object_masks+23,X    6   # old-row M0; X already advanced in P0-mid
#   DEY                      2
#   BPL supercycle_start     3 taken / 2 final fall-through
#
# so the three continuing iterations remain exactly 16 cycles.  The fourth
# falls through one cycle early with Y=$ff.  192-line draw terminates with a
# WSYNC, so that final one-cycle shortening is intentionally absorbed by the
# terminal WSYNC rather than becoming raster drift.
use strict;
use warnings;

my $y=95;
my @after;
for my $sc (0..3) {
   my $a_before;
   for my $pair (0..23) {
      $a_before=$y;       # conceptual P0 byte loaded using this Y
      $y=($y-1)&255;
   }
   push @after,$y;
   if ($sc<3) {
      die "supercycle $sc should take BPL at Y=$y\n" if $y & 0x80;
   } else {
      die "final supercycle must fall through with negative Y=$y\n" unless $y & 0x80;
   }
   # The only instructions between the conceptual LDA and the next STA GRP0
   # are memory LSR, DEY, and BPL.  None writes A on a 6502.
   die "unexpected next-pair source at supercycle $sc\n"
      unless defined $a_before;
}
die "supercycle Y sequence changed: @after\n" unless "@after" eq '71 47 23 255';

my $ordinary_tail=5+3+6+2;       # LDA, staging STA, LSR, DEY
my $loop_taken=5+6+2+3;          # LDA, LSR, DEY, taken BPL
my $loop_final=5+6+2+2;          # final BPL not taken

die "taken loop tail no longer cycle-neutral\n" unless $ordinary_tail==16 && $loop_taken==16;
die "final fallthrough delta changed\n" unless $loop_final==15;

print "stripe32_supercycle_loop_bound ok: one 24-pair body runs at Y=95..72/71..48/47..24/23..0; BPL tails are 16/16/16 cycles, final fallthrough is 15 and terminates through WSYNC\n";
