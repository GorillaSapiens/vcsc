#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exhaustive RAM bound for the hybrid stripes=32 transition policy.
#
# A one-stripe run with exactly one changing player uses the sparse one-player
# handoff: three exact pixels for that player, one exact P0 handoff pixel, two
# pointer bytes, plus ball/PF0 and row-shadow composites = 8 bytes.
# A one-stripe run where both players change uses the dual handoff = 16 bytes.
# A run of two or more consecutive union-special stripes uses one cached block:
# both players are exact for all 3*r special pairs, both are exact for one
# handoff pair, and both final service pointers are installed once at run end.
# Its payload is 6*r + 10 bytes.  Two descriptor bytes per run are packed into
# the same arena, so capacity follows the reachable event shape rather than a
# sum of independent worst-case arrays.
use strict;
use warnings;

sub pair_state {
   my($u,$h,$k)=@_;
   my $raw=$u-1-$k;
   my $q=$raw&255;
   return 'Z' unless $q<$h;
   return $raw<0 ? 'A1' : 'A0';
}
sub special_mask {
   my($u,$h)=@_;
   my $m="\0"x4;
   for my $s (0..31) {
      my @p=map { pair_state($u,$h,3*$s+$_) } 0..2;
      vec($m,$s,1)=1 unless $p[0] eq $p[1] && $p[1] eq $p[2];
   }
   return $m;
}

my %seen;
for my $u (0..255) {
   for my $h (0..255) {
      my $m=special_mask($u,$h);
      $seen{unpack('H8',$m)}=1;
   }
}
my @masks=map { pack('H8',$_) } keys %seen;
my($worst_arena,$worst_payload,$worst_runs,$worst_union)=(0,0,0,0);
my $worst_desc='';
for my $a (@masks) {
   for my $b (@masks) {
      my $u=$a|$b;
      my($payload,$runs,$union)=(0,0,0);
      my @shape;
      my $s=0;
      while ($s<32) {
         if (vec($u,$s,1)) {
            my @flags;
            my $start=$s;
            while ($s<32 && vec($u,$s,1)) {
               my $f=(vec($a,$s,1)?1:0)|(vec($b,$s,1)?2:0);
               push @flags,$f;
               ++$s; ++$union;
            }
            my $r=@flags;
            my $cost;
            if ($r==1 && ($flags[0]==1 || $flags[0]==2)) {
               $cost=8;
            } elsif ($r==1) {
               $cost=16;
            } else {
               $cost=6*$r+10;
            }
            $payload+=$cost;
            ++$runs;
            push @shape,sprintf('%d:%s=%d',$start,join('',@flags),$cost);
         } else {
            ++$s;
         }
      }
      my $arena=$payload+2*$runs;
      if ($arena>$worst_arena) {
         ($worst_arena,$worst_payload,$worst_runs,$worst_union)=($arena,$payload,$runs,$union);
         $worst_desc=join(',',@shape);
      }
   }
}

my $base_module_ram=71;
my $stripe_hot_state=18;
my $scratch_overlap=11;
my $fixed=$base_module_ram+$stripe_hot_state-$scratch_overlap;
my $bounded=$fixed+$worst_arena;
die "hybrid arena changed: $worst_arena != 48 ($worst_desc)\n" unless $worst_arena==48;
die "hybrid payload changed: $worst_payload != 44\n" unless $worst_payload==44;
die "hybrid worst runs changed: $worst_runs != 2\n" unless $worst_runs==2;
die "hybrid worst union changed: $worst_union != 4\n" unless $worst_union==4;
die "hybrid RIOT bound changed: $bounded != 126\n" unless $bounded==126;
print "stripe32_transition_run_bound ok: packed event arena<=48 bytes (payload<=44 plus 2 bytes/run), fixed stripe/base=78, total RIOT<=126, leaving 2 live control bytes; worst=$worst_desc\n";
