#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# expectstdout: vcs_stella_x_display_allocation ok
# expectexit: 0

# Concurrency safety for the X server that each Stella certification run starts.
#
# Two checkouts are normally exercised at once by different accounts sharing /tmp
# and the X server, so every run has to pick a display nobody else is taking.  The
# pattern this replaces was
#
#     my$n=250+($$%20); $n++ while -e "/tmp/.X11-unix/X$n";
#
# which is check-then-create: two processes can both observe a number free and both
# start a server on it, and the loser dies.  It stayed invisible because nothing
# verified that the server came up, so the run continued against a dead display and
# failed later as an unrelated Stella error.  With the pid bucket forced to collide,
# two of three servers died that way.
#
# The reservation is a file created with O_CREAT|O_EXCL, because that is the one
# primitive available here that is atomic.  Ownership has to be recorded, since a
# reservation cannot be reclaimed blindly: a killed run must not hide a display
# forever, and a reservation held by another account must not be stolen on the
# strength of a kill(0) that cannot see across accounts.
#
# This is a source-and-unit tier check: no Xvfb and no Stella, so it stays in the
# compile phase and costs nothing.  The converted runners are covered by the contract
# scan at the end rather than by running them here.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use File::Path qw(make_path);
use Fcntl qw(O_CREAT O_EXCL O_WRONLY);

@ARGV == 2 or die "usage: $0 REPO TMP\n";
my ($repo, $tmp) = @ARGV;
make_path($tmp);
$repo = abs_path($repo) or die "could not resolve repo\n";
$tmp = abs_path($tmp);
require File::Spec->catfile($repo, qw(test stella_test_lib.pl));

# Displays 380 and up are outside every range the certification runners claim, so a
# server appearing there is not one of ours to reuse.
my $free_base = 380;

sub spew_reservation {
   my ($number, $user, $pid, $when) = @_;
   my $path = vcsc_x_reserve_path($number);
   unlink $path;
   sysopen(my $fh, $path, O_CREAT | O_EXCL | O_WRONLY, 0644)
      or die "could not plant a reservation for display $number: $!\n";
   print {$fh} "$user $pid $when\n";
   close($fh);
   return $path;
}

my $self = scalar getpwuid($<);

# --- a display carrying a live socket is never taken ---------------------------
# This is what covers another account's server and an interactive session: those are
# not addressed through a reservation file at all, only through their socket.  A test
# that cannot plant a socket without destroying a real one must say so rather than
# proceed, so the absence is checked rather than assumed.
{
   my $base = $free_base;
   mkdir(File::Spec->catdir(File::Spec->tmpdir(), '.X11-unix'));
   for my $n ($base .. $base + 3) {
      -e vcsc_x_socket_path($n)
         and die "display $n is already serving; refusing to overwrite a real socket\n";
      open(my $s, '>', vcsc_x_socket_path($n)) or die "could not plant socket $n: $!\n";
      close($s);
   }
   my $got = eval { vcsc_reserve_x_display($base, 4) };
   my $err = $@;
   for my $n ($base .. $base + 3) { unlink vcsc_x_socket_path($n) }
   defined($got)
      and die "a display already carrying an X socket was handed out as $got\n";
   $err =~ /serving an X server/
      or die "refusing a socketed display must say why, but said: $err";
   vcsc_release_x_displays();
}

# --- exhaustion is a clear error, not a wrong display --------------------------
{
   my $base = $free_base + 4;
   for my $n ($base .. $base + 2) { spew_reservation($n, $self, $$, time()) }
   my $got = eval { vcsc_reserve_x_display($base, 3) };
   my $err = $@;
   for my $n ($base .. $base + 2) { unlink vcsc_x_reserve_path($n) }
   defined($got) and die "a fully reserved range still handed out $got\n";
   $err =~ /\Q$base\E\.\.\Q@{[$base + 2]}\E/
      or die "exhaustion must name the range it tried, but said: $err";
}

# --- reclaiming depends on who holds the reservation --------------------------
# Within this account kill(0) is exact.  Across accounts it is not: kill(0) answers
# only for our own processes, so testing a foreign pid reports it dead and would take
# a reservation from a live run.  Age is then the only evidence available.
{
   my $base = $free_base + 8;

   spew_reservation($base, $self, 999999, time());          # same account, gone
   my ($reclaimed) = eval { vcsc_reserve_x_display($base, 1) };
   defined($reclaimed) && $reclaimed == $base
      or die "a reservation whose owner has gone was not reclaimed\n";
   unlink vcsc_x_reserve_path($base);

   spew_reservation($base + 1, $self, $$, time());         # same account, alive
   my $mine = eval { vcsc_reserve_x_display($base + 1, 1) };
   defined($mine)
      and die "stole a reservation held by this very live process\n";
   unlink vcsc_x_reserve_path($base + 1);

   spew_reservation($base + 2, 'another-account', $$, time());
   my $foreign = eval { vcsc_reserve_x_display($base + 2, 1) };
   defined($foreign)
      and die "cross-account liveness was decided by a kill(0) that cannot see it\n";
   unlink vcsc_x_reserve_path($base + 2);

   # The same foreign reservation becomes reclaimable once it ages out, which bounds
   # how long a killed run in another account can keep a display hidden.
   spew_reservation($base + 3, 'another-account', $$, time() - 99999);
   my ($aged) = eval { vcsc_reserve_x_display($base + 3, 1) };
   defined($aged) && $aged == $base + 3
      or die "another account's reservation did not age out\n";
   unlink vcsc_x_reserve_path($base + 3);

   # A reservation that exists but carries no readable owner record is not evidence
   # of a dead owner.  The claim is created with O_EXCL and the record is written
   # afterwards and flushed at close, so a peer can read the file while it is still
   # empty.  Reading that as abandoned lets the peer unlink a live claim and take the
   # same display, which is the race this mechanism exists to prevent -- measured
   # here as five concurrent claims landing on one display before it was fixed.
   open(my $half, '>', vcsc_x_reserve_path($base + 4)) or die "could not plant a blank claim: $!\n";
   close($half);
   my $blank = eval { vcsc_reserve_x_display($base + 4, 1) };
   defined($blank)
      and die "a claim whose owner record is not yet readable was taken as abandoned\n";
   unlink vcsc_x_reserve_path($base + 4);
}

# --- the reservation is atomic under real contention ---------------------------
# Each claim is HELD while the others contend.  Without the hold this only measures
# how fast the loop runs and passes trivially.
{
   my $base = $free_base + 16;
   my $claim = File::Spec->catfile($tmp, 'vcsc_x_claim.pl');
   open(my $fh, '>', $claim) or die "could not write the claim helper: $!\n";
   # Each claim is HELD until the parent releases everyone.  A fixed sleep would be
   # wrong: under load the last process can start after the first has already
   # released, and reusing a freed display is then correct behaviour rather than a
   # collision, so a fixed hold makes the test fail for the wrong reason.  With a
   # barrier all twelve hold at once, and a range exactly twelve wide means any
   # duplicate would leave somebody with no display at all.
   print {$fh} <<'CLAIM';
use strict;
use warnings;
require $ARGV[0];
$| = 1;                      # report on claiming, not on exit: the parent waits for these
my ($n) = vcsc_reserve_x_display($ARGV[1], $ARGV[2]);
print "$n\n";
for (1 .. 600) { last if -e $ARGV[3]; select undef, undef, undef, 0.05 }
END { vcsc_release_x_displays() }
CLAIM
   close($fh);

   my $out = File::Spec->catfile($tmp, 'vcsc_x_claims.txt');
   my $release = File::Spec->catfile($tmp, 'vcsc_x_release');
   unlink $out, $release;
   my $lib = File::Spec->catfile($repo, qw(test stella_test_lib.pl));
   my @pids;
   for (1 .. 12) {
      my $pid = fork();
      defined($pid) or die "could not fork a claim: $!\n";
      if (!$pid) {
         # Appending, not truncating: all twelve write to the same file and a '>'
         # open would have each of them discard the previous reports.
         open(STDOUT, '>>', $out) or die $!;
         exec($^X, $claim, $lib, $base, 12, $release);
         die "could not exec a claim: $!\n";
      }
      push @pids, $pid;
   }

   # Wait for every claim to be held before letting any of them go.
   my @got;
   for (my $waited = 0; $waited < 300; $waited++) {
      if (open($fh, '<', $out)) {
         my $raw = do { local $/; <$fh> };
         close($fh);
         # Only whole lines count.  The file is being appended to concurrently, so a
         # read can catch a partially written number; treating a torn "40" as a
         # finished claim would satisfy the barrier early and let a claim be
         # released and legitimately reused, which then reads as a collision.
         @got = ($raw =~ /(\d+)\n/g);
         last if @got >= 12;
      }
      select undef, undef, undef, 0.1;
   }
   open(my $go, '>', $release) or die "could not release the claims: $!\n";
   close($go);
   waitpid($_, 0) for @pids;

   @got == 12 or die "12 concurrent claims produced @{[scalar @got]} reports\n";
   my %seen;
   $seen{$_}++ for @got;
   my @duplicated = sort { $a <=> $b } grep { $seen{$_} > 1 } keys %seen;
   @duplicated
      and die "concurrent claims collided on displays @duplicated\n";
   scalar glob(vcsc_x_reserve_path($base) . '*')
      and die "a reservation outlived the process that took it\n";
}

# --- a server that never came up is reported, not absorbed ---------------------
# The reservation makes a display UNIQUE; it cannot make a server START.  Without
# this check the failure surfaces later as an opaque Stella error with nothing
# pointing at the cause, which is how the original race stayed hidden.
{
   my $pid = fork();
   defined($pid) or die "could not fork a doomed server: $!\n";
   exit 3 unless $pid;
   my $ok = eval { vcsc_xvfb_assert_ready(':' . ($free_base + 28), $pid); 1 };
   my $err = $@;
   $ok and die "the readiness assertion accepted a server that had already exited\n";
   $err =~ /exit 3/
      or die "the refusal must report the exit status, but said: $err";
}

{
   my ($n, $display) = vcsc_reserve_x_display($free_base + 29, 1);
   my $pid = fork();
   defined($pid) or die "could not fork a mute server: $!\n";
   unless ($pid) { select undef, undef, undef, 30; exit 0 }
   my $ok = eval { vcsc_xvfb_assert_ready($display, $pid); 1 };
   my $err = $@;
   kill 'TERM', $pid;
   waitpid($pid, 0);
   $ok and die "the readiness assertion accepted a server that never listened\n";
   $err =~ /never began accepting connections/
      or die "the refusal must say the server never accepted connections, but said: $err";
   vcsc_release_x_displays();
}

# --- no runner may go back to probing for a display ----------------------------
# The behaviour above is worth nothing if a new runner reinstates the old probe, so
# the contract is checked on the source rather than left to review.
{
   my @offenders;
   my $starters = 0;
   for my $file (sort glob(File::Spec->catfile($repo, 'test', '*.pl'))) {
      next if $file =~ /stella_test_lib\.pl$/;        # quotes the old pattern on purpose
      next if $file =~ /stella_snapshot_keys\.pl$/;   # connects, does not serve
      next if $file =~ /vcs_stella_x_display_allocation\.pl$/;   # this file
      open(my $fh, '<', $file) or die "could not read $file: $!\n";
      my $src = do { local $/; <$fh> };
      close($fh);
      push @offenders, "$file picks a display by testing for the socket"
         if $src =~ /while\s*-?\s*-e\s*"?\/tmp\/\.X11-unix/;
      if ($src =~ /exec\(\s*\$xvfb/) {
         $starters++;
         push @offenders, "$file starts Xvfb without asserting that it came up"
            unless $src =~ /vcsc_xvfb_assert_ready/;
      }
   }
   $starters >= 20
      or die "the contract scan only found $starters runners starting Xvfb; it is not seeing the tree\n";
   @offenders
      and die "the X display contract has been broken:\n  " . join("\n  ", @offenders) . "\n";
}

print "vcs_stella_x_display_allocation ok\n";
exit 0;