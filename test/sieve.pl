#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: Sieve smoke test passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub run_capture {
    my (@cmd) = @_;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);
    close $in;
    local $/;
    my $stdout = <$out> // '';
    my $stderr = <$err> // '';
    waitpid($pid, 0);
    return ($? >> 8, $? & 127, $stdout, $stderr);
}

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $driver = File::Spec->catfile($repo, qw(driver vcsc));
my $sim = File::Spec->catfile($repo, qw(simulator vcsc-sim));
my $src = File::Spec->catfile($repo, qw(test sieve.c26));
my $cfg = File::Spec->catfile($repo, qw(test generic_6502.cfg));
my $hex = File::Spec->catfile($tmp, 'sieve.hex');

my ($rc, $sig, $out, $err) = run_capture($driver, '-I', File::Spec->catdir($repo, 'test'), '-T', $cfg, $src, '-o', $hex);
die "sieve compile failed rc=$rc sig=$sig\nstdout:\n$out\nstderr:\n$err" if $rc || $sig;

# The program deliberately runs forever. Read ten lines, then terminate the
# simulator. This is the deterministic test-suite form of the historical
# `vcsc-sim sieve.hex | head` smoke target.
pipe(my $reader, my $writer) or die "pipe: $!\n";
my $pid = fork();
die "fork: $!\n" unless defined $pid;
if ($pid == 0) {
    close $reader;
    open STDOUT, '>&', $writer or die "redirect stdout: $!\n";
    close $writer;
    open STDERR, '>', File::Spec->devnull() or die "redirect stderr: $!\n";
    exec $sim, $hex;
    die "exec $sim: $!\n";
}
close $writer;
my @got;
for (1 .. 10) {
    my $line = <$reader>;
    die "sieve simulator ended before ten primes\n" unless defined $line;
    chomp $line;
    push @got, $line;
}
close $reader;
kill 'TERM', $pid;
waitpid($pid, 0);
my @want = qw(2 3 5 7 11 13 17 19 23 29);
die "sieve output mismatch: got [@got], expected [@want]\n" unless "@got" eq "@want";
print "Sieve smoke test passed\n";
