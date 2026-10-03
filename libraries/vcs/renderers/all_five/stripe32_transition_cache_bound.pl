#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Exhaustive shape/budget bound for sparse player transition stripes in the
# frame-wide-Y stripes=32 machine.
#
# Pair k consumes q=(public_y-1-k)&255.  A player is active when q<height;
# an active source before/after q wraps uses the two possible graphics-pointer
# biases proved by stripe32_common_index_bound.pl.  A three-pair stripe is
# special when those three pair states are not identical.  Such a stripe can
# be serviced by three exact cached bytes instead of changing the service
# pointer in the middle of the stripe.  The following stripe, when any, is
# uniform again until the next special stripe.
#
# Replacing all six five-cycle indirect player reads in a dual-player special
# stripe with three-cycle exact-cache reads recovers twelve cycles.  Added to
# the common-index machine's seventeen preparation cycles, that is 29 aggregate
# cycles.  The earlier four-LDA/STA aggregate pointer-copy accounting is now
# superseded by stripe32_transition_handoff_search.pl, which proves an exact
# fragmented schedule by extending each affected player cache one pair past the
# transition and temporarily using X/S as byte carriers.
#
# RAM also remains bounded.  Each player contributes at most two special
# stripes, so there are at most four player-event incidences.  Each incidence
# needs three special-stripe pixels plus one handoff-pair pixel (16 bytes total),
# and at most two precomputed next-pointer bytes (8 bytes total).  Each union
# event needs three composite enable/PF bytes plus one packed-row shadow byte
# (16 bytes total).  Thus the complete handoff payload is at most 40 bytes.
# Eleven beam-dead object-mask scratch bytes are available without increasing
# the base 71-byte module allocation.  With 18 bytes of stripe hot state
# (two PF buffers, two colors, and two service pointers), the bounded layout is
# 71+18+40-11 = 118 bytes, leaving ten RIOT bytes for event-selection state.
use strict;
use warnings;

sub pair_state {
   my ($u,$h,$k)=@_;
   my $raw=$u-1-$k;
   my $q=$raw&255;
   return 'Z' unless $q<$h;
   return $raw<0 ? 'A1' : 'A0';
}

my $worst_special=0;
my %special_masks;
for my $u (0..255) {
   for my $h (0..255) {
      # Use an actual 32-bit bit vector rather than a Perl integer.  Stripe 31
      # otherwise crosses the signed/native packing boundary on some hosts.
      my $mask="\0" x 4;
      my $special=0;
      my @stripe_state;
      for my $s (0..31) {
         my @p=map { pair_state($u,$h,3*$s+$_) } 0..2;
         if ($p[0] eq $p[1] && $p[1] eq $p[2]) {
            $stripe_state[$s]=$p[0];
         } else {
            $stripe_state[$s]='M';
            vec($mask,$s,1)=1;
            ++$special;
         }
      }
      die "player exceeds two special stripes u=$u h=$h n=$special\n"
         if $special>2;
      $worst_special=$special if $special>$worst_special;

      # Between special stripes every complete stripe has one stable service
      # pointer state.  Adjacent uniform stripes may differ; no uniform stripe
      # may itself contain an activity or wrap transition.
      for my $s (0..31) {
         next if $stripe_state[$s] eq 'M';
         my @p=map { pair_state($u,$h,3*$s+$_) } 0..2;
         die "uniform stripe changed internally u=$u h=$h s=$s\n"
            unless $p[0] eq $p[1] && $p[1] eq $p[2];
      }
      $special_masks{unpack('H8',$mask)}=1;
   }
}
die "single-player special worst case changed: $worst_special\n"
   unless $worst_special==2;

my @masks=map { pack('H8',$_) } keys %special_masks;
my $worst_union=0;
for my $a (@masks) {
   for my $b (@masks) {
      my $n=unpack('%32b*',$a|$b);
      die "two players exceed four special stripes: $n\n" if $n>4;
      $worst_union=$n if $n>$worst_union;
   }
}
die "dual-player special union changed: $worst_union\n" unless $worst_union==4;

# Consecutive union events may form a run.  Treating a run as one cached
# transition block avoids needing to reload the next event threshold between
# adjacent special stripes.  With at most four union bits, both the maximum
# run length and maximum number of separated runs are four; verify the actual
# reachable mask family rather than relying only on that trivial count bound.
my $worst_run=0;
my $worst_runs=0;
for my $a (@masks) {
   for my $b (@masks) {
      my $u=$a|$b;
      my ($run,$best,$runs,$inside)=(0,0,0,0);
      for my $s (0..31) {
         if (vec($u,$s,1)) {
            ++$run;
            $best=$run if $run>$best;
            if (!$inside) { ++$runs; $inside=1; }
         } else {
            $run=0;
            $inside=0;
         }
      }
      $worst_run=$best if $best>$worst_run;
      $worst_runs=$runs if $runs>$worst_runs;
   }
}
die "dual-player consecutive special run changed: $worst_run\n" unless $worst_run==4;
die "dual-player separated special run count changed: $worst_runs\n" unless $worst_runs==4;

# At most two special stripes/player.  The old three-byte-only cache bound is
# retained, then extended by one exact handoff byte per player-event incidence.
my $special_player_payload=2*2*3;
my $incidences=2*2;
my $handoff_player_payload=$incidences;
my $exact_player_payload=$special_player_payload+$handoff_player_payload;
my $pointer_payload=$incidences*2;
my $union_event_payload=$worst_union*(3+1);
my $handoff_payload=$exact_player_payload+$pointer_payload+$union_event_payload;
my $ordinary_prep=17;
my $cache_recovery=6*(5-3);
my $special_budget=$ordinary_prep+$cache_recovery;
my $base_module_ram=71;
my $stripe_hot_state=18;
my $scratch_overlap=11;
my $bounded_ram=$base_module_ram+$stripe_hot_state+$handoff_payload-$scratch_overlap;
die "special aggregate budget changed: $special_budget != 29\n"
   unless $special_budget==29;
die "special player payload changed: $special_player_payload != 12\n"
   unless $special_player_payload==12;
die "extended exact player payload changed: $exact_player_payload != 16\n"
   unless $exact_player_payload==16;
die "transition handoff payload changed: $handoff_payload != 40\n"
   unless $handoff_payload==40;
die "bounded stripes32 RAM changed: $bounded_ram != 118\n"
   unless $bounded_ram==118;
die "bounded stripes32 RAM exceeds RIOT: $bounded_ram\n" if $bounded_ram>128;

print "stripe32_transition_cache_bound ok: one<=2 special stripes, union<=4, run<=4, runs<=4, special pixels<=12 bytes, extended exact-player<=16, complete handoff payload<=40, bounded RIOT=118; exact fragmented handoff schedule proved separately\n";
