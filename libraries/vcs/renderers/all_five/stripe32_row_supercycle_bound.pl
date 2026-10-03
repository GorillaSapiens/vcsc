#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Deterministic packed-mask row cadence for the stripes=32 six-line machine.
#
# One stripe is three two-scanline pairs; one packed BL/M1/M0 mask row is
# eight pairs.  gcd(3,8)=1, so their joint phase repeats after lcm(3,8)=24
# pairs = eight stripes.  The 96-pair raster is exactly four such supercycles.
# No runtime stripe or row modulus is therefore needed: one eight-stripe code
# supercycle can contain the three row-boundary variants at fixed locations
# and loop four times while frame-wide player/feed Y continues to count down.
#
# A stripes32-only compact mask view can address the three 12-byte object
# lanes as object_masks+0/+12/+24 indexed by row X=0..11.  This describes the
# same 36 live BL/M1/M0 bytes as the historical stride-four rows; byte 47 stays
# the public playfield-position alias.  The proof is address/layout algebra,
# not yet an emitted repacker.
use strict;
use warnings;

my $pairs=96;
my $stripe_pairs=3;
my $row_pairs=8;
my $super_pairs=24;
my $super_stripes=8;

sub gcd { my($a,$b)=@_; ($a,$b)=($b,$a%$b) while $b; return $a; }
sub lcm { my($a,$b)=@_; return $a/gcd($a,$b)*$b; }

die "joint cadence changed\n" unless lcm($stripe_pairs,$row_pairs)==$super_pairs;
die "raster no longer four supercycles\n" unless $pairs/$super_pairs==4;
die "supercycle stripe count changed\n" unless $super_pairs/$stripe_pairs==$super_stripes;

my @boundary;
for my $k (0..$pairs-2) { # no row handoff is needed after terminal pair 95
   next unless (($k+1)%$row_pairs)==0;
   my $stripe=int($k/$stripe_pairs);
   my $phase=$k%$stripe_pairs;
   push @boundary, [$k,$stripe,$phase,int($k/$super_pairs),$k%$super_pairs];
}
die "expected eleven visible row handoffs\n" unless @boundary==11;

# Each 24-pair supercycle has boundaries after local pairs 7,15,23.  The last
# raster supercycle omits the terminal 95->96 handoff, hence 3+3+3+2 = 11.
my @want=(7,15,23);
for my $sc (0..3) {
   my @got=map { $_->[4] } grep { $_->[3]==$sc } @boundary;
   my @expect=$sc==3 ? (7,15) : @want;
   die "supercycle $sc row-boundary shape changed: @got\n"
      unless "@got" eq "@expect";
}

# Within the eight stripe bodies, those boundaries are respectively after
# stripe2/pair1, stripe5/pair0, stripe7/pair2.  This exact pattern repeats.
my @first=grep { $_->[3]==0 } @boundary;
my @shape=map { [ $_->[1]%8, $_->[2] ] } @first;
my @shape_text=map { "s$_->[0]p$_->[1]" } @shape;
die "unexpected eight-stripe row shape: @shape_text\n"
   unless "@shape_text" eq 's2p1 s5p0 s7p2';

# Compact/transposed live-mask address proof.  Row X is 0..11; BL, M1, M0
# live in separate 12-byte lanes, so all three indexed addresses are unique,
# cover exactly 36 bytes, and remain inside the 48-byte object-mask allocation.
my %seen;
for my $row (0..11) {
   for my $lane (0,12,24) {
      my $off=$lane+$row;
      die "compact mask address outside object_masks: $off\n" if $off<0 || $off>=48;
      die "duplicate compact mask address: $off\n" if $seen{$off}++;
   }
}
die "compact mask live-byte count changed\n" unless keys(%seen)==36;

# The historical stride-four representation also has exactly these 36 live
# logical bytes.  Its fourth lane contributes 12 locations, with the final one
# (offset47) reserved for playfield_position; the other eleven are beam-dead
# after VBLANK, matching the existing scratch-overlap accounting.
my @old_live;
for my $row (0..11) { push @old_live, 4*$row,4*$row+1,4*$row+2; }
die "old live-byte count changed\n" unless @old_live==36;
my @old_lane=map { 4*$_+3 } 0..11;
die "old scratch lane changed\n" unless $old_lane[-1]==47 && @old_lane==12;

print "stripe32_row_supercycle_bound ok: 3-pair stripes x 8-pair mask rows => 24-pair/8-stripe supercycle repeated 4x; row handoffs s2p1,s5p0,s7p2; 11 visible handoffs; compact lanes 0/12/24 cover 36 mask bytes\n";
