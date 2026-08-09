#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: compiler dash stdout semantics passed
# expectstderrexact:

use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

my $repo = shift @ARGV // die "usage: $0 REPO TMP\n";
my $tmp  = shift @ARGV // die "usage: $0 REPO TMP\n";
$repo = abs_path($repo) // die "could not resolve repo root\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $cc1 = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $inc = File::Spec->catdir($repo, 'test');
-x $cc1 or die "missing compiler: $cc1\n";
-x $vcsc or die "missing driver: $vcsc\n";

my $src = File::Spec->catfile($tmp, 'dash_stdout.c26');
open(my $srcfh, '>', $src) or die "write $src: $!\n";
print {$srcfh} <<'SRC';
include "machine_6502.c26"
void main(void) {
}
SRC
close($srcfh);

sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}

my $old = getcwd();
chdir($tmp) or die "chdir $tmp: $!\n";

my ($exit, $sig, $stdout, $stderr) = run_capture($cc1, '-quiet', '-I', $inc, $src, '-o', '-');
die "vcsc-cc1 -o - failed exit=$exit signal=$sig\n$stderr" if $exit || $sig;
die "vcsc-cc1 -o - wrote stderr:\n$stderr" if $stderr ne '';
die "vcsc-cc1 -o - did not emit assembly on stdout\n" if $stdout !~ /this file produced by \"vcsc-cc1\" compiler/;
die "vcsc-cc1 -o - created a literal '-' file\n" if -e '-';

($exit, $sig, $stdout, $stderr) = run_capture($vcsc, '-S', '-I', $inc, '-o', '-', $src);
die "vcsc -S -o - failed exit=$exit signal=$sig\n$stderr" if $exit || $sig;
die "vcsc -S -o - wrote stderr:\n$stderr" if $stderr ne '';
die "vcsc -S -o - did not emit assembly on stdout\n" if $stdout !~ /this file produced by \"vcsc-cc1\" compiler/;
die "vcsc -S -o - created a literal '-' file\n" if -e '-';

($exit, $sig, $stdout, $stderr) = run_capture($vcsc, '-v', '-S', '-I', $inc, '-o', '-', $src);
die "vcsc -v -S -o - failed exit=$exit signal=$sig\n$stderr" if $exit || $sig;
die "vcsc -v -S -o - did not keep assembly on stdout\n" if $stdout !~ /this file produced by \"vcsc-cc1\" compiler/;
die "vcsc -v -S -o - polluted stdout with its command trace\n" if $stdout =~ /vcsc-cc1 .* -o -/s;
die "vcsc -v -S -o - did not put its command trace on stderr\n" if $stderr !~ /vcsc-cc1 .* -o -/s;
die "vcsc -v -S -o - created a literal '-' file\n" if -e '-';

for my $mode (['-c'], []) {
   my @args = (@$mode, '-I', $inc, '-o', '-', $src);
   ($exit, $sig, $stdout, $stderr) = run_capture($vcsc, @args);
   die "vcsc @args unexpectedly accepted non-assembly stdout output\n" if !$exit && !$sig;
   die "vcsc @args wrong diagnostic:\n$stderr" if $stderr !~ /-o - is supported only with -S/;
   die "vcsc @args created a literal '-' file\n" if -e '-';
}

chdir($old) or die "chdir $old: $!\n";
print "compiler dash stdout semantics passed\n";
