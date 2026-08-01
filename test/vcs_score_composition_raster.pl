#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 30
# expectstdout: vcs_score_composition_raster ok: 8 big-renderer score orders have exact 48x8 pixels and boundary cycles
# expectexit: 0

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
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $raster_src=File::Spec->catfile($repo,qw(test vcs_six_glyph_raster.cpp));
my $raster=File::Spec->catfile($tmp,'vcs_score_composition_raster');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-DILLEGAL_OPCODES','-I',$mos,$raster_src,@mos_input,'-o',$raster);
$rc==0 && !$sig or die "score-raster harness build failed\n$out$err";
$out eq '' && $err eq '' or die "score-raster harness build wrote output\n$out$err";

my @families=(
   ['all_five_181',0],
   ['player_color_181',0],
   ['all_five_181_unofficial',1],
   ['player_color_181_unofficial',1],
);
my $checked=0;
for my $family (@families) {
   my($name,$illegals)=@$family;
   for my $order (qw(above below)) {
      my $src=File::Spec->catfile($repo,'test','fixtures',$name,"static_score_${order}.c26");
      my $bin=File::Spec->catfile($tmp,"${name}_${order}.bin");
      my @extra=$illegals ? ('-Wa,--illegals') : ();
      ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,@extra,$src,'-o',$bin);
      $rc==0 && !$sig or die "$name $order build failed\n$out$err";
      without_usage($out) eq '' && $err eq '' or die "$name $order build wrote output\n$out$err";
      -s $bin == 4096 or die "$name $order is not a 4K ROM\n";
      my $entry=$order eq 'above' ? 40 : 221;
      ($rc,$sig,$out,$err)=capture($raster,$bin,$entry,'123456');
      $rc==0 && !$sig or die "$name $order score raster failed\n$out$err";
      $out eq "vcs_six_glyph_raster ok: 1 exact 48x8 score rasters, hostile reflection reset, and 262-line frames\n"
         or die "unexpected $name $order raster output: $out";
      $err eq '' or die "$name $order raster stderr: $err";
      ++$checked;
   }
}
$checked==8 or die "checked $checked score compositions, expected 8\n";
print "vcs_score_composition_raster ok: 8 big-renderer score orders have exact 48x8 pixels and boundary cycles\n";
