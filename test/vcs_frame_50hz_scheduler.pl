#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_frame_50hz_scheduler ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
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
sub write_file {
   my($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n";
   print {$f} $d; close($f) or die "close $p: $!\n";
}
sub without_cartridge_usage {
   my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out;
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $harness_src=File::Spec->catfile($repo,qw(test vcs_frame_50hz_scheduler.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_frame_50hz_scheduler');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$harness_src,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "scheduler harness build failed\n$out$err";
$out eq '' && $err eq '' or die "scheduler harness build wrote output\n$out$err";

for my $standard (qw(pal secam)) {
   my $upper=uc($standard);
   for my $case (
      ['normal',5,4,0],
      ['boundary',43,34,1],
      ['vblank-overrun',45,34,1],
      ['overscan-overrun',43,36,1],
   ) {
      my($mode,$vblank_wait,$overscan_wait,$diagnostics)=@$case;
      my $source=File::Spec->catfile($tmp,"${standard}_${mode}.c26");
      my $bin=File::Spec->catfile($tmp,"${standard}_${mode}.bin");
      my $mapfile=File::Spec->catfile($tmp,"${standard}_${mode}.map");
      my $diag=$diagnostics ? "alias VCS_${upper}_DIAGNOSTICS 1\n" : '';
      write_file($source,<<"SRC");
${diag}include "vcs.c26"
include "frame_${standard}.c26"

void main(void) {
   while (1) {
      vcs_${standard}_vsync();
      vcs_${standard}_begin_vblank();
      vcs_${standard}_wait_scanlines($vblank_wait);
      vcs_${standard}_end_vblank();
      vcs_${standard}_wait_scanlines(VCS_${upper}_VISIBLE_SCANLINES`uint8_t);
      asm nop;
      vcs_${standard}_begin_overscan();
      vcs_${standard}_wait_scanlines($overscan_wait);
      vcs_${standard}_end_overscan();
   }
}
SRC
      ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$source,'-o',$bin);
      $rc==0 && !$sig or die "$standard $mode build failed\n$out$err";
      without_cartridge_usage($out) eq '' && $err eq ''
         or die "$standard $mode build wrote output\n$out$err";
      -s $bin == 4096 or die "$standard $mode ROM is not exactly 4096 bytes\n";
      my $map=read_file($mapfile);
      my $flag_arg='none';
      if ($diagnostics) {
         $map =~ /vcs_${standard}_overrun_flags.*?run=\$([0-9A-Fa-f]{4})/
            or die "$standard $mode map is missing diagnostic flags\n";
         $flag_arg=sprintf('0x%04x',hex($1));
         $map =~ /vcs_${standard}_overrun_phase/
            or die "$standard $mode map is missing diagnostic phase byte\n";
      }
      else {
         $map !~ /vcs_${standard}_overrun_(?:flags|phase)/
            or die "$standard production scheduler retained diagnostic RAM\n";
      }
      ($rc,$sig,$out,$err)=capture($harness,$bin,$mode,$flag_arg);
      $rc==0 && !$sig or die "$standard $mode scheduler run failed\n$out$err";
      $out eq "vcs_frame_50hz_scheduler $mode ok\n"
         or die "unexpected $standard $mode harness output: $out";
      $err eq '' or die "$standard $mode harness stderr: $err";
   }
}
print "vcs_frame_50hz_scheduler ok\n";
