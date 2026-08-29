#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: bank switching example make passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub run_capture {
   my(@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($? >> 8,$? & 127,$stdout,$stderr);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";

my $src=File::Spec->catdir($repo,'examples','09_bankswitching','01_diagnostic');
my $work=File::Spec->catdir($tmp,'bankswitching-example');
make_path($work);
for my $name (qw(Makefile bankswitching_diagnostic.c26 status_font.c26 cart_type_font.c26)) {
   copy(File::Spec->catfile($src,$name),File::Spec->catfile($work,$name))
      or die "copy $name: $!\n";
}

my($rc,$sig,$stdout,$stderr)=run_capture(
   'make','-C',$work,
   'ROOT='.$repo,
   'VCSC='.File::Spec->catfile($repo,'driver','vcsc'),
   'VCS_DIR='.File::Spec->catdir($repo,'libraries','vcs'),
   'all'
);
$rc==0 && !$sig
   or die "diagnostic example make failed rc=$rc sig=$sig\nstdout:\n$stdout\nstderr:\n$stderr";
$stderr !~ /(?:^|\n)\/bin\/sh: .*: not found(?:\n|$)/
   or die "diagnostic example make executed malformed command substitutions:\n$stderr";

for my $stem (qw(f8 f6 f4 f8sc f6sc f4sc poisoned)) {
   -s File::Spec->catfile($work,"$stem.bin")
      or die "missing $stem.bin\n";
   -s File::Spec->catfile($work,"$stem.map")
      or die "missing $stem.map\n";
}
my @bins=glob(File::Spec->catfile($work,'*.bin'));
@bins==7 or die "diagnostic example emitted ".scalar(@bins)." binaries instead of seven\n";
for my $suffix (qw(bin hex map sym lst cfg)) {
   !-e File::Spec->catfile($work,".$suffix")
      or die "malformed empty-stem artifact .$suffix was created\n";
}

print "bank switching example make passed\n";
