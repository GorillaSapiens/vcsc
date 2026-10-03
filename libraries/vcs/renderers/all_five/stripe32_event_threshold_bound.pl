#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Carry-threshold proof for one-stripe-ahead stripes=32 event selection.
#
# Pair-2 Y for stripe s is 93-3*s.  A special stripe e>0 must be selected by
# pair 2 of stripe e-1 so the next stripe can enter its cached path from pair 0.
# The pretrigger Y is 96-3*e; compare it with threshold=pretrigger+1=97-3*e.
# CPY therefore leaves carry set on every earlier selector stripe and clears it
# exactly on e-1.  Event stripe zero has no predecessor and is selected once by
# VBLANK before visible drawing starts.
#
# Loads, stores, TSX/TXS, transfers, NOP and DEY do not change carry, so the
# compare may live in the five-cycle pair-2 A preparation hole and a later BCS
# may occupy the three-cycle pair-2 P1 preparation hole.  The ordinary taken
# BCS costs three cycles; special fall-through costs two and gains one cycle.
use strict;
use warnings;
for my $e (1..31) {
   my $pre=96-3*$e;
   my $threshold=$pre+1;
   die "threshold out of uint8 e=$e t=$threshold\n" if $threshold<4 || $threshold>94;
   for my $s (0..$e-1) {
      my $y=93-3*$s;
      my $carry=$y >= $threshold ? 1 : 0;
      if ($s<$e-1) {
         die "early stripe cleared carry e=$e s=$s y=$y threshold=$threshold\n" unless $carry;
      } else {
         die "pretrigger stripe retained carry e=$e s=$s y=$y threshold=$threshold\n" if $carry;
      }
   }
}
print "stripe32_event_threshold_bound ok: stripe e>0 pretriggers at pair2 of e-1 with CPY (97-3e); C stays set earlier and clears exactly one stripe ahead; stripe0 is a VBLANK entry case\n";
