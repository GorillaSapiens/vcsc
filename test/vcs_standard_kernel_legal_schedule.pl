#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//;
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
my $profile=File::Spec->catdir($vcs,qw(kernels standard_4k_ntsc));
my $source=File::Spec->catfile($repo,qw(test fixtures vcs_examples 05_static_kernel golden.c26));
my $kernel=File::Spec->catfile($profile,'standard_4k_ntsc_kernel.s26');
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $bin=File::Spec->catfile($tmp,'legal_schedule.bin');
my $mapfile=File::Spec->catfile($tmp,'legal_schedule.map');
my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,
   $source,$kernel,'-o',$bin);
$rc==0 && !$sig or die "static-kernel build failed\n$out$err";
without_cartridge_usage($out) eq '' && $err eq '' or die "static-kernel build wrote output\n$out$err";
my $map=read_file($mapfile);
my @zp=map { map_symbol($map,$_) } qw(
   vcs_standard_object_masks
);

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $src=File::Spec->catfile($repo,'test','vcs_standard_kernel_legal_schedule.cpp');
my $exe=File::Spec->catfile($tmp,'legal_schedule');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
$rc==0 && !$sig or die "mask schedule harness build failed\n$out$err";
without_cartridge_usage($out) eq '' && $err eq '' or die "mask schedule build wrote output\n$out$err";
my $base=$zp[0];
my @args=(sprintf('0x%02x',$base));
($rc,$sig,$out,$err)=capture($exe,$bin,@args);
$rc==0 && !$sig or die "mask schedule harness failed\n$out$err";
$out eq "vcs_standard_kernel_legal_schedule ok: 46 scanlines, three steady masks and five final values locked\n"
   or die "unexpected mask schedule output: $out";
$err eq '' or die "mask schedule stderr: $err";
print "vcs_standard_kernel_legal_schedule ok\n";
