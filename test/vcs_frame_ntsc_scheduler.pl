#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

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
sub without_cartridge_usage {
   my($out)=@_; $out =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+//; return $out;
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $fixtures=File::Spec->catdir($repo,qw(test fixtures frame_ntsc_scheduler));
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $harness_src=File::Spec->catfile($repo,qw(test vcs_frame_ntsc_scheduler.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_frame_ntsc_scheduler');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$harness_src,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "scheduler harness build failed\n$out$err";
$out eq '' && $err eq '' or die "scheduler harness build wrote output\n$out$err";

my @cases=(
   ['normal','normal.c26','none'],
   ['boundary','boundary.c26',undef],
   ['vblank-overrun','vblank_overrun.c26',undef],
   ['overscan-overrun','overscan_overrun.c26',undef],
);
for my $case (@cases) {
   my($mode,$source_name,$flag_arg)=@$case;
   my $source=File::Spec->catfile($fixtures,$source_name);
   my $bin=File::Spec->catfile($tmp,"$mode.bin");
   my $mapfile=File::Spec->catfile($tmp,"$mode.map");
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$source,'-o',$bin);
   $rc==0 && !$sig or die "$mode build failed\n$out$err";
   without_cartridge_usage($out) eq '' && $err eq ''
      or die "$mode build wrote output\n$out$err";
   -s $bin == 4096 or die "$mode ROM is not exactly 4096 bytes\n";
   my $map=read_file($mapfile);
   if ($mode eq 'normal') {
      $map !~ /vcs_ntsc_overrun_(?:flags|phase)/
         or die "production scheduler retained diagnostic RAM\n";
   }
   else {
      $map =~ /vcs_ntsc_overrun_flags.*?run=\$([0-9A-Fa-f]{4})/
         or die "$mode map is missing diagnostic flags\n";
      $flag_arg=sprintf('0x%04x',hex($1));
      $map =~ /vcs_ntsc_overrun_phase/
         or die "$mode map is missing diagnostic phase byte\n";
   }
   ($rc,$sig,$out,$err)=capture($harness,$bin,$mode,$flag_arg);
   $rc==0 && !$sig or die "$mode scheduler run failed\n$out$err";
   $out eq "vcs_frame_ntsc_scheduler $mode ok\n"
      or die "unexpected $mode harness output: $out";
   $err eq '' or die "$mode harness stderr: $err";
}
print "vcs_frame_ntsc_scheduler ok\n";
