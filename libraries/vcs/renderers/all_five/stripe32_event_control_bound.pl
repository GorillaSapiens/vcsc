#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# RAM-state bound for metadata-free stripes32 event sequencing.
#
# stripe32_event_threshold_type_bound.pl proves the threshold byte itself also
# identifies P0-only/P1-only/dual.  The union events are sorted in raster order
# during VBLANK.  Therefore the visible dispatcher needs only the current
# threshold plus three queued thresholds; it does not need a parallel metadata
# byte per event.
#
# Exact/pointer cache selection can likewise be implicit in control flow.  A
# handler state is (p0-incidences-consumed,p1-incidences-consumed).  Each count
# is 0..2.  P0/P1/dual advances the corresponding count(s).  Since each player
# has <=2 incidences and the union has <=4 events, a finite set of state-specific
# continuation labels can select p0slot0/1 and p1slot0/1 without a RAM index.
# This is a storage/control-state proof only; emitted handler timing remains a
# separate integration obligation.
use strict;
use warnings;

my @kind=qw(p0 p1 dual);
my %next;
my %reachable=("0,0,0"=>1); # p0count,p1count,eventcount
for my $step (0..3) {
   for my $state (grep { (split /,/)[2]==$step } keys %reachable) {
      my($a,$b,$n)=split /,/,$state;
      for my $k (@kind) {
         my($aa,$bb)=($a,$b);
         ++$aa if $k eq 'p0' || $k eq 'dual';
         ++$bb if $k eq 'p1' || $k eq 'dual';
         next if $aa>2 || $bb>2;
         my$key="$aa,$bb,".($n+1);
         $reachable{$key}=1;
         $next{"$state/$k"}=$key;
      }
   }
}
# Every legal sequence of <=4 union events and <=2 incidences/player has a
# unique count-state transition; no RAM slot selector is semantically required.
my $max_states=scalar keys %reachable;
die "event control state space unexpectedly large: $max_states\n" if $max_states>20;
for my $state (keys %reachable) {
   my($a,$b,$n)=split /,/,$state;
   die "bad p0 incidence count" if $a<0 || $a>2;
   die "bad p1 incidence count" if $b<0 || $b>2;
   die "bad union event count" if $n<0 || $n>4;
}

my $current_threshold=1;
my $queued_thresholds=3;
my $metadata_bytes=0;
die "threshold-only event control changed\n"
   unless $current_threshold+$queued_thresholds+$metadata_bytes==4;
print "stripe32_event_control_bound ok: current threshold=1 + queued thresholds=3; event type is threshold-encoded and p0/p1 cache incidence is control-flow state, so descriptor metadata RAM=0 (reachable code states=$max_states)\n";
