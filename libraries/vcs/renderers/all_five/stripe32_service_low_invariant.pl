#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Common-Y service-pointer low-byte invariant for stripes=32.
#
# For active pixels pair k uses Y=95-k and pointer graphics+public_y-96.  A
# wrapped active interval adds $0100, which changes only the high byte.  If the
# inactive source is a page-aligned 351-byte zero slab and its service pointer
# is constructed with the SAME low byte as the active pointer, then Y=0..95
# can read from every possible low-byte origin 0..255 without leaving the slab.
# Thus A0, A1, and Z all share one pointer-low value for the entire frame;
# every player state transition needs only a high-byte change.
use strict;
use warnings;

my $zero_len=351;
for my $glo (0..255) {
   for my $u (0..255) {
      my $active_base=$glo+$u-96;
      my $low=$active_base&255;
      for my $k (0..95) {
         my $y=95-$k;
         my $raw=$u-1-$k;
         my $want_active=($glo+(($raw)&255))&255;
         my $ptr=$active_base+($raw<0?256:0);
         my $got=($ptr+$y)&255;
         die "active low mapping mismatch glo=$glo u=$u k=$k\n" if $got!=$want_active;
         die "A0/A1 low changed glo=$glo u=$u k=$k\n" if (($ptr&255)!=$low);
      }
      for my $y (0..95) {
         my $off=$low+$y;
         die "zero slab too short low=$low y=$y off=$off\n" if $off >= $zero_len;
      }
   }
}
# Minimal contiguous page-based slab: starts can be all 256 low-byte residues;
# each needs 96 bytes, so offsets 0..(255+95) must be zero.
die "zero slab minimum changed\n" unless $zero_len==255+95+1;
print "stripe32_service_low_invariant ok: active A0/A1 and inactive Z share one service-pointer low byte; only high changes at transitions; page-aligned zero slab=351 bytes covers low 0..255 plus Y 0..95\n";
