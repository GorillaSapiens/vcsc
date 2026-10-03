#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Fixed-address RIOT layout bound for stripes=32 sparse transition events.
#
# Each player has at most two event incidences.  Give each incidence a fixed
# four-byte exact-cache slot: bytes 0..2 are the three special-stripe pixels;
# byte 3 is the following handoff-pair pixel.  For a P1-only event that fourth
# byte deliberately holds the P0 handoff pixel required by the one-player
# timing proof; for a dual event the P1/P0 incidence slots hold their matching
# handoff pixels.  Thus all timing-critical exact loads can remain three-cycle
# zero-page absolute loads; no packed/indexed event arena is required.
#
# Fixed event storage:
#   16 exact bytes     2 incidences/player * 4 bytes
#    8 pointer bytes   2 incidences/player * 2 bytes
#   16 composite bytes 4 union events * (ball/M1/M0/row shadow)
#    8 descriptor bytes 4 union events * (threshold, metadata)
# = 48 bytes.  Together with the 78-byte base+stripe state after the existing
# 11-byte beam-dead overlap and two live event-control bytes, RIOT is exactly
# 128 bytes.  Runtime descriptor sequencing/dispatch is proved separately.
use strict;
use warnings;

sub state {
   my($u,$h,$k)=@_;
   my$raw=$u-1-$k; my$q=$raw&255;
   return 'Z' unless $q<$h;
   return $raw<0?'A1':'A0';
}
sub mask {
   my($u,$h)=@_;
   my$m="\0"x4; my$n=0;
   for my$s(0..31){
      my@p=map{state($u,$h,3*$s+$_)}0..2;
      if(!($p[0] eq $p[1] && $p[1] eq $p[2])){vec($m,$s,1)=1;++$n;}
   }
   die "player event incidences exceed two: u=$u h=$h n=$n\n" if $n>2;
   return $m;
}
my%seen;
for my$u(0..255){for my$h(0..255){my$m=mask($u,$h);$seen{unpack('H8',$m)}=1;}}
my@m=map{pack('H8',$_)}keys%seen;
my$worst_union=0;
for my$a(@m){for my$b(@m){
   my$n=unpack('%32b*',$a|$b);
   die "union events exceed four: $n\n" if $n>4;
   $worst_union=$n if $n>$worst_union;
}}
die "union worst changed: $worst_union\n" unless $worst_union==4;

my$exact=2*2*4;
my$pointers=2*2*2;
my$composites=$worst_union*4;
my$descriptors=$worst_union*2;
my$event_storage=$exact+$pointers+$composites+$descriptors;
my$fixed=71+18-11;
my$live_control=2;
my$total=$fixed+$event_storage+$live_control;
die "fixed event storage changed: $event_storage != 48\n" unless $event_storage==48;
die "fixed stripe/base state changed: $fixed != 78\n" unless $fixed==78;
die "RIOT bound changed: $total != 128\n" unless $total==128;
print "stripe32_event_layout_bound ok: exact=16 pointer=8 composite=16 descriptor=8 fixed-event=48; base+stripe=78; live-control=2; RIOT=128; exact caches have fixed zero-page addresses\n";
