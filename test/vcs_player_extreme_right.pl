#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_player_extreme_right ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
sub slurp { my($f)=@_; local $/; my $s=<$f>; defined($s)?$s:'' }
sub run {
   my(@c)=@_; my $e=gensym; my $p=open3(my $i,my $o,$e,@c); close $i;
   my $so=slurp($o); my $se=slurp($e); waitpid($p,0);
   return ($?>>8,$?&127,$so,$se);
}
my $repo=abs_path(shift @ARGV // die "repo\n");
my $tmp=abs_path(shift @ARGV // die "tmp\n");
die "args\n" if @ARGV;
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $obj=File::Spec->catfile($mos,'mos6502.o');
my @mos=-f $obj ? ($obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $exe=File::Spec->catfile($tmp,'vcs_player_extreme_right');
my($rc,$sig,$out,$err)=run($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_standard_objects.cpp)),@mos,'-o',$exe);
die "harness build failed\n$out$err" if $rc || $sig;
for my $kind (qw(181 192)) {
   my $src=File::Spec->catfile($repo,qw(test fixtures player_color_extreme_right),"checker_${kind}.c26");
   my $bin=File::Spec->catfile($tmp,"checker_${kind}.bin");
   ($rc,$sig,$out,$err)=run($driver,'-I',$vcs,$src,'-o',$bin);
   die "checker $kind build failed\n$out$err" if $rc || $sig;
   ($rc,$sig,$out,$err)=run($exe,$bin,'--players-hblank');
   die "checker $kind timing failed\n$out$err" if $rc || $sig;
   $out eq "vcs_player_extreme_right ok: checkerboard P0/P1 commits remain in HBLANK\n"
      or die "checker $kind output: $out";
   $err eq '' or die "checker $kind stderr: $err";
}
print "vcs_player_extreme_right ok\n";
