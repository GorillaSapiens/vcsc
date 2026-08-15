#!/usr/bin/perl
# runner: perl @FILE@
# phase: e2e
# expectstdout: runner timing report ok
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);

my $tmp = tempdir('vcsc_runner_timing_XXXX', TMPDIR => 1, CLEANUP => 1);
my $timings = File::Spec->catfile($tmp, 'test-times.tsv');
my $slow = File::Spec->catfile($Bin, 'fixtures', 'runner_fixture_pass.test');
my $fast = File::Spec->catfile($Bin, 'fixtures', 'runner_fixture_fast.test');
my $runner = File::Spec->catfile($Bin, 'test.pl');

sub run_ok {
   my (@args) = @_;
   system($^X, $runner, @args) == 0
      or die "nested test runner failed: $?\n";
}

run_ok('--jobs', '2', '--timings', $timings, $slow, $fast);
run_ok('--jobs', '2', '--timings', $timings, '--timings-append', $fast);

open(my $fh, '<', $timings) or die "could not open timing report: $!\n";
my @lines = <$fh>;
close($fh);
chomp @lines;

@lines == 4 or die "expected one header plus three timing rows, got " . scalar(@lines) . " lines\n";
$lines[0] eq "seconds\tstatus\tphase\ttest"
   or die "bad timing report header: $lines[0]\n";

my @expected = ('runner_fixture_pass.test', 'runner_fixture_fast.test', 'runner_fixture_fast.test');
for my $i (0..2) {
   my @field = split(/\t/, $lines[$i + 1], 4);
   @field == 4 or die "bad timing row: $lines[$i + 1]\n";
   $field[0] =~ /^\d+\.\d{6}$/ or die "bad elapsed seconds: $field[0]\n";
   $field[1] eq 'pass' or die "bad timing status: $field[1]\n";
   $field[2] eq 'e2e' or die "bad timing phase: $field[2]\n";
   $field[3] =~ /\Q$expected[$i]\E\z/ or die "bad timing test name: $field[3]\n";
}

my ($slow_seconds) = split(/\t/, $lines[1], 2);
$slow_seconds >= 0.8 or die "slow fixture timing was not measured inside the worker: $slow_seconds\n";

print "runner timing report ok\n";
