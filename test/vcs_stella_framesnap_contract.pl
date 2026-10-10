#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_stella_framesnap_contract ok
# expectexit: 0

# Contract for the Stella build these tests are certified against.
#
# The certification runners snapshot by asking Stella to save a frame at a known
# index, using -framesnap.  That option is a LOCAL ADDITION to Stella, not stock
# upstream behaviour, so an unpatched or upgraded Stella would silently ignore it
# rather than fail: the runners would fall back to timing-dependent capture and
# the rasters would stop being reproducible without anything saying why.
#
# This asserts the two things that actually matter, in increasing cost:
#
#   1. The Stella on PATH ADVERTISES -framesnap in its own -help output.  This is
#      a declared capability rather than an inferred one -- a build that dropped
#      the option, or a distribution package that predates it, is rejected here
#      with a message naming the binary, instead of by a digest mismatch much
#      later in a raster comparison.
#
#   2. The option is FUNCTIONAL, not merely present: a real ROM run snapshots at
#      the requested frame, and the same frame yields the same bytes twice.  A
#      help string can survive a patch that no longer compiles into working code,
#      so the claim "good stella" is only worth anything if it is exercised.
#
# Determinism is the whole reason the runners are moving to this, so the second
# check runs the same frame twice and compares.  It is checked serially and twice
# rather than once, because a single capture cannot distinguish "deterministic"
# from "happened to agree".
#
# The serial directive is NOT an optimisation choice here.  This is a two-capture
# comparison, so it asserts nothing about behaviour under concurrent load; what
# makes the certification runs safe to drop their serial marking is a separate,
# heavier measurement, and this test deliberately does not pretend to establish it.

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Spec;
use File::Path qw(make_path remove_tree);

@ARGV == 2 or die "usage: $0 REPO TMP\n";
my ($repo, $tmp) = @ARGV;
$repo = abs_path($repo) or die "could not resolve repo\n";
make_path($tmp);
$tmp = abs_path($tmp);

require File::Spec->catfile($repo, qw(test stella_test_lib.pl));

sub findexe {
   my ($name) = @_;
   return abs_path($name) if $name =~ m{/} && -x $name;
   for (split(/:/, $ENV{PATH} // '')) {
      my $p = "$_/$name";
      return abs_path($p) if -x $p;
   }
   return undef;
}

sub slurp_fh { my ($fh) = @_; local $/; return <$fh> // ''; }

my $stella = findexe($ENV{VCSC_STELLA} || $ENV{STELLA} || 'stella')
   or die "set STELLA or VCSC_STELLA\n";
my $xvfb = findexe($ENV{VCSC_XVFB} || $ENV{XVFB} || 'Xvfb') or die "Xvfb required\n";
my $driver = File::Spec->catfile($repo, qw(driver vcsc));
my $vcs = File::Spec->catdir($repo, qw(libraries vcs));

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# 1. The option is advertised.
#
# Stella writes its help to stdout, and -help is documented to exit 0.  It is
# read from a PRIVATE Xvfb rather than from whatever display happens to be in the
# environment: running the emulator bare is what makes it try to open a window on
# an interactive session.

my $help_dir = File::Spec->catdir($tmp, 'help');
my $help_user = File::Spec->catdir($help_dir, 'user');
make_path($help_user);
vcsc_stella_private_env($help_user);

my (undef, $help_display) = vcsc_reserve_x_display(392, 10);
my $help_xvfb = fork();
defined $help_xvfb or die "fork Xvfb for the help probe failed\n";
if (!$help_xvfb) {
   open(STDOUT, '>:raw', File::Spec->catfile($help_dir, 'xvfb.log')) or die $!;
   open(STDERR, '>&STDOUT');
   exec($xvfb, $help_display, '-ac', '-screen', '0', '1024x768x24');
   die "exec Xvfb failed\n";
}
vcsc_xvfb_assert_ready($help_display, $help_xvfb);

my $help_text = do {
   local $ENV{DISPLAY} = $help_display;
   my $ph = open(my $pipe, '-|', $stella, '-help')
      or die "could not run $stella -help: $!\n";
   my $text = slurp_fh($pipe);
   close($pipe);
   $text;
};
vcsc_release_x_displays();

$help_text =~ /^\s+-framesnap\s+<number>\s+\S/m
   or die "$stella does not advertise -framesnap in -help.\n"
    . "This suite certifies rasters with -framesnap, which is a local addition to\n"
    . "Stella rather than stock upstream behaviour.  An unpatched or older build\n"
    . "would ignore the option and every certification would silently fall back to\n"
    . "timing-dependent capture, so the failure would surface as an unexplained\n"
    . "digest mismatch rather than here.  Rebuild Stella with the framesnap patch.\n";

# The option has to take an argument, not just exist as a name: a bare boolean
# would parse and then mean something else entirely.
$help_text =~ /^\s+-framesnap\s+<number>/m
   or die "$stella advertises -framesnap without a <number> argument\n";

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# 2. The option works, and the same frame captures the same bytes.
#
# A purpose-built ROM is used rather than a certification fixture: this test is
# about whether Stella can be driven, and driving it is easier to read off a ROM
# whose raster changes every frame.  Without that, a stalled capture and a correct
# one can produce identical output and the comparison proves nothing.

my $probe_source = File::Spec->catfile($tmp, 'framesnap_probe.c26');
open(my $sfh, '>', $probe_source) or die "could not write $probe_source: $!\n";
print {$sfh} <<'ROM';
// Frames whose raster differs on every frame, so "captured at the right frame"
// and "captured at some other frame" cannot be confused.
include "vcs.c26"

void main(void) {
   uint8_t f;
   COLUBK := 0x84;
   COLUPF := 0x2e;
   f := 0x11;
   while (1) {
      asm sta WSYNC;
      asm sta WSYNC;
      asm sta WSYNC;
      asm sta WSYNC;
      asm sta WSYNC;
      asm sta WSYNC;
      asm sta WSYNC;
      asm sta WSYNC;
      asm sta WSYNC;
      asm sta WSYNC;
      // Advance the playfield pattern every frame.  The counters are driven with
      // plain stores outside vblank on purpose: the point is only that no two
      // frames share a raster, not that this is well-timed 2600 code.
      //
      // The step has to be ODD as well as non-zero.  An even step walks a short
      // cycle through a 4-bit register value, so frames N and N+7 came out
      // identical and the option could not be shown to be selecting the frame it
      // was asked for.
      PF0 := f;
      PF1 := f;
      PF2 := 0x00;
      f := f + 3;
      if (f > 0x0f) { f := f - 0x10; }
   }
}
ROM
close($sfh);

my $probe_rom = File::Spec->catfile($tmp, 'framesnap_probe.bin');
{
   my $ph = open(my $pipe, '-|', $driver, '-I', $vcs, $probe_source, '-o', $probe_rom)
      or die "could not build the framesnap probe ROM: $!\n";
   my $out = slurp_fh($pipe);
   close($pipe);
   die "building the framesnap probe ROM failed:\n$out\n" if $? != 0;
}
-f $probe_rom && -s $probe_rom
   or die "framesnap probe ROM was not produced at $probe_rom\n";

# Capture one frame, on its own private display and user directory.
#
# -snapsavedir, -snapname, -sssingle and -ss1x are passed explicitly rather than
# inherited from the certification runners: this asserts the option on its own,
# and a capture that only works because some other setting happened to be in
# effect would not be evidence that -framesnap works.
sub capture_frame {
   my ($frame, $tag) = @_;
   my $dir = File::Spec->catdir($tmp, "run_$tag");
   my $snaps = File::Spec->catdir($dir, 'snap');
   my $user = File::Spec->catdir($dir, 'user');
   # The directory is removed first, not just created.  Reusing a $tmp that holds
   # the result of an earlier run would let a stale PNG satisfy the capture below,
   # which is exactly how a Stella that advertises -framesnap and then ignores it
   # would pass this test.
   remove_tree($dir);
   make_path($snaps, $user);

   vcsc_stella_private_env($user);
   my (undef, $display) = vcsc_reserve_x_display(392, 10);
   my $xpid = fork();
   defined $xpid or die "fork Xvfb for $tag failed\n";
   if (!$xpid) {
      open(STDOUT, '>:raw', File::Spec->catfile($dir, 'xvfb.log')) or die $!;
      open(STDERR, '>&STDOUT');
      exec($xvfb, $display, '-ac', '-screen', '0', '1024x768x24');
      die "exec Xvfb failed\n";
   }
   vcsc_xvfb_assert_ready($display, $xpid);

   my $log = File::Spec->catfile($dir, 'stella.log');
   my $pid = fork();
   defined $pid or die "fork Stella for $tag failed\n";
   if (!$pid) {
      open(STDOUT, '>:raw', $log) or die $!;
      open(STDERR, '>&STDOUT');
      $ENV{DISPLAY} = $display;
      # Determinism and reproducibility come from turbo mode plus the project's
      # pinned palette, so this capture is comparable with the certified ones:
      # nothing in this ROM is random, and no run is gated on wall-clock time.
      exec($stella,
           vcsc_stella_palette_args($repo, $user),
           '-turbo', '1',
           '-audio.enabled', '0',
           '-bs', '4K',
           '-plr.bankrandom', '0', '-plr.ramrandom', '0', '-plr.tiarandom', '0',
           '-dev.bankrandom', '0', '-dev.ramrandom', '0', '-dev.cpurandom', '0',
           '-dev.tiarandom', '0', '-dev.hsrandom', '0', '-dev.tiadriven', '0',
           '-video', 'software',
           '-framesnap', $frame,
           '-snapsavedir', $snaps, '-snapname', 'rom', '-sssingle', '1', '-ss1x', '1',
           '-exitlauncher', '0', '-confirmexit', '0',
           '-userdir', $user,
           $probe_rom);
      die "exec Stella failed\n";
   }

   # Wait for the snapshot.  Bounded so a build that accepts the flag and then does
   # nothing reports as a missing capture instead of hanging the suite.
   my $png;
   for (1 .. 600) {
      my @found = grep { -s $_ } glob(File::Spec->catfile($snaps, '*.png'));
      if (@found) { $png = $found[0]; last }
      select undef, undef, undef, 0.1;
   }
   kill 'TERM', $pid;
   select undef, undef, undef, 0.2;
   kill 'KILL', $pid;
   waitpid($pid, 0);
   vcsc_release_x_displays();

   my $log_text = do { local $/; open(my $fh, '<', $log); <$fh> // '' };
   defined $png
      or die "Stella produced no snapshot for -framesnap $frame.\n"
         . "The option is advertised in -help but did not capture anything.\n"
         . "Stella log:\n$log_text\n";
   return (sha256_hex(do { local $/; open(my $fh, '<:raw', $png); <$fh> }), $png);
}

# Two frames chosen to be far enough apart that the probe ROM's playfield pattern
# cannot have come back around between them.  Nearby frames are NOT safe here:
# measured on a real fixture, frames 84..93 produced byte-identical captures,
# because the raster genuinely does not change across that stretch.  Comparing
# N against N+1 would therefore pass for an emulator that ignored the frame
# number entirely.
my $frame_a = 40;
my $frame_b = 140;
my ($digest_a) = capture_frame($frame_a, 'a');
my ($digest_b) = capture_frame($frame_a, 'b');

# Same frame twice, same bytes.  This is the property the certification runners
# are being changed to rely on: if it does not hold, their pinned rasters cannot
# be trusted and the serial marking must stay.
$digest_a eq $digest_b
   or die "-framesnap $frame_a is not reproducible across runs\n"
    . "  first:  $digest_a\n  second: $digest_b\n"
    . "The certification runners capture at a fixed frame and compare pinned\n"
    . "digests, so this has to hold or every raster they certify is unreliable.\n";

# A DIFFERENT frame must produce a DIFFERENT capture, otherwise "reproducible"
# would be satisfied by an emulator that ignores the frame number and always
# writes the same image -- which would pass the comparison above while proving
# nothing about capturing the requested frame.
my ($digest_other) = capture_frame($frame_b, 'other');
$digest_other ne $digest_a
   or die "-framesnap did not distinguish frame $frame_a from frame $frame_b\n"
    . "Both produced $digest_a, so the option is not selecting the frame it\n"
    . "claims to and a reproducible digest here would mean nothing.\n";

print "vcs_stella_framesnap_contract ok\n";