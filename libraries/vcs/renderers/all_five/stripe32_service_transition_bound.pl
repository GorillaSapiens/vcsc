#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exhaustive service-state transition bound for the common-Y stripes=32 path.
#
# Pair k uses q=(public_y-1-k)&255.  Service state is Z when q>=height,
# A0 for active pre-wrap graphics, and A1 for active post-wrap graphics.
# VBLANK installs the state for pair zero.  During the 96 visible pairs there
# can be at most two subsequent state changes/player.  A change at k%3==0 is a
# stripe-boundary change and needs no three-byte exact cache; a change at
# k%3==1/2 makes that stripe mixed and may be rendered from a three-byte exact
# cache, then the service high byte is installed for the final state.
#
# This deliberately counts boundary changes that the older mixed-stripe-only
# bound did not count.  Two players still have at most four union event stripes.
use strict;
use warnings;

sub state {
   my($u,$h,$k)=@_;
   my $raw=$u-1-$k;
   my $q=$raw&255;
   return 'Z' unless $q<$h;
   return $raw<0 ? 'A1' : 'A0';
}

my($worst_changes,$worst_mixed,$worst_boundary,$worst_events)=(0,0,0,0);
my %event_masks;
my %mixed_masks;
my %transition_patterns;
for my $u (0..255) {
   for my $h (0..255) {
      my @s=map { state($u,$h,$_) } 0..95;
      my(@changes,%mixed,%boundary,%events);
      for my $k (1..95) {
         next if $s[$k] eq $s[$k-1];
         push @changes,$k;
         my $stripe=int($k/3);
         $events{$stripe}=1;
         if (($k%3)==0) { $boundary{$stripe}=1; }
         else           { $mixed{$stripe}=1; }
      }
      for my $stripe (0..31) {
         my @p=@s[3*$stripe..3*$stripe+2];
         if (!($p[0] eq $p[1] && $p[1] eq $p[2])) {
            $mixed{$stripe}=1;
            $events{$stripe}=1;
            $transition_patterns{join(',',@p)}=1;
         }
      }
      die "player service changes exceed two u=$u h=$h n=".@changes."\n"
         if @changes>2;
      die "player event stripes exceed two u=$u h=$h n=".keys(%events)."\n"
         if keys(%events)>2;
      $worst_changes=@changes if @changes>$worst_changes;
      $worst_mixed=keys(%mixed) if keys(%mixed)>$worst_mixed;
      $worst_boundary=keys(%boundary) if keys(%boundary)>$worst_boundary;
      $worst_events=keys(%events) if keys(%events)>$worst_events;
      my($em,$mm)=("\0"x4,"\0"x4);
      vec($em,$_,1)=1 for keys %events;
      vec($mm,$_,1)=1 for keys %mixed;
      $event_masks{unpack('H8',$em)}=1;
      $mixed_masks{unpack('H8',$mm)}=1;
   }
}
die "worst service changes changed: $worst_changes\n" unless $worst_changes==2;
die "worst mixed stripes changed: $worst_mixed\n" unless $worst_mixed==2;
die "worst boundary stripes changed: $worst_boundary\n" unless $worst_boundary==2;
die "worst player event stripes changed: $worst_events\n" unless $worst_events==2;

my @m=map { pack('H8',$_) } keys %event_masks;
my $worst_union=0;
for my $a (@m) {
   for my $b (@m) {
      my $n=unpack('%32b*',$a|$b);
      die "two-player service-event union exceeds four: $n\n" if $n>4;
      $worst_union=$n if $n>$worst_union;
   }
}
die "service-event union worst changed: $worst_union\n" unless $worst_union==4;

my @want=sort qw(A0,A0,Z A0,Z,A1 A0,Z,Z Z,A0,A0 Z,A0,Z Z,A1,A1 Z,Z,A0 Z,Z,A1);
my @got=sort keys %transition_patterns;
die "mixed-state pattern set changed: got=@got\n" unless "@got" eq "@want";

# Keep the public rainbow fixture's four events explicit: this catches the
# exact boundary-event omission that motivated this proof.
sub event_desc {
   my($u,$h)=@_;
   my @s=map { state($u,$h,$_) } 0..95;
   my @out;
   for my $k (1..95) {
      next if $s[$k] eq $s[$k-1];
      push @out,sprintf('%d:%s',int($k/3),($k%3)?'mixed':'boundary');
   }
   return join(',',@out);
}
die "rainbow P0 event shape changed\n" unless event_desc(18,7) eq '3:mixed,6:boundary';
die "rainbow P1 event shape changed\n" unless event_desc(55,7) eq '16:boundary,18:mixed';

print "stripe32_service_transition_bound ok: service changes/player<=2, event stripes/player<=2, two-player union<=4; boundary changes are counted separately from mixed stripes; rainbow fixture P0=3m/6b P1=16b/18m\n";
