#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
#
# Historical geometry bound for the dual-uniform window-selection strategy.
#
# The hot service itself costs three pairs (six scanlines).  For a generic
# stripe boundary, both P0 and P1 must have a common three-pair window in which
# each player is independently uniform (all active or all inactive).  The
# current zero-tax candidate dispatch can start only on an ordinary pair and a
# service may not cross an eight-pair packed-row edge.
#
# Exhaustive uint8 y/height state proves:
#   * no legal ordinary-entry candidate subset fits in 13 pairs;
#   * 1,3,5,9,11 always works in 14 pairs => 28 scanlines;
#   * if row-boundary entry (start 8) is eventually made zero-tax, then
#     1,3,5,8,10 works in 13 pairs => 26 scanlines.
#
# This is no longer the generic stripe-height plan.  It remains an executable
# bound on the discarded strategy that searched ahead for a convenient uniform
# three-pair window.  The active stripes=32 design services every three pairs.

use strict;
use warnings;

sub bad_mask {
   my($y,$h,$starts)=@_;
   my $bad=0;
   for my $i (0..$#$starts) {
      my $s=$starts->[$i];
      my $a0=(($y-$s  ) & 255) < $h ? 1 : 0;
      my $a1=(($y-$s-1) & 255) < $h ? 1 : 0;
      my $a2=(($y-$s-2) & 255) < $h ? 1 : 0;
      $bad |= 1 << $i unless $a0==$a1 && $a1==$a2;
   }
   return $bad;
}

sub masks_for {
   my($starts)=@_;
   my %seen;
   for my $y (0..255) {
      for my $h (0..255) {
         $seen{bad_mask($y,$h,$starts)}=1;
      }
   }
   return [sort {$a<=>$b} keys %seen];
}

sub subset_works {
   my($subset,$masks)=@_;
   for my $a (@$masks) {
      for my $b (@$masks) {
         return 0 if (($a|$b)&$subset)==$subset;
      }
   }
   return 1;
}

sub candidate_universe {
   my($horizon,$allow_row_boundary)=@_;
   my @s;
   for my $start (1..$horizon-3) {
      my $r=$start & 7;
      next if $r>5;                    # three-pair service must stay in row
      next if !$allow_row_boundary && $r==0;
      push @s,$start;
   }
   return @s;
}

sub first_working_subset {
   my($horizon,$allow_row_boundary)=@_;
   my @starts=candidate_universe($horizon,$allow_row_boundary);
   return unless @starts;
   my $masks=masks_for(\@starts);
   my $limit=1<<@starts;
   my($best,$best_count);
   for my $subset (1..$limit-1) {
      my $count=unpack('%32b*',pack('L',$subset));
      next if defined($best_count) && $count>$best_count;
      next unless subset_works($subset,$masks);
      if (!defined($best_count) || $count<$best_count) {
         $best=$subset; $best_count=$count;
      }
   }
   return unless defined $best;
   my @chosen;
   for my $i (0..$#starts) {
      push @chosen,$starts[$i] if ($best>>$i)&1;
   }
   return \@chosen;
}

for my $h (3..13) {
   my $s=first_working_subset($h,0);
   die "ordinary-entry service unexpectedly fits in $h pairs: @{$s}\n" if $s;
}
my $safe=first_working_subset(14,0)
   or die "no ordinary-entry service set within 14 pairs\n";
join(',',@$safe) eq '1,3,5,9,11'
   or die "14-pair ordinary-entry set changed: ".join(',',@$safe)."\n";

for my $h (3..12) {
   my $s=first_working_subset($h,1);
   die "row-boundary service unexpectedly fits in $h pairs: @{$s}\n" if $s;
}
my $edge=first_working_subset(13,1)
   or die "no row-boundary-capable service set within 13 pairs\n";
join(',',@$edge) eq '1,3,5,8,10'
   or die "13-pair row-boundary set changed: ".join(',',@$edge)."\n";

sub min_equal_pairs {
   my($n)=@_;
   my $min=999;
   for my $i (0..$n-1) {
      my $lo=int($i*96/$n);
      my $hi=int(($i+1)*96/$n);
      my $h=$hi-$lo;
      $min=$h if $h<$min;
   }
   return $min;
}
my $safe_max=0;
my $edge_max=0;
for my $n (1..96) {
   my $m=min_equal_pairs($n);
   $safe_max=$n if $m>=14;
   $edge_max=$n if $m>=13;
}
$safe_max==6 or die "28-line equal-stripe maximum changed: $safe_max\n";
$edge_max==7 or die "26-line equal-stripe maximum changed: $edge_max\n";
min_equal_pairs(6)==16 or die "stripes=6 no longer has 16-pair equal stripes\n";
min_equal_pairs(7)==13 or die "stripes=7 no longer demonstrates the 13-pair boundary\n";

print "stripe_dual_uniform_window_bound ok: old-safe=28 old-edge=26 scanlines\n";
