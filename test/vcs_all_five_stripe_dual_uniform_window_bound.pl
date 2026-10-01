#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripe_dual_uniform_window_bound ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo); $tmp=abs_path($tmp);
my $probe=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_dual_uniform_window_bound.pl));
my($rc,$sig,$out,$err)=capture($^X,$probe);
$rc==0&&!$sig or die "dual-uniform window bound failed\n$out$err";
$out eq "stripe_dual_uniform_window_bound ok: old-safe=28 old-edge=26 scanlines\n"
   or die "dual-uniform window output changed: $out";
$err eq '' or die "dual-uniform window stderr: $err";
print "vcs_all_five_stripe_dual_uniform_window_bound ok\n";
