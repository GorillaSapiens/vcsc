#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Event-threshold payload proof for the stripes=32 common-Y selector.
#
# Pair-2 Y on stripe s is 93-3*s.  Event stripe e>0 is selected by pair 2 of
# stripe e-1, where Y=96-3*e.  Any threshold in Y+1..Y+3 clears carry there,
# while the immediately earlier selector has Y+3 and therefore still leaves
# carry set.  Because the pretrigger Y is divisible by three, those three
# equally valid threshold values have residues 1,2,0 modulo three.  The value
# itself can therefore encode the event kind without an extra type byte:
#   residue 1 => P0-only, residue 2 => P1-only, residue 0 => dual.
# Stripe zero has no predecessor and is selected directly by VBLANK.
use strict;
use warnings;

my @kind = qw(p0 p1 dual);
my %residue = (p0=>1, p1=>2, dual=>0);
for my $e (1..31) {
   my $pre=96-3*$e;
   for my $kind (@kind) {
      my $want=$residue{$kind};
      my ($threshold)=grep { ($_%3)==$want } ($pre+1..$pre+3);
      die "no threshold e=$e kind=$kind\n" unless defined $threshold;
      die "threshold out of uint8 e=$e kind=$kind t=$threshold\n"
         if $threshold<4 || $threshold>96;
      die "threshold residue mismatch e=$e kind=$kind t=$threshold\n"
         unless ($threshold%3)==$want;
      for my $s (0..$e-1) {
         my $y=93-3*$s;
         my $carry=$y >= $threshold ? 1 : 0;
         if ($s<$e-1) {
            die "early clear e=$e kind=$kind s=$s y=$y t=$threshold\n"
               unless $carry;
         } else {
            die "target retained carry e=$e kind=$kind s=$s y=$y t=$threshold\n"
               if $carry;
         }
      }
   }
}
print "stripe32_event_threshold_type_bound ok: each e>0 has three equivalent trigger thresholds; threshold mod 3 encodes p0/p1/dual with no extra type byte; stripe0 remains a VBLANK entry case\n";
