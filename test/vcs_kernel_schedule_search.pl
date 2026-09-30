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

# The authoritative periodic pair starts at physical scanline-A cycle 2 and
# ends exactly 152 cycles later at the same phase.  Run it once with ordinary
# dynamic player production and once with double-buffer feed work replacing those
# soft slots.  Every TIA appointment must be identical between the two runs.
my $machine=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pair_machine_search.pl));
local $ENV{VCSC_STRIPE_PAIR_MODE}='ordinary';
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$machine);
$rc==0 && !$sig or die "authoritative ordinary pair search failed\n$out$err";
$out =~ /^solution 1 for all_five authoritative 152-cycle machine \[ordinary\]$/m
   or die "authoritative ordinary pair header missing\n$out";
$out =~ /line_cycles=76 horizon=152 phase_origin=2/
   or die "authoritative pair epoch changed\n$out";
$out =~ /0\.\.\s*59\s+0:02\.\.0:61\s+a_visible/
   or die "scanline-A body moved\n$out";
$out =~ /60\.\.\s*82\s+0:62\.\.1:08\s+p1_feed\[ordinary_dynamic\]/
   or die "ordinary P1 feed slot moved\n$out";
$out =~ /83\.\.105\s+1:09\.\.1:31\s+b_left/ &&
$out =~ /106\.\.123\s+1:32\.\.1:49\s+p0_mid\[ordinary_dynamic\]/ &&
$out =~ /124\.\.135\s+1:50\.\.1:61\s+b_right/
   or die "scanline-B cadence/feed split moved\n$out";
$out =~ /136\.\.151\s+1:62\.\.2:01\s+p0_feed\[ordinary_dynamic\]/
   or die "ordinary P0 feed slot moved\n$out";
$out =~ /0:13\.\.0:15\s+\+3\s+sta PF0/
   or die "instruction-level PF0 span missing\n$out";
$out =~ /1:06\.\.1:08\s+\+3\s+sta GRP1/
   or die "instruction-level GRP1 span missing\n$out";
$out =~ /1:46\.\.1:49\s+\+4\s+sta\.a PF0/
   or die "instruction-level absolute PF0 timing knob missing\n$out";
$out =~ /2:00\.\.2:01\s+\+2\s+nop/
   or die "pair carry tail no longer ends at next A cycle 1\n$out";
$out !~ /\bIDLE\b/ or die "authoritative ordinary pair contains fictitious idle time\n$out";
my @ordinary_events=($out =~ /^\s+event\s+.*$/mg);
@ordinary_events==17 or die "ordinary pair TIA event count changed: ".scalar(@ordinary_events)."\n$out";

local $ENV{VCSC_STRIPE_PAIR_MODE}='refill';
my($rrc,$rsig,$rout,$rerr)=capture($^X,$solver,'--max-solutions','1',$machine);
$rrc==0 && !$rsig or die "authoritative refill pair search failed\n$rout$rerr";
$rout =~ /p1_feed\[refill_pf0\]/ && $rout =~ /p0_mid\[refill_color0\]/ &&
$rout =~ /p0_feed\[refill_pf1\]/
   or die "refill work did not replace all three soft feed slots\n$rout";
$rout =~ /next_stripe_pf\+0/ && $rout =~ /next_stripe_pf\+1/ &&
$rout =~ /next_stripe_color\+0/
   or die "refill pair lost staged PF/color feed work\n$rout";
$rout !~ /\bIDLE\b/ or die "authoritative refill pair contains fictitious idle time\n$rout";
my @refill_events=($rout =~ /^\s+event\s+.*$/mg);
join("\n",@refill_events) eq join("\n",@ordinary_events)
   or die "refill work moved a TIA appointment\nordinary:\n".join("\n",@ordinary_events)."\nrefill:\n".join("\n",@refill_events)."\n";
$err =~ /^searched=7 pruned_deadline=0 pruned_horizon=0 solutions=1\n\z/
   or die "unexpected ordinary machine solver statistics: $err";
$rerr =~ /^searched=7 pruned_deadline=0 pruned_horizon=0 solutions=1\n\z/
   or die "unexpected refill machine solver statistics: $rerr";

# Compose the same authoritative machine three times.  This is the complete
# six-scanline refill body: all six PF bytes plus both next colors fit without
# moving any of the 51 TIA appointments.  Pair 2 retains a real seven-cycle
# spare slot for rolling planner/preparation work.
local $ENV{VCSC_STRIPE_PAIR_MODE}='refill';
local $ENV{VCSC_STRIPE_PAIR_COUNT}=3;
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$machine);
$rc==0 && !$sig or die "authoritative three-pair refill search failed\n$out$err";
$out =~ /^solution 1 for all_five authoritative 456-cycle machine \[refill\]$/m
   or die "three-pair authoritative header missing\n$out";
$out =~ /line_cycles=76 horizon=456 phase_origin=2/
   or die "three-pair authoritative horizon changed\n$out";
for my $n (0..5) {
   $out =~ /next_stripe_pf\+$n/ or die "three-pair machine lost staged PF byte $n\n$out";
}
for my $n (0..1) {
   $out =~ /next_stripe_color\+$n/ or die "three-pair machine lost staged color $n\n$out";
}
$out =~ /p2_p0_mid\[refill_spare7\]/ &&
$out =~ /bit\.a timing_scratch/ && $out =~ /nop\.z timing_scratch/
   or die "three-pair machine lost explicit seven-cycle rolling-prep budget\n$out";
$out !~ /\bIDLE\b/ or die "three-pair machine contains fictitious idle time\n$out";
my @three_events=($out =~ /^\s+event\s+.*$/mg);
@three_events==51 or die "three-pair TIA event count changed: ".scalar(@three_events)."\n$out";
$out =~ /event PF0L\s+\@\s+13 \(0:15\)/ &&
$out =~ /event PF2R\s+\@\s+439 \(5:61\)/
   or die "three-pair fixed PF phase family moved\n$out";
$err =~ /^searched=19 pruned_deadline=0 pruned_horizon=0 solutions=1\n\z/
   or die "unexpected three-pair machine solver statistics: $err";

# Historical developer commands using the old one-pair filename must delegate
# to the authoritative machine rather than maintaining another cadence copy.
my $exact=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pair_exact_search.pl));
local $ENV{VCSC_STRIPE_PAIR_MODE}='ordinary';
local $ENV{VCSC_STRIPE_PAIR_COUNT}=1;
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$exact);
$rc==0 && !$sig or die "one-pair compatibility shim failed\n$out$err";
$out =~ /^solution 1 for all_five authoritative 152-cycle machine \[refill\]$/m
   or die "one-pair compatibility shim no longer selects authoritative refill mode\n$out";

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

# A second construction avoids per-pair player classification altogether when
# both players share a three-pair window in which each is independently uniform
# (all active or all inactive).  Two rolling service pointers then make the hot
# path identical for all four activity-mode combinations.  Immediate local
# indices 2/1/0 survive across each P0 line, leaving eight tail cycles: the first
# two tails copy the next stripe colors while all six PF bytes are refilled.
my $dual_uniform=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_dual_uniform_pointer_service_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$dual_uniform);
$rc==0 && !$sig or die "dual-uniform pointer service search failed\n$out$err";
$out =~ /dual-uniform-pointer three-pair service/
   or die "dual-uniform pointer solution header missing\n$out";
for my $n (0..5) {
   $out =~ /inactive_pf\+$n/
      or die "dual-uniform pointer service lost PF byte $n\n$out";
}
for my $n (0..1) {
   $out =~ /next_stripe_color\+$n/
      or die "dual-uniform pointer service lost color byte $n\n$out";
}
$out =~ /ldy #2/ && $out =~ /ldy #1/ && $out =~ /ldy #0/
   or die "dual-uniform pointer service lost local 2\/1\/0 indices\n$out";
$out =~ /event PF0L\s+@\s+90 \(1:14\)/
   or die "dual-uniform pointer service lost first P0 PF phase\n$out";
$out =~ /event PF2R\s+@\s+436 \(5:56\)/
   or die "dual-uniform pointer service lost final P0 PF phase\n$out";
$out !~ /cpy\.z .*player[01]_height/
   or die "dual-uniform pointer service reintroduced a hot player height test\n$out";
$out =~ /stx\.a next_color_slot\+0/ && $out =~ /stx\.a next_color_slot\+1/
   or die "dual-uniform pointer service no longer fills both eight-cycle color slots\n$out";
$out =~ /ldx\.z service_resume_x/ && $out =~ /jmp \(service_resume_ptr\)/
   or die "dual-uniform pointer service lost dynamic X restore/resume vector tail\n$out";
$out !~ /ldx #service_resume_x/
   or die "dual-uniform pointer service regressed to a fixed resume X value\n$out";
$err =~ /^searched=13 pruned_deadline=0 pruned_horizon=0 solutions=1\n\z/
   or die "unexpected dual-uniform pointer solver statistics: $err";

# Exhaust the *pair* of player state spaces without a 2^32 brute-force loop.
# For one uint8 y/height state, record the nine candidate starts (0..8) whose
# three rows are not uniform.  There are only a small number of distinct masks;
# testing every pair of distinct masks is equivalent to testing all P0/P1 state
# combinations.  No union may cover all nine starts, and the tight worst case
# must require start 8.
my @uniform_bad_seen=(0) x 512;
for my $y (0..255) {
   for my $h (0..255) {
      my $bad=0;
      for my $s (0..8) {
         my $a0=(($y-$s    ) & 255) < $h ? 1 : 0;
         my $a1=(($y-$s-1  ) & 255) < $h ? 1 : 0;
         my $a2=(($y-$s-2  ) & 255) < $h ? 1 : 0;
         $bad |= 1 << $s unless $a0==$a1 && $a1==$a2;
      }
      $uniform_bad_seen[$bad]=1;
   }
}
my @uniform_bad_masks=grep { $uniform_bad_seen[$_] } 0..511;
@uniform_bad_masks==52
   or die "single-player uniform-window mask count changed: ".scalar(@uniform_bad_masks)."\n";
my $dual_worst=-1;
for my $mask0 (@uniform_bad_masks) {
   for my $mask1 (@uniform_bad_masks) {
      my $blocked=$mask0 | $mask1;
      my $found;
      for my $s (0..8) {
         if (!(($blocked >> $s) & 1)) { $found=$s; last; }
      }
      defined $found or die "no common P0/P1 uniform service window through start 8\n";
      $dual_worst=$found if $found>$dual_worst;
   }
}
$dual_worst==8 or die "dual-player uniform-window bound changed: worst=$dual_worst\n";

# More useful to the actual unrolled kernel: avoid packed-row transitions
# altogether.  Relative to two consecutive eight-pair rows, try ordinary pair
# starts 1..5 in the first row and 1..3 in the second.  These eight candidates
# are sufficient for every P0/P1 uint8 state pair; the tight ordering can make
# the eighth candidate (relative start 11) the first usable one.  A three-pair
# service therefore always remains wholly inside one ordinary unrolled row.
my @ordinary_candidates=(1,2,3,4,5,9,10,11);
my @ordinary_bad_seen=(0) x 256;
my $ordinary_single_max=0;
for my $y (0..255) {
   for my $h (0..255) {
      my $bad=0;
      for my $i (0..$#ordinary_candidates) {
         my $s=$ordinary_candidates[$i];
         my $a0=(($y-$s    ) & 255) < $h ? 1 : 0;
         my $a1=(($y-$s-1  ) & 255) < $h ? 1 : 0;
         my $a2=(($y-$s-2  ) & 255) < $h ? 1 : 0;
         $bad |= 1 << $i unless $a0==$a1 && $a1==$a2;
      }
      $ordinary_bad_seen[$bad]=1;
      my $bits=unpack('%32b*',pack('L',$bad));
      $ordinary_single_max=$bits if $bits>$ordinary_single_max;
   }
}
$ordinary_single_max==4
   or die "single player blocks more than four ordinary service starts: $ordinary_single_max\n";
my @ordinary_masks=grep { $ordinary_bad_seen[$_] } 0..255;
my $ordinary_worst=-1;
for my $mask0 (@ordinary_masks) {
   for my $mask1 (@ordinary_masks) {
      my $blocked=$mask0 | $mask1;
      my $found;
      for my $i (0..$#ordinary_candidates) {
         if (!(($blocked >> $i) & 1)) { $found=$i; last; }
      }
      defined $found or die "no common uniform service window in ordinary two-row candidate set\n";
      $ordinary_worst=$found if $found>$ordinary_worst;
   }
}
$ordinary_worst==7
   or die "ordinary two-row service-window bound changed: candidate=$ordinary_worst\n";

# The ordinary starts can be narrowed further.  Five fixed starts, all odd and
# separated by at least two pairs, are enough: 1,3,5,9,11.  A player's
# three-pair activity can change only at the active/inactive threshold and at
# uint8 wrap.  Each transition blocks at most one of these starts, so the two
# players' four transitions can block at most four of five candidates.  Prove
# both the transition formula and that no four-start subset of the ordinary
# starts through four rows has the same universal property.
my @dispatch_candidates=(1,3,5,9,11);
for my $y (0..255) {
   for my $h (0..255) {
      for my $s (@dispatch_candidates) {
         my $a0=(($y-$s    ) & 255) < $h ? 1 : 0;
         my $a1=(($y-$s-1  ) & 255) < $h ? 1 : 0;
         my $a2=(($y-$s-2  ) & 255) < $h ? 1 : 0;
         my $direct=($a0==$a1 && $a1==$a2) ? 0 : 1;
         my $t0=$y & 255;
         my $t1=($y-$h) & 255;
         my $by_transition=$h==0 ? 0 :
            (($s==$t0 || $s==(($t0-1)&255) ||
              $s==$t1 || $s==(($t1-1)&255)) ? 1 : 0);
         $direct==$by_transition
            or die "uniform transition formula changed y=$y h=$h s=$s direct=$direct transition=$by_transition\n";
      }
   }
}
my @dispatch_bad_seen=(0) x 32;
for my $y (0..255) {
   for my $h (0..255) {
      my $bad=0;
      for my $i (0..$#dispatch_candidates) {
         my $s=$dispatch_candidates[$i];
         my $a0=(($y-$s    ) & 255) < $h ? 1 : 0;
         my $a1=(($y-$s-1  ) & 255) < $h ? 1 : 0;
         my $a2=(($y-$s-2  ) & 255) < $h ? 1 : 0;
         $bad |= 1 << $i unless $a0==$a1 && $a1==$a2;
      }
      $dispatch_bad_seen[$bad]=1;
   }
}
my @dispatch_masks=grep { $dispatch_bad_seen[$_] } 0..31;
for my $m0 (@dispatch_masks) {
   for my $m1 (@dispatch_masks) {
      (($m0 | $m1) & 0x1f) != 0x1f
         or die "five fixed dual-uniform dispatch candidates can all be blocked\n";
   }
}

# Five is minimal even if the planner may choose any ordinary start in the
# first four packed rows.  Exhaust all four-start subsets against the compact
# set of distinct single-player bad masks.
my @minimal_universe=grep { my $r=$_ & 7; $r>=1 && $r<=5 } 1..31;
my %minimal_masks;
for my $y (0..255) {
   for my $h (0..255) {
      my $bad=0;
      for my $i (0..$#minimal_universe) {
         my $s=$minimal_universe[$i];
         my $a0=(($y-$s    ) & 255) < $h ? 1 : 0;
         my $a1=(($y-$s-1  ) & 255) < $h ? 1 : 0;
         my $a2=(($y-$s-2  ) & 255) < $h ? 1 : 0;
         $bad |= 1 << $i unless $a0==$a1 && $a1==$a2;
      }
      $minimal_masks{$bad}=1;
   }
}
my @minimal_masks=keys %minimal_masks;
my %covered_four;
for my $m0 (@minimal_masks) {
   for my $m1 (@minimal_masks) {
      my $u=(0+$m0) | (0+$m1);
      my @bit=grep { ($u>>$_)&1 } 0..$#minimal_universe;
      next if @bit<4;
      for my $a (0..$#bit-3) {
         for my $b ($a+1..$#bit-2) {
            for my $c ($b+1..$#bit-1) {
               for my $d ($c+1..$#bit) {
                  my $four=(1<<$bit[$a])|(1<<$bit[$b])|
                           (1<<$bit[$c])|(1<<$bit[$d]);
                  $covered_four{$four}=1;
               }
            }
         }
      }
   }
}
my $want_four=1;
$want_four=$want_four*(@minimal_universe-$_)/($_+1) for 0..3;
scalar(keys %covered_four)==$want_four
   or die "some four ordinary starts unexpectedly guarantee a common uniform window\n";

# Pair 32 is a particularly useful rolling-planner origin: it is aligned to a
# 16-pair period, so the five relative starts 1,3,5,9,11 can be screened using
# only the low nibble of each activity-transition position.  The table below
# deliberately aliases every later 16-pair period onto the same candidate.
# Those aliases can create false conflicts, but never false safety: a real
# conflict is always marked, and each of the four P0/P1 threshold/wrap
# transitions still marks at most one bit.  Thus even the conservative alias
# masks cannot block all five candidates.  This buys a fixed 16-byte table and
# removes planner range checks.
my @transition_alias=(0,1,1,2,2,4,4,0,0,8,8,16,16,0,0,0);
my %alias_masks;
for my $y (0..255) {
   for my $h (0..255) {
      my $alias=$transition_alias[$y & 15] |
                $transition_alias[(($y-$h)&255) & 15];
      $alias_masks{$alias}=1;
      my $true=0;
      for my $i (0..$#dispatch_candidates) {
         my $s=$dispatch_candidates[$i];
         my $a0=(($y-$s    ) & 255) < $h ? 1 : 0;
         my $a1=(($y-$s-1  ) & 255) < $h ? 1 : 0;
         my $a2=(($y-$s-2  ) & 255) < $h ? 1 : 0;
         $true |= 1 << $i unless $a0==$a1 && $a1==$a2;
      }
      ($true & ~$alias)==0
         or die "transition alias lost a real conflict y=$y h=$h true=$true alias=$alias\n";
      unpack('%32b*',pack('L',$alias)) <= 2
         or die "one player alias-blocked more than two candidates y=$y h=$h alias=$alias\n";
   }
}
my @alias_masks=sort {$a<=>$b} keys %alias_masks;
my @first_free_start;
for my $mask (0..31) {
   my $start;
   for my $i (0..$#dispatch_candidates) {
      if (!(($mask>>$i)&1)) { $start=$dispatch_candidates[$i]; last; }
   }
   $first_free_start[$mask]=defined($start) ? $start : 0;
}
for my $m0 (@alias_masks) {
   for my $m1 (@alias_masks) {
      my $u=$m0|$m1;
      unpack('%32b*',pack('L',$u)) <= 4
         or die "two-player transition alias blocks more than four candidates mask=$u\n";
      my $s=$first_free_start[$u];
      $s && grep($_==$s,@dispatch_candidates)
         or die "alias selector lost a free candidate mask=$u start=$s\n";
      my ($i)=grep { $dispatch_candidates[$_]==$s } 0..$#dispatch_candidates;
      !(($u>>$i)&1)
         or die "alias selector chose a blocked candidate mask=$u start=$s\n";
   }
}

# Once the selector returns relative start r, X can keep r all the way through
# pointer construction and the candidate-dispatch region.  P1's first service
# source row is y-(32+r); P0 is one pipeline decrement ahead at y-(33+r).
# If a selected three-pair window is active, its first source row can never be
# 0 or 1, so biasing the graphics pointer by source-2 is safe and local Y=2,1,0
# addresses exactly the required three bytes.
for my $which (qw(P1 P0)) {
   my $ahead=$which eq 'P0' ? 1 : 0;
   for my $y (0..255) {
      for my $h (0..255) {
         for my $r (@dispatch_candidates) {
            my $q=($y-32-$r-$ahead)&255;
            my @active=map { (($q-$_)&255)<$h ? 1:0 } 0..2;
            next unless $active[0]==$active[1] && $active[1]==$active[2];
            if ($active[0]) {
               $q>=2 or die "$which active uniform window underflows pointer bias y=$y h=$h r=$r q=$q\n";
               my $bias=($q-2)&255;
               (($bias+2)&255)==$q &&
               (($bias+1)&255)==(($q-1)&255) &&
               $bias==(($q-2)&255)
                  or die "$which active service pointer bias changed y=$y h=$h r=$r q=$q\n";
            }
         }
      }
   }
}

# The selector itself is free in the raster cadence and can target one shared
# service body without relying on a short branch.  The non-selected candidate
# path is exactly the ordinary 20-cycle mask/tail budget.  The selected path
# is 22 cycles: its local BNE falls through, then an unconditional JMP spends
# the two idle cycles at the front of the shared service.  The service therefore
# still begins its first STA GRP0 at pair cycle 2.
my $dispatch_search=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_dual_uniform_dispatch_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','2',$dispatch_search);
$rc==0 && !$sig or die "dual-uniform dispatch search failed\n$out$err";
$out =~ /candidate_tail\[selected\]/
   or die "selected dual-uniform dispatch path is no longer schedulable\n$out";
$out =~ /candidate_tail\[not_selected\]/
   or die "non-selected dual-uniform dispatch path is no longer schedulable\n$out";
$out =~ /0\.\.\s*21\s+0:00\.\.0:21\s+candidate_tail\[selected\]/
   or die "selected dispatch path no longer consumes the service's two-cycle entry idle\n$out";
$out =~ /jmp shared_service/
   or die "selected dispatch path lost range-free JMP to shared service\n$out";
$out =~ /0\.\.\s*19\s+0:00\.\.0:19\s+candidate_tail\[not_selected\]/
   or die "non-selected dispatch path no longer consumes exact 20-cycle budget\n$out";

# A stronger single-row service only requires P1 to be uniform.  P0 can be
# arbitrary because the planner caches the three exact P0 sprite bytes.  In one
# eight-pair packed row the three fixed starts 0,2,4 always contain a uniform
# three-pair P1 window and all fit before the tail-7 A/B boundary. Two starts
# are not enough anywhere in starts 0..5.
my @p1_cache_candidates=(0,2,4);
for my $y (0..255) {
   for my $h (0..255) {
      my $found;
      for my $s (@p1_cache_candidates) {
         my @a=map { (($y-$s-$_)&255)<$h ? 1:0 } 0..2;
         if ($a[0]==$a[1] && $a[1]==$a[2]) { $found=$s; last; }
      }
      defined $found or die "no P1-uniform window in starts 0,2,4 y=$y h=$h\n";
   }
}
for my $a (0..4) {
   for my $b ($a+1..5) {
      my $can_fail=0;
      OUTER: for my $y (0..255) {
         for my $h (0..255) {
            my $ba=0; my $bb=0;
            for my $spec ([$a,\$ba],[$b,\$bb]) {
               my($s,$out)=@$spec;
               my @v=map { (($y-$s-$_)&255)<$h ? 1:0 } 0..2;
               $$out=1 unless $v[0]==$v[1] && $v[1]==$v[2];
            }
            if ($ba && $bb) { $can_fail=1; last OUTER; }
         }
      }
      $can_fail or die "two starts unexpectedly guarantee P1 uniformity: $a,$b\n";
   }
}

my $p1cache_dispatch=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_p1_cache_dispatch_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$p1cache_dispatch);
$rc==0 && !$sig or die "P1-cache dispatch search failed\n$out$err";
$out =~ /P1-cache three-candidate dispatch/
   or die "P1-cache dispatch solution header missing\n$out";
$out =~ /0\.\.\s*24\s+0:00\.\.0:24\s+candidate0_tail/
   or die "candidate 0 no longer matches the 25-cycle row-backedge envelope\n$out";
$out =~ /25\.\.\s*44\s+0:25\.\.0:44\s+candidate2_tail/
   or die "candidate 2 no longer matches the 20-cycle pair-1 envelope\n$out";
$out =~ /45\.\.\s*64\s+0:45\.\.0:64\s+candidate4_tail/
   or die "candidate 4 no longer matches the 20-cycle pair-3 envelope\n$out";
$out =~ /jmp \(candidate0_ptr\)/ && $out =~ /jmp \(candidate2_ptr\)/ &&
$out =~ /jmp shared_service/
   or die "P1-cache dispatch lost its two pointers plus fallback\n$out";

my $p1cache_row_gate=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_p1_cache_row_gate_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','5',$p1cache_row_gate);
$rc==0 && !$sig or die "P1-cache row-gate search failed\n$out$err";
for my $variant (qw(old_normal_reference gated_normal gated_service gated_boundary old_boundary_reference)) {
   $out =~ /row_gate\[$variant\]/
      or die "P1-cache row gate lost $variant path\n$out";
}
my $ten_cycle_paths=()=$out =~ /0\.\.\s*9\s+0:00\.\.0:09\s+row_gate\[/g;
$ten_cycle_paths==5
   or die "P1-cache row gate no longer keeps every GRP0 commit at cycle 10\n$out";
$out =~ /inx ; X=\$00 Z=1/ && $out =~ /inx ; X=\$04 Z=0/ &&
$out =~ /bpl\.same nearby_special/ && $out =~ /nop ; compensate skipped JMP/ &&
$out =~ /beq\.same service ; taken only for X=\$00/
   or die "P1-cache row gate lost zero-tax service\/boundary discriminator\n$out";

# The PF-only four-line body needs only two consecutive P1-uniform pairs.
# Choosing the late starts 4,5,6 keeps every service window at the end of the
# eight-pair row.  A decrementing uint8 sprite can cross only the height
# threshold and byte-wrap boundaries, so its activity cannot alternate at all
# three adjacent boundaries 4->5, 5->6, and 6->7.  Exhaustively verify the
# actual uint8 semantics.  Also prove that no pair of starts in 0..6 provides
# the same guarantee, so three late candidates are minimal.
my @p1_cache_4line_candidates=(4,5,6);
for my $y (0..255) {
   for my $h (0..255) {
      my $found;
      for my $s (@p1_cache_4line_candidates) {
         my @a=map { (($y-$s-$_)&255)<$h ? 1:0 } 0..1;
         if ($a[0]==$a[1]) { $found=$s; last; }
      }
      defined $found or die "no two-pair P1-uniform late window in starts 4,5,6 y=$y h=$h\n";
   }
}
for my $a (0..5) {
   for my $b ($a+1..6) {
      my $can_fail=0;
      OUTER4: for my $y (0..255) {
         for my $h (0..255) {
            my $aa=((($y-$a)&255)<$h ? 1:0);
            my $ab=((($y-$a-1)&255)<$h ? 1:0);
            my $ba=((($y-$b)&255)<$h ? 1:0);
            my $bb=((($y-$b-1)&255)<$h ? 1:0);
            if ($aa!=$ab && $ba!=$bb) { $can_fail=1; last OUTER4; }
         }
      }
      $can_fail or die "two starts unexpectedly guarantee two-pair P1 uniformity: $a,$b\n";
   }
}

my $p1cache4_dispatch=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_p1_cache_4line_dispatch_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$p1cache4_dispatch);
$rc==0 && !$sig or die "four-line P1-cache dispatch search failed\n$out$err";
$out =~ /P1-cache four-line late dispatch/
   or die "four-line P1-cache dispatch solution header missing\n$out";
for my $spec ([4,0,19],[5,20,39],[6,40,59]) {
   my($start,$lo,$hi)=@$spec;
   $out =~ /\Q$lo\E\.\.\s*\Q$hi\E\s+0:\d\d\.\.0:\d\d\s+candidate${start}_tail/
      or die "four-line candidate $start no longer consumes its exact 20-cycle predecessor tail\n$out";
}
$out =~ /jmp \(candidate4_ptr\)/ && $out =~ /jmp \(candidate5_ptr\)/ &&
$out =~ /jmp shared_service/
   or die "four-line late dispatch lost two vectors plus fallback\n$out";

my $p1cache4=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_p1_uniform_p0_cache_4line_service_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$p1cache4);
$rc==0 && !$sig or die "four-line P1-uniform/P0-cache service search failed\n$out$err";
$out =~ /P1-uniform\/P0-cache two-pair PF-only service/
   or die "four-line P1-uniform/P0-cache solution header missing\n$out";
for my $n (0..5) {
   $out =~ /inactive_pf\+$n/
      or die "four-line P1-uniform/P0-cache service lost PF byte $n\n$out";
}
for my $n (0..1) {
   $out =~ /p0_service_byte\+$n/
      or die "four-line P1-uniform/P0-cache service lost exact P0 byte $n\n$out";
}
$out !~ /next_color_slot/
   or die "four-line PF-only service unexpectedly absorbed color preparation\n$out";
$out =~ /ldx #normal_x/
   or die "four-line PF-only service lost normal-X restoration\n$out";

my $p1cache=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_p1_uniform_p0_cache_service_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$p1cache);
$rc==0 && !$sig or die "P1-uniform/P0-cache service search failed\n$out$err";
$out =~ /P1-uniform\/P0-cache three-pair service/
   or die "P1-uniform/P0-cache solution header missing\n$out";
for my $n (0..5) {
   $out =~ /inactive_pf\+$n/
      or die "P1-uniform/P0-cache service lost PF byte $n\n$out";
}
for my $n (0..1) {
   $out =~ /next_color_slot\+$n/
      or die "P1-uniform/P0-cache service lost color byte $n\n$out";
}
for my $n (0..2) {
   $out =~ /p0_service_byte\+$n/
      or die "P1-uniform/P0-cache service lost exact P0 byte $n\n$out";
}
$out =~ /ldy #2/ && $out =~ /\bdey\b/
   or die "P1-uniform/P0-cache service lost local 2\/1\/0 index\n$out";
$out =~ /jmp \(service_resume_ptr\)/
   or die "P1-uniform/P0-cache service lost dynamic resume tail\n$out";
$out !~ /cpy\.z .*height/
   or die "P1-uniform/P0-cache service reintroduced a hot height test\n$out";

my $exact_cache=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_exact_cache_service_search.pl));
($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$exact_cache);
$rc==0 && !$sig or die "exact-cache service search failed\n$out$err";
$out =~ /exact-cache fixed three-pair service/
   or die "exact-cache service solution header missing\n$out";
for my $n (0..5) {
   $out =~ /inactive_pf\+$n/
      or die "exact-cache service lost PF byte $n\n$out";
}
for my $n (0..2) {
   $out =~ /p1_service_byte\+$n/ && $out =~ /p0_service_byte\+$n/
      or die "exact-cache service lost staged player byte $n\n$out";
}
$out !~ /service_p1_ptr|candidate|cpy\.z .*height/
   or die "exact-cache service retained hot selector/pointer machinery\n$out";
$out =~ /jmp \(service_resume_ptr\)/
   or die "exact-cache service lost rolling resume tail\n$out";

# Exact-P1-pointer service removes mixed-pattern dispatch entirely.  The
# inactive PF buffer starts as three exact P1 pointers, and each pair overwrites
# its consumed pointer with the corresponding two next-stripe PF bytes.  P0 is
# classified live with CPY; exhaust all eight possible branch-outcome patterns.
my $pointer=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pointer_service_search.pl));
for my $p0pat (0..7) {
   local $ENV{VCSC_P0_PATTERN}=$p0pat;
   ($rc,$sig,$out,$err)=capture($^X,$solver,'--max-solutions','1',$pointer);
   $rc==0 && !$sig or die "pointer service search failed p0=$p0pat\n$out$err";
   $out =~ /exact-P1-pointer\/live-P0 three-pair service p0=$p0pat/
      or die "pointer service solution header missing p0=$p0pat\n$out";
   for my $n (0..5) {
      $out =~ /inactive_pf\+$n/
         or die "pointer service lost PF buffer byte $n p0=$p0pat\n$out";
      $out =~ /next_stripe_pf\+$n/
         or die "pointer service lost staged PF byte $n p0=$p0pat\n$out";
   }
   $out =~ /lda\.ix \(inactive_pf\+\$18\+0,x\)/
      or die "pointer service lost pair-0 indexed-indirect pointer p0=$p0pat\n$out";
   $out =~ /cpy\.z player0_height/
      or die "pointer service lost live P0 height test p0=$p0pat\n$out";
   $out !~ /bit\.z inactive_pf/
      or die "pointer service reintroduced P0 pointer metadata p0=$p0pat\n$out";
   $out =~ /event PF0L\s+@\s+89 \(1:13\)/
      or die "pointer service lost first P0 PF phase p0=$p0pat\n$out";
   $out =~ /event PF2R\s+@\s+444 \(5:64\)/
      or die "pointer service lost final P0 PF phase p0=$p0pat\n$out";
   $out !~ /cpy\.z player1_height/
      or die "pointer service reintroduced a P1 height test p0=$p0pat\n$out";
   $out !~ /ldx #service_resume_x/
      or die "pointer service reintroduced an X restore p0=$p0pat\n$out";
   $err =~ /^searched=13 pruned_deadline=0 pruned_horizon=0 solutions=1
\z/
      or die "unexpected pointer service solver statistics p0=$p0pat: $err";
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
