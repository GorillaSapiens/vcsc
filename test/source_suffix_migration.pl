#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: assembler source suffix migration passed
# expectstderrexact:

use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use File::Find;
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
$repo = abs_path($repo) // die "cannot resolve repo\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "cannot resolve tmp\n";

my @bad;
find({
   no_chdir => 1,
   wanted => sub {
      return if -d $_;
      my $path = $File::Find::name;
      my $rel = File::Spec->abs2rel($path, $repo);
      return if $rel =~ m{^\.\.\.(?:/|$)};
      return if $rel =~ m{^libraries/vcs/legacy-basic-renderers(?:/|$)};
      push @bad, $rel if $rel =~ /\.s\z/;
   },
}, $repo);
die "maintained generic .s assembler sources remain:\n" . join("\n", sort @bad) . "\n" if @bad;

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>', $path) or die "cannot write $path: $!\n";
   print {$fh} $text;
   close($fh) or die "cannot close $path: $!\n";
}

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

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $inc = File::Spec->catdir($repo, 'test');
-x $vcsc or die "missing driver $vcsc\n";
-x $as or die "missing assembler $as\n";

my $src = File::Spec->catfile($tmp, 'suffix_probe.c26');
write_file($src, "include \"machine_6502.c26\"\nvoid main(void) {}\n");
my ($exit, $sig, $out, $err) = run_capture($vcsc, '-S', '-I', $inc, $src);
die "driver -S failed exit=$exit sig=$sig\n$out$err" if $exit != 0 || $sig != 0;
my $generated = File::Spec->catfile($tmp, 'suffix_probe.s26');
-f $generated or die "driver -S did not create canonical suffix_probe.s26\n";
!-e File::Spec->catfile($tmp, 'suffix_probe.s') or die "driver -S created obsolete suffix_probe.s\n";

my $obj = File::Spec->catfile($tmp, 'suffix_probe.o26');
($exit, $sig, $out, $err) = run_capture($vcsc, '-c', $generated, '-o', $obj);
die "driver rejected canonical .s26 input\n$out$err" if $exit != 0 || $sig != 0;
-f $obj or die "driver did not produce object from .s26 input\n";
$err !~ /legacy assembler suffix/ or die "canonical .s26 input emitted legacy warning\n$err";

my $legacy = File::Spec->catfile($tmp, 'legacy.s');
write_file($legacy, ".byte 1\n");
my $legacy_obj = File::Spec->catfile($tmp, 'legacy.o26');
($exit, $sig, $out, $err) = run_capture($vcsc, '-c', $legacy, '-o', $legacy_obj);
die "temporary legacy .s compatibility failed\n$out$err" if $exit != 0 || $sig != 0;
-f $legacy_obj or die "legacy .s compatibility did not produce object\n";
$err =~ /legacy assembler suffix '\.s'.*use '\.s26'/s
   or die "legacy .s compatibility lacked explicit warning\n$err";

print "assembler source suffix migration passed\n";
