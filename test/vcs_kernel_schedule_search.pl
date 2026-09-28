#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_kernel_schedule_search ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $solver=File::Spec->catfile($repo,qw(libraries vcs renderers kernel_schedule_search.pl));
my $problem=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_stage_search.pl));
-x $solver or die "kernel schedule solver is not executable\n";
-f $problem or die "stripe schedule search input missing\n";

my($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$problem);
$rc==0 && !$sig or die "schedule search failed\n$out$err";
$out =~ /^solution 1 for all_five six-scanline stripe staging bandwidth$/m
   or die "schedule solution header missing\n$out";
$out =~ /stage0\s+stage inactive PF byte 0/m
   or die "first staging byte missing from schedule\n";
$out =~ /stage5\s+stage inactive PF byte 5/m
   or die "sixth staging byte missing from schedule\n";
$out =~ /line_cycles=76 horizon=456/
   or die "six-scanline horizon changed\n";
$err =~ /^searched=\d+ pruned_deadline=\d+ pruned_horizon=\d+ solutions=1\n\z/
   or die "unexpected solver statistics: $err";

# The exact active-player pair model pins all twelve PF writes to the maintained
# phases.  Its legal result must use the real self-hosted P1 service sequence.
my $exact=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pair_exact_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$exact);
$rc==0 && !$sig or die "exact pair search failed\n$out$err";
$out =~ /p1_sprite\[self_hosted\]/ or die "exact pair did not choose self-hosted staging\n$out";
$out =~ /event PF0L\s+@\s+15 \(0:15\)/ or die "exact pair lost first PF0 phase\n$out";
$out =~ /event PF2R\s+@\s+137 \(1:61\)/ or die "exact pair lost final PF2 phase\n$out";
$out =~ /line1_pf\[pf0r_absolute_plus1\]/
   or die "exact pair did not use absolute addressing as the required +1-cycle timing knob\n$out";
$out =~ /IDLE 2 cycles \(nop\/2\)/
   or die "exact pair did not materialize its two-cycle entry filler\n$out";

# The three-pair exact model uses pair tails as part of the following pair and
# must move all six PF bytes in six scanlines.  Its odd-numbered copies happen
# in the P0 tail before loading the already-precomputed P0 byte for the next
# pair, so A enters the next pair with the correct GRP0 value.
my $three=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_three_pair_exact_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$three);
$rc==0 && !$sig or die "three-pair exact search failed\n$out$err";
for my $n (0..5) {
   $out =~ /next_stripe_pf\+$n/ or die "three-pair exact search lost staged PF byte $n\n$out";
}
$out =~ /p2_p0_tail_stage/ or die "three-pair exact search did not use final pair tail\n$out";
$out =~ /line_cycles=76 horizon=458/ or die "three-pair exact horizon changed\n$out";

# The remaining fully-dynamic P0 producer is deliberately over budget.  The
# lower-bound fixture must end at cycle 158, five cycles after the maintained
# pair cadence ends at 153; this gives later schedule work a concrete target.
my $p0bound=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_p0_stage_bound_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$p0bound);
$rc==0 && !$sig or die "P0 bound search failed\n$out$err";
$out =~ /153\.\.158\s+2:01\.\.2:06\s+mask_shift/
   or die "P0 bound no longer demonstrates the five-cycle deficit\n$out";
$out =~ /all_five P0 rolling-refill five-cycle bound/
   or die "P0 bound solution header missing\n$out";

# The measured service phases remove the P0 producer bottleneck: pair 0
# needs only one seed byte, and pairs 1/2 dynamically chain the next GRP0
# while staging PF bytes 3/5 and ending exactly on the maintained cadence.
my $p0service=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_p0_service_phase_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,"--max-solutions","1",$p0service);
$rc==0 && !$sig or die "P0 service-phase search failed\n$out$err";
$out =~ /service_grp0_seed/ or die "P0 service-phase search lost its single entry seed\n$out";
$out =~ /next_stripe_pf\+2/ or die "P0 service-phase search lost staged PF byte 3\n$out";
$out =~ /next_stripe_pf\+5/ or die "P0 service-phase search lost staged PF byte 5\n$out";
$out =~ /305\s+3:58\.\.4:01\s+p1_tail/ or die "P0 pair 1 no longer closes exactly on cadence\n$out";
$out =~ /457\s+5:58\.\.6:01\s+p2_tail/ or die "P0 pair 2 no longer closes exactly on cadence\n$out";

# If three consecutive service pairs are known all-active or all-inactive for
# P1, both concrete bodies can stage one PF byte and retain the same following
# line phase.  Keep both solutions executable.
my $p1uniform=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_p1_uniform_service_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,"--max-solutions","2",$p1uniform);
$rc==0 && !$sig or die "P1 uniform-service search failed\n$out$err";
$out =~ /p1_service\[known_active\]/ or die "P1 active service body is no longer schedulable\n$out";
$out =~ /p1_service\[known_inactive\]/ or die "P1 inactive service body is no longer schedulable\n$out";

# Exhaustively prove that, for every uint8 P1 y/height state, a uniform
# three-pair activity window begins no later than pair 4.  This is a
# conservative 14-scanline rolling-service bound while mixed-state six-line
# scheduling remains the preferred target.
my $worst=-1;
for my $y (0..255) {
   for my $h (0..255) {
      my $found;
      START: for my $s (0..4) {
         my $a0=(($y-$s    ) & 255) < $h ? 1 : 0;
         my $a1=(($y-$s-1  ) & 255) < $h ? 1 : 0;
         my $a2=(($y-$s-2  ) & 255) < $h ? 1 : 0;
         if ($a0==$a1 && $a1==$a2) { $found=$s; last START; }
      }
      defined $found or die "no uniform P1 service window for y=$y h=$h\n";
      $worst=$found if $found>$worst;
   }
}
$worst==4 or die "P1 uniform-window bound changed: worst=$worst\n";

# A tighter mixed-state construction removes the per-pair height test from the
# six-line service window entirely.  The rolling planner supplies one 3-bit
# activity pattern for each player.  Exercise all 8x8 combinations: P1 carries
# PF bytes 0/2/4 in X, P0 stages 1/3/5 in its recovered bookkeeping cycles,
# and the P0 tails commit X before restoring the next packed-mask X seed.
my $mixed=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_mixed_service_search.pl));
for my $p0pat (0..7) {
   for my $p1pat (0..7) {
      local $ENV{VCSC_P0_PATTERN}=$p0pat;
      local $ENV{VCSC_P1_PATTERN}=$p1pat;
      ($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$mixed);
      $rc==0 && !$sig or die "mixed service search failed p0=$p0pat p1=$p1pat\n$out$err";
      $out =~ /mixed P0\/P1 three-pair service p0=$p0pat p1=$p1pat/
         or die "mixed service solution header missing p0=$p0pat p1=$p1pat\n$out";
      for my $n (0..5) {
         $out =~ /inactive_pf\+$n/ or die "mixed service lost PF byte $n p0=$p0pat p1=$p1pat\n$out";
      }
      $out =~ /event PF0L\s+@\s+91 \(1:15\)/
         or die "mixed service lost first P0 PF phase p0=$p0pat p1=$p1pat\n$out";
      $out =~ /event PF2R\s+@\s+437 \(5:57\)/
         or die "mixed service lost final P0 PF phase p0=$p0pat p1=$p1pat\n$out";
      $out =~ /ldx #service_resume_x/
         or die "mixed service did not restore X seed p0=$p0pat p1=$p1pat\n$out";
      $out !~ /cpy\.z .*player[01]_height/
         or die "mixed service reintroduced a per-pair player height test p0=$p0pat p1=$p1pat\n$out";
      $err =~ /^searched=13 pruned_deadline=0 pruned_horizon=0 solutions=1\n\z/
         or die "unexpected mixed service solver statistics p0=$p0pat p1=$p1pat: $err";
   }
}

# Exercise implementation alternatives explicitly.  The slow implementation
# cannot meet the event deadline, so the solver must select the cached one.
my $alt=File::Spec->catfile($tmp,'kernel_schedule_alt.pl');
open(my $fh,'>:raw',$alt) or die "write $alt: $!\n";
print {$fh} <<'EOF';
return {
  name=>'implementation choice', line_cycles=>76, horizon=>20,
  operations=>[{
    id=>'sprite', description=>'commit precomputed or dynamic sprite',
    implementations=>[
      { name=>'dynamic', asm=>[['dynamic lookup',14]],
        events=>[{name=>'GRP1',offset=>13,windows=>[[0,8]]}] },
      { name=>'cached', asm=>[['lda cached',3]],
        events=>[{name=>'GRP1',offset=>2,windows=>[[0,8]]}] },
    ],
  }],
};
EOF
close($fh) or die "close $alt: $!\n";
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$alt);
$rc==0 && !$sig or die "alternative search failed\n$out$err";
$out =~ /sprite\[cached\]/ or die "solver did not choose cached implementation\n$out";
$out !~ /sprite\[dynamic\]/ or die "impossible dynamic implementation was selected\n$out";


# Real-idle mode rejects fictitious one-cycle holes.  With 2- and 3-cycle
# fillers, a required two-cycle delay is legal and is printed as real assembly,
# while a required one-cycle delay has no solution.  This guards the exact
# scheduling use case where 6502 timing cannot simply "wait one cycle".
my $fill=File::Spec->catfile($tmp,'kernel_schedule_fill.pl');
open($fh,'>:raw',$fill) or die "write $fill: $!\n";
print {$fh} <<'EOF';
return {
  name=>'real filler', line_cycles=>76, horizon=>5,
  idle_fillers=>[
    {text=>'nop',cycles=>2},
    {text=>'nop.z scratch',cycles=>3},
  ],
  operations=>[{
    id=>'write', earliest=>2, latest_end=>4,
    asm=>[['sta PF0',3]],
    events=>[{name=>'PF0',offset=>2,windows=>[[4,4]]}],
  }],
};
EOF
close($fh) or die "close $fill: $!\n";
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$fill);
$rc==0 && !$sig or die "real filler search failed\n$out$err";
$out =~ /IDLE 2 cycles \(nop\/2\)/ or die "2-cycle filler was not materialized\n$out";

my $one=File::Spec->catfile($tmp,'kernel_schedule_one_cycle_gap.pl');
open($fh,'>:raw',$one) or die "write $one: $!\n";
print {$fh} <<'EOF';
return {
  name=>'one cycle impossible', line_cycles=>76, horizon=>4,
  idle_fillers=>[
    {text=>'nop',cycles=>2},
    {text=>'nop.z scratch',cycles=>3},
  ],
  operations=>[{
    id=>'write', earliest=>1, latest_end=>3,
    asm=>[['sta PF0',3]],
    events=>[{name=>'PF0',offset=>2,windows=>[[3,3]]}],
  }],
};
EOF
close($fh) or die "close $one: $!\n";
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$one);
$rc==1 && !$sig or die "one-cycle hole should be unschedulable\n$out$err";
$err =~ /solutions=0/ or die "one-cycle hole did not report zero solutions\n$err";

print "vcs_kernel_schedule_search ok\n";
