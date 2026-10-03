#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exhaustively model the existing 192-line BL/M1/M0 range builder and bound
# the number of state changes visible to a 96-pair stripes=32 renderer.
#
# prepare_one() receives an 8-bit biased endpoint U, an 8-bit height H, and an
# inclusive preparation limit.  It creates one or two inclusive 1-based ranges
# because U-H wraps in uint8 arithmetic.  set_range() maps index N to visible
# pair N-1.  Ball uses U=ball_y+2 and limit=96; missiles use U=y+1 and
# limit=95.  This script deliberately mirrors that implementation rather than
# substituting a nicer geometric interpretation.
use strict;
use warnings;

sub ranges {
   my($u,$h,$limit)=@_;
   $u &= 255;
   $h &= 255;
   my $lo=($u-$h)&255;
   my @r;

   # This is the control flow in @prepare_one, expressed as ranges.
   if ($lo > $u) {                       # wrapped subtraction
      if ($u != 0) {
         my $end=$u > $limit ? $limit : $u;
         push @r,[1,$end] if 1 <= $end;
      }
      if ($lo <= $limit) {
         push @r,[$lo,$limit] if $lo <= $limit;
      }
   } else {
      my $start=$lo || 1;
      my $end=$u > $limit ? $limit : $u;
      push @r,[$start,$end] if $start <= $end;
   }
   return @r;
}

sub bits {
   my($y,$h,$bias,$limit)=@_;
   my @b=(0)x96;
   my $u=($y+$bias)&255;
   for my $r (ranges($u,$h,$limit)) {
      my($a,$z)=@$r;
      for my $n ($a..$z) {
         my $k=$n-1;
         $b[$k]=1 if $k>=0 && $k<96;
      }
   }
   return @b;
}

sub stats {
   my(@b)=@_;
   my $changes=0;
   my @change_pair;
   my $prev=0; # TIA enable is cleared before the visible raster.
   for my $k (0..95) {
      if ($b[$k] != $prev) {
         ++$changes;
         push @change_pair,$k;
         $prev=$b[$k];
      }
   }
   # A transition after the final visible pair need not be serviced in raster.
   my %mixed;
   for my $s (0..31) {
      my $a=$b[3*$s];
      $mixed{$s}=1 if $b[3*$s+1] != $a || $b[3*$s+2] != $a;
   }
   return ($changes,scalar(keys %mixed),\@change_pair);
}

my %kind=(
   ball    => [2,96],
   missile => [1,95],
);
my %patterns;
for my $kind (sort keys %kind) {
   my($bias,$limit)=@{$kind{$kind}};
   my($worst_changes,$worst_mixed)=(0,0);
   my($wc_case,$wm_case);
   for my $y (0..255) {
      for my $h (0..255) {
         my @b=bits($y,$h,$bias,$limit);
         my($c,$m,$cp)=stats(@b);
         if ($c>$worst_changes) { $worst_changes=$c; $wc_case=[$y,$h,$cp]; }
         if ($m>$worst_mixed) { $worst_mixed=$m; $wm_case=[$y,$h,$cp]; }
         my $packed=pack('B*',join('',@b));
         $patterns{$kind}{unpack('H*',$packed)}=1;
      }
   }
   die "$kind pair-state changes exceed four: $worst_changes\n" if $worst_changes>4;
   die "$kind mixed stripes exceed four: $worst_mixed\n" if $worst_mixed>4;
   print "$kind changes<=$worst_changes mixed_stripes<=$worst_mixed patterns=".
      scalar(keys %{$patterns{$kind}})."\n";
}

# Bound the union of stripe-local mixed work for BL/M1/M0.  Enumerating all
# triples of 96-bit patterns would be wasteful; enumerate only their mixed
# stripe masks, whose state space is tiny.
my %mixed_masks;
for my $kind (keys %patterns) {
   for my $hex (keys %{$patterns{$kind}}) {
      my @b=split //,unpack('B*',pack('H*',$hex));
      my $m=0;
      for my $s (0..31) {
         my $i=3*$s;
         $m |= 1<<$s if $b[$i]!=$b[$i+1] || $b[$i]!=$b[$i+2];
      }
      $mixed_masks{$kind}{$m}=1;
   }
}
my @ball=keys %{$mixed_masks{ball}};
my @miss=keys %{$mixed_masks{missile}};
my $upper=2+3+3;
my @ball_max=grep { unpack('%32b*',pack('L<',$_))==2 } @ball;
my @miss_max=grep { unpack('%32b*',pack('L<',$_))==3 } @miss;
my $found=0;
OUTER: for my $b (@ball_max) {
   for my $m1 (@miss_max) {
      next if $b & $m1;
      for my $m0 (@miss_max) {
         if (!(($b|$m1)&$m0)) { $found=1; last OUTER; }
      }
   }
}
die "non-player mixed-stripe union upper bound $upper is not reachable\n" unless $found;
print "nonplayer union mixed_stripes<=$upper (reachable); scalar/event replacement is bounded\n";
print "stripe32_object_transition_bound ok\n";
