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
# cycles.  Four precomputed pointer-byte copies cost 24 cycles (four times
# LDA.z+STA.z); one five-cycle RMW remains for event/control state.  This is an
# aggregate bound only: the next emitted problem is packing those operations
# into the real fragmented slots without moving any TIA appointment.
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

# At most two special stripes/player * three exact bytes/stripe.  The two
# players therefore need no more than twelve exceptional graphics bytes.
my $payload=2*2*3;
my $ordinary_prep=17;
my $cache_recovery=6*(5-3);
my $special_budget=$ordinary_prep+$cache_recovery;
my $pointer_handoff=4*(3+3);
my $control_rmw=5;
die "special aggregate budget changed: $special_budget != 29\n"
   unless $special_budget==29;
die "pointer/control aggregate no longer closes: $pointer_handoff+$control_rmw != $special_budget\n"
   unless $pointer_handoff+$control_rmw==$special_budget;

print "stripe32_transition_cache_bound ok: one<=2 special stripes, union<=4, exact player payload<=${payload} bytes; special aggregate 29=24 pointer+5 control cycles; fragmented slot packing remains\n";
