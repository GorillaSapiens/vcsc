#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Physical RIOT layout bound for stripes=32 player transitions plus packed-row
# advancement.
#
# VCSC reserves six physical RIOT bytes for the hardware stack. A raster that
# borrows S also saves the caller S in named private RAM.
#
# Boundary-color needs 16 stripe-hot bytes: two six-byte PF buffers plus two
# two-byte player service pointers. The 48-byte object-mask allocation has
# eleven beam-dead bytes after VBLANK. The compact-row cadence uses four of
# those bytes (offsets 36,39,42,45) for the exact P0 values needed only when a
# mask row ends after stripe pair0. Seven dead bytes remain available to overlap
# stripe-hot state, so fixed named storage is 71+16-7 = 80 bytes.
#
# stripe32_service_low_invariant.pl proves that each player's service-pointer
# low byte is constant for the complete frame. A service transition therefore
# queues only one next high byte, not a two-byte pointer. The exhaustive state
# model below separately counts every service event (including stripe-boundary
# changes) and mixed stripes (which alone need exact/cache composite data).
# Event storage is therefore:
#   16 exact bytes       two 4-byte mixed incidences/player
#    4 pointer highs     two one-byte service changes/player
#   12 composite bytes   <=4 mixed union events * ball/M1/M0
#    3 queued thresholds <=4 service union events after the live first one
# = 35 bytes.
#
# Threshold residue encodes P0-only/P1-only/dual, and the per-player incidence
# slot can be carried by control-flow state, so no descriptor metadata byte is
# required. Add one live threshold and one saved caller-S byte: named objects
# total 117. With six hardware-stack bytes the physical total is 123/128,
# leaving five RIOT bytes of real integration slack.
use strict;
use warnings;

sub state {
   my($u,$h,$k)=@_;
   my $raw=$u-1-$k;
   my $q=$raw&255;
   return 'Z' unless $q<$h;
   return $raw<0 ? 'A1' : 'A0';
}

my(%service_masks,%mixed_masks);
my($worst_player_service,$worst_player_mixed)=(0,0);
for my $u (0..255) {
   for my $h (0..255) {
      my @s=map { state($u,$h,$_) } 0..95;
      my(%service,%mixed);
      for my $k (1..95) {
         next if $s[$k] eq $s[$k-1];
         $service{int($k/3)}=1;
      }
      for my $stripe (0..31) {
         my @p=@s[3*$stripe..3*$stripe+2];
         $mixed{$stripe}=1 unless $p[0] eq $p[1] && $p[1] eq $p[2];
      }
      my $sn=keys %service;
      my $mn=keys %mixed;
      die "player service events exceed two: u=$u h=$h n=$sn\n" if $sn>2;
      die "player mixed incidences exceed two: u=$u h=$h n=$mn\n" if $mn>2;
      $worst_player_service=$sn if $sn>$worst_player_service;
      $worst_player_mixed=$mn if $mn>$worst_player_mixed;
      my($sm,$mm)=("\0"x4,"\0"x4);
      vec($sm,$_,1)=1 for keys %service;
      vec($mm,$_,1)=1 for keys %mixed;
      $service_masks{unpack('H8',$sm)}=1;
      $mixed_masks{unpack('H8',$mm)}=1;
   }
}
die "player service worst changed: $worst_player_service\n" unless $worst_player_service==2;
die "player mixed worst changed: $worst_player_mixed\n" unless $worst_player_mixed==2;

sub worst_union {
   my($set,$label)=@_;
   my @m=map { pack('H8',$_) } keys %$set;
   my $worst=0;
   for my $a (@m) {
      for my $b (@m) {
         my $n=unpack('%32b*',$a|$b);
         die "$label union exceeds four: $n\n" if $n>4;
         $worst=$n if $n>$worst;
      }
   }
   return $worst;
}
my $service_union=worst_union(\%service_masks,'service-event');
my $mixed_union=worst_union(\%mixed_masks,'mixed-event');
die "service union worst changed: $service_union\n" unless $service_union==4;
die "mixed union worst changed: $mixed_union\n" unless $mixed_union==4;

my $base_module_ram=71;
my $stripe_hot_state=16;
my $dead_mask_bytes=11;
my $row_cache_bytes=4;
my $hot_overlap=$dead_mask_bytes-$row_cache_bytes;
my $fixed=$base_module_ram+$stripe_hot_state-$hot_overlap;
my $exact=2*2*4;
my $pointer_highs=2*2;
my $composites=$mixed_union*3;
my $queued_thresholds=$service_union-1;
my $event_storage=$exact+$pointer_highs+$composites+$queued_thresholds;
my $live_threshold=1;
my $saved_caller_s=1;
my $named=$fixed+$event_storage+$live_threshold+$saved_caller_s;
my $hardware_stack=6;
my $physical=$named+$hardware_stack;
my $slack=128-$physical;

die "row cache count changed: $row_cache_bytes != 4\n" unless $row_cache_bytes==4;
die "remaining scratch overlap changed: $hot_overlap != 7\n" unless $hot_overlap==7;
die "fixed stripe/base state changed: $fixed != 80\n" unless $fixed==80;
die "event storage changed: $event_storage != 35\n" unless $event_storage==35;
die "named RIOT objects changed: $named != 117\n" unless $named==117;
die "physical RIOT bound changed: $physical != 123\n" unless $physical==123;
die "RIOT slack changed: $slack != 5\n" unless $slack==5;
print "stripe32_event_layout_bound ok: service-union=4 mixed-union=4; row-cache=4 inside mask scratch; hot-overlap=7 fixed=80; exact=16 pointer-high=4 composite=12 queued-threshold=3 event=35; live-threshold=1 saved-S=1 named=117; hardware-stack=6 physical=123/128 slack=5\n";
