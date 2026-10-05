#!/usr/bin/perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
# Generic positive-stripe geometry and legality authority for the all_five
# renderer.
#
# There is exactly ONE positive-stripe implementation.  It is generic in BOTH
# axes: TEMPLATE_stripes selects the stripe count and TEMPLATE_lines selects how
# many visible scanlines this renderer was allocated.  Positive stripes are NOT
# restricted to a 192-line renderer; a score/status component or a user-written
# component may consume part of the raster above or below the stripe region, so
# the stripe region only has to fit inside the allocated lines.
#
# Measured stripe minimum
# -----------------------
# The six-scanline rolling machine in stripe32_sixline_machine_search.pl is the
# zero-slack worst case: three two-scanline pairs per stripe.  Taller stripes
# only add slack.  A stripe below six scanlines is rejected outright, never
# rounded up.
#
# Pair geometry
# -------------
# A stripe of H scanlines occupies P=H/2 renderer pairs, so H must be even and
# P>=3.  The region of N stripes therefore covers N*P pairs.
#
# Body shape
# ----------
# One packed BL/M1/M0 object-mask row spans eight pairs, so the joint stripe/row
# phase repeats after lcm(P,8) pairs.  That supercycle is the largest body the
# runtime may loop.  Looping it is what keeps the frame free of any runtime
# stripe or row modulus, so supercycle length, stripes per supercycle, and
# repetition count are compile-time functions of (TEMPLATE_lines,
# TEMPLATE_stripes).
#
# Three region shapes are legal, and which one applies is reported rather than
# hidden:
#
#   exact     region is a whole multiple of the supercycle; the body loops a
#             whole number of times and nothing else is needed.
#   tail      the remainder is 0..7 pairs, which is exactly the partial-row
#             landing the maintained VCS_STRIPES2_CERT_TAIL0..7 certification
#             already covers, so the existing single cadence serves it.
#   single    the region is no larger than one supercycle, so the emitted body
#             is the whole region and never loops at all.
#
# A larger remainder is a partial supercycle, which this file reports as
# `partial` and leaves for an explicit scheduling decision rather than accepting
# or rejecting it silently.
#
# Region, not equality
# --------------------
# The stripe region is SUM(heights) scanlines.  It must be even, at least
# 6*N, and no larger than the allocated TEMPLATE_lines; any remainder belongs to
# composing components and is not this renderer's to schedule.  Because every
# height is even the region sum is even, so an odd TEMPLATE_lines can still be
# striped provided the region leaves the odd scanline to a composing component.
#
# Rejection is explicit
# ---------------------
# Odd heights, sub-minimum heights, and a region larger than the renderer are
# rejected by name.  Nothing is silently rounded or approximated.
use strict;
use warnings;

my $min_lines = 6;    # measured six-scanline minimum
my $row_pairs = 8;    # packed BL/M1/M0 mask row, in renderer pairs
my $min_p     = $min_lines / 2;
my $max_tail  = $row_pairs - 1;   # maintained 0..7 row-tail certification
my $max_stripes = 32;

sub gcd { my($a,$b)=@_; ($a,$b)=($b,$a%$b) while $b; return $a; }
sub lcm { my($a,$b)=@_; return $a/gcd($a,$b)*$b; }

die "stripe minimum is no longer six scanlines\n" unless $min_lines==6 && $min_p==3;
die "certified tail range changed\n" unless $max_tail==7;

# The maintained all_five line modes, including the two score-composable ones
# that deliberately leave part of the raster to another component.
my @modes=(170,181,192,228);

# classify(LINES, HEIGHTS) -> (legal, reason, plan)
sub classify {
   my($lines,@h)=@_;
   return (0,'no heights supplied',undef) unless @h;
   for my $v (@h) {
      return (0,"odd height $v",undef)         if $v % 2;
      return (0,"sub-minimum height $v",undef) if $v < $min_lines;
   }
   my $sum=0; $sum+=$_ for @h;
   return (0,"stripe region $sum exceeds allocated $lines scanlines",undef) if $sum > $lines;
   return (0,"stripe region $sum is odd",undef) if $sum % 2;

   # One generated body has one supercycle shape, so every height must share the
   # same joint stripe/row period.  Heights of six and twelve scanlines both give
   # a 24-pair supercycle and therefore may be mixed; five scanline pairs do not.
   my %super_of;
   $super_of{lcm($_/2,$row_pairs)}=1 for @h;
   return (0,'mixed heights need more than one stripe/row period',undef)
      if keys(%super_of)>1;
   my ($super)=(keys %super_of)[0];
   my $p=(sort { $a <=> $b } map { $_/2 } @h)[0];
   for my $v (@h) {
      my $q=$v/2;
      return (0,"height $v does not divide the $super-pair supercycle",undef)
         if $super % $q;
   }

   my $region = $sum/2;
   my $per_super = int($super/$p);
   my %plan=(p=>$p,super=>$super,per_super=>$per_super,region=>$region,loops=>0,reps=>1,tail=>0,shape=>'single');
   if ($region < $super) {
      # One body spans the region; it never loops.
      $plan{shape}='single';
   } else {
      my $reps=int($region/$super);
      my $tail=$region%$super;
      $plan{reps}=$reps; $plan{tail}=$tail;
      if ($tail==0) { $plan{shape}='exact'; }
      elsif ($tail<=$max_tail) { $plan{shape}='tail'; }
      else { $plan{shape}='partial'; }
      $plan{loops}=1;
   }
   return (1,'',\%plan);
}

# Equal-split geometry: LINES/N must be an even integer of at least six.
sub equal_split {
   my($lines,$n)=@_;
   return undef if $lines % $n;
   my $h=$lines/$n;
   return undef if $h % 2;
   return undef if $h < $min_lines;
   return $h;
}

# ------------------------------------------------------- equal split per mode
# N is capped at 32, so some divisors of a mode are out of range (228/38 is six
# scanlines but needs N=38), and some quotients are odd (228/12 is 19).
my %want=(
   170 => [1,5,17],
   181 => [],
   192 => [1,2,3,4,6,8,12,16,24,32],
   228 => [1,2,3,6,19],
);
my @report;
my %plan_for;
for my $lines (@modes) {
   my @legal;
   for my $n (1..$max_stripes) {
      my $h=equal_split($lines,$n);
      next unless defined $h;
      my($ok,$why,$plan)=classify($lines,($h)x$n);
      die "equal split $lines/$n passed equal_split but was rejected: $why\n" unless $ok;
      push @legal,$n;
      $plan_for{$lines}{$n}=$plan;
   }
   my $got=join(',',@legal);
   my $exp=join(',',@{$want{$lines}});
   die "equal-split set for lines=$lines changed: got '$got' want '$exp'\n" unless $got eq $exp;
   my %shape;
   $shape{$plan_for{$lines}{$_}{shape}}++ for @legal;
   push @report,sprintf('lines=%d equal N=%s [%s]',$lines,
      @legal ? $got : 'none (odd)',
      join(',',map { "$_:$shape{$_}" } sort keys %shape));
}

# The 192-line mode is the published stress family and must need no tail at all.
for my $n (sort { $a <=> $b } keys %{ $plan_for{192} }) {
   my $pl=$plan_for{192}{$n};
   die "192 N=$n unexpectedly needs shape $pl->{shape}\n" unless $pl->{shape} eq 'exact';
}

# 181 is odd so it can never take an equal split.  It is striped by leaving the
# odd scanline to a composing component: six thirty-line stripes fill 180 lines.
die "odd line mode unexpectedly has an equal split\n" if keys %{$plan_for{181} // {}};
my($ok181,$why181,$p181)=classify(181,(30)x6);
die "181-line six-stripe region rejected: $why181\n" unless $ok181;
die "181-line region shape changed\n"
   unless $p181->{shape} eq 'single' && $p181->{reps}==1 && $p181->{loops}==0;

# ----------------------------------------------------------- supplied regions
# A supplied table may mix heights as long as every height shares one
# stripe/row period.  Sixteen six-line plus eight twelve-line stripes are 24
# stripes over 192 lines and share the six-line period.
my($ok_mixed,$why_mixed,$pm)=classify(192,((6)x16,(12)x8));
die "supplied six/twelve height table rejected: $why_mixed\n" unless $ok_mixed;
die "mixed table period changed\n"
   unless $pm->{p}==3 && $pm->{super}==24 && $pm->{shape} eq 'exact'
       && $pm->{reps}==4 && $pm->{per_super}==8;

# ---------------------------------------------------------- (192,32) stress case
my $h32=equal_split(192,32);
die "192/32 no longer yields six scanlines\n" unless defined $h32 && $h32==6;
my $p32=$plan_for{192}{32};
die "192/32 supercycle shape changed\n"
   unless $p32->{p}==3 && $p32->{super}==24 && $p32->{shape} eq 'exact'
       && $p32->{reps}==4 && $p32->{per_super}==8 && $p32->{loops}==1 && $p32->{tail}==0;

# Taller stripes are never tighter than the six-scanline worst case.
for my $n (sort { $a <=> $b } keys %{ $plan_for{192} }) {
   die "192 N=$n has fewer pairs per stripe than the measured minimum\n"
      if $plan_for{192}{$n}{p} < 3;
}

# ---------------------------------------------------- tail certification reuse
# A 0..7 remainder is the maintained row-tail landing, so it must be reachable
# and must stay within the certified range.
my($ok_tail,$why_tail,$ptail)=classify(170,(10)x17);
die "170/17 rejected: $why_tail\n" unless $ok_tail;
die "170/17 shape changed\n" unless $ptail->{shape} eq 'tail';
die "170/17 tail out of certified range: $ptail->{tail}\n" unless $ptail->{tail}<=$max_tail;

# ----------------------------------------------------------------- rejections
my @reject=(
   [ 192,'odd height 5',                          5 ],
   [ 192,'sub-minimum height 4',                  4 ],
   [ 170,'stripe region 174 exceeds allocated 170 scanlines', (6)x29 ],
   [ 181,'stripe region 186 exceeds allocated 181 scanlines', (6)x31 ],
   [ 192,'mixed heights need more than one stripe/row period', (6)x30,10 ],
   [ 192,'mixed heights need more than one stripe/row period', 10,182 ],
   [ 192,'odd height 5',                          (5)x38,2 ],
);
for my $r (@reject) {
   my($lines,$want_reason,@h)=@$r;
   my($ok,$why)=classify($lines,@h);
   die "expected rejection: $want_reason\n" if $ok;
   die "rejection reason changed for '$want_reason': $why\n" unless $why eq $want_reason;
}

# A region only has to FIT: full, partial, and odd-mode regions are all legal,
# including a region that exactly fills 228 lines.
for my $case ([170,(10)x17],[192,(6)x30],[228,(6)x38],[192,((6)x16,(12)x8)],
              [192,(6)x32],[228,(12)x19]) {
   my($lines,@h)=@$case;
   my($ok,$why)=classify($lines,@h);
   die "legal region $lines/".scalar(@h)." rejected: $why\n" unless $ok;
}

printf "stripe_generic_geometry_bound ok: one generic implementation is generic in stripes and lines; min height 6 (P>=3), mask row 8 pairs, supercycle=lcm(P,8); %s; (192,32) gives h=6 P=3 super=24 x4 = 8 stripes/supercycle and needs no tail; region only has to fit inside TEMPLATE_lines so odd 181 and partial regions are strippable; a 0..7 remainder reuses the maintained row-tail certification; odd/sub-minimum/oversized/mixed-period heights rejected by name\n",
   join('; ',@report);