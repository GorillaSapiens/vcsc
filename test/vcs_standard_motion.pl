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

sub map_any_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(kernels standard_4k_ntsc));
my $source=File::Spec->catfile($repo,qw(test fixtures vcs_examples 06_object_motion golden.c26));
my $kernel=File::Spec->catfile($profile,'standard_4k_ntsc_kernel.s26');
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $bin=File::Spec->catfile($tmp,'object_motion_test.bin');
my $mapfile=File::Spec->catfile($tmp,'object_motion_test.map');
my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,
   $source,$kernel,'-o',$bin);
$rc==0 && !$sig or die "motion diagnostic build failed\n$out$err";
without_cartridge_usage($out) eq '' && $err eq '' or die "motion diagnostic build wrote output\n$out$err";
my $map=read_file($mapfile);
my $strong_hook=map_any_symbol($map,'vcs_standard_overscan_hook');
my $weak_hook=map_any_symbol($map,'__weak_vcs_standard_overscan_hook');
$strong_hook != $weak_hook or die "strong overscan hook did not override weak fallback\n";
$map =~ /region=RAM\s+depth=5\s+bytes=\$000E\s+physical=\$00F2-\$00FF\s+extra=\$0004/
   or die "motion cartridge stack map does not include main -> drawscreen -> hook -> update -> move\n";
my @zp=map { map_symbol($map,$_) } qw(
   vcs_standard_object_x
   vcs_standard_player0_y
   vcs_standard_player1_y
   vcs_standard_missile0_y
   vcs_standard_missile1_y
   vcs_standard_ball_y
   motion_frame
);

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $src=File::Spec->catfile($repo,'test','vcs_standard_motion.cpp');
my $exe=File::Spec->catfile($tmp,'vcs_standard_motion');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
$rc==0 && !$sig or die "motion harness build failed\n$out$err";
without_cartridge_usage($out) eq '' && $err eq '' or die "motion harness build wrote output\n$out$err";
my @args=map { sprintf('0x%02x',$_) } @zp;
($rc,$sig,$out,$err)=capture($exe,$bin,@args);
$rc==0 && !$sig or die "motion harness failed\n$out$err";
$out eq "vcs_standard_motion ok: 320 full-range X/HMOVE states and seven exact object rasters locked\n"
   or die "unexpected motion harness output: $out";
$err eq '' or die "motion harness stderr: $err";
print "vcs_standard_motion ok\n";
