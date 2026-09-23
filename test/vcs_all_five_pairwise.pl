#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: vcs_all_five_pairwise ok

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub read_file {
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return defined($d)?$d:'';
}
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing $name\n";
   my $value=hex($1);
   $value <= 0xff or die "$name is not in zero page\n";
   return $value;
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_192 smoke.c26));
my $bin=File::Spec->catfile($tmp,'all_five_pairwise.bin');
my $mapfile=File::Spec->catfile($tmp,'all_five_pairwise.map');
my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "all-five pairwise diagnostic build failed\n$out$err";
without_cartridge_usage($out) eq '' && $err eq ''
   or die "all-five pairwise diagnostic build wrote output\n$out$err";
my $map=read_file($mapfile);
my $object_x=map_symbol($map,'game_object_x');

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $src=File::Spec->catfile($repo,'test','vcs_all_five_pairwise.cpp');
my $exe=File::Spec->catfile($tmp,'vcs_all_five_pairwise');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
$rc==0 && !$sig or die "all-five pairwise harness build failed\n$out$err";
without_cartridge_usage($out) eq '' && $err eq ''
   or die "all-five pairwise harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($exe,$bin,sprintf('0x%02x',$object_x));
$rc==0 && !$sig or die "all-five pairwise harness failed\n$out$err";
$out eq "vcs_all_five_pairwise ok: 10 pairs x 160 x 160 = 256000 cases\n"
   or die "unexpected all-five pairwise harness output: $out";
$err eq '' or die "all-five pairwise harness stderr: $err";
print "vcs_all_five_pairwise ok\n";
