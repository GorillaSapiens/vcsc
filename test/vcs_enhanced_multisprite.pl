#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_enhanced_multisprite ok: 192-line symmetric P0/P1 multiplexer, 997-frame Y/XY timing sweeps, fair 3-way 2-of-3 rotation
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my$d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my$err=gensym; my$pid=open3(my$in,my$out,$err,@cmd); close($in);
   my$so=slurp_fh($out); my$se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub read_file { my($p)=@_; open(my$fh,'<:raw',$p) or die "read $p: $!\n"; local$/; my$d=<$fh>; close($fh); return defined($d)?$d:''; }
sub write_file { my($p,$d)=@_; open(my$fh,'>:raw',$p) or die "write $p: $!\n"; print{$fh}$d; close($fh) or die "close $p: $!\n"; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my$repo=shift@ARGV // usage(); my$tmp=shift@ARGV // usage(); usage() if@ARGV;
$repo=abs_path($repo)//die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp)//die "resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$renderer=File::Spec->catfile($vcs,qw(renderers enhanced_multisprite enhanced_multisprite.c26));
my$example=File::Spec->catfile($repo,qw(examples 18_enhanced_multisprite 01_192 01_interactive enhanced_multisprite_192_interactive.c26));
my$common=File::Spec->catdir($repo,qw(examples common));
my$text=read_file($renderer);
$text =~ /TEMPLATE_HARDWARE_LANES\s*:=\s*2/ or die "enhanced renderer lost two-lane contract\n";
$text =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*192/ or die "enhanced renderer lost 192-line contract\n";
$text =~ /TEMPLATE_PLAYER0_MAX_Y\s+89/ && $text =~ /TEMPLATE_PLAYER1_MAX_Y\s+89/ or die "enhanced legal Y range changed\n";
$text =~ /uint8_t\s+TEMPLATE_event_order\[7\]/ or die "bounded event-order scheduler missing\n";
$text =~ /event_order\[\]\s+is a compact descending list/ or die "event-order scheduler contract comment missing\n";
$text =~ /Stable-partition the priority list/ or die "fair persistent-priority rotation missing\n";

my$smoke=File::Spec->catfile($tmp,'enhanced_multisprite_smoke.bin');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$example,'-o',$smoke);
$rc==0 && !$sig or die "enhanced example build failed\n$out$err";
$out=without_usage($out); $out eq '' or die "enhanced example build stdout: $out";
$err eq '' or die "enhanced example build stderr: $err";
(-s $smoke) == 4096 or die "enhanced example is not a 4K ROM\n";

my$cxx=$ENV{CXX}||'c++';
my$mos=File::Spec->catdir($repo,qw(simulator mos6502));
my$mo=File::Spec->catfile($mos,'mos6502.o');
my@mi=-f$mo?($mo):(File::Spec->catfile($mos,'mos6502.cpp'));
my$timing=File::Spec->catfile($tmp,'enhanced_timing');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mi,'-o',$timing);
$rc==0 && !$sig or die "timing harness build failed\n$out$err";
$out eq '' && $err eq '' or die "timing harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($timing,$smoke,'100','--no-audio','--raw-lines','264');
$rc==0 && !$sig or die "static enhanced timing failed\n$out$err";
$out eq "vcs_frame_timing ok: 97 frames at 262 lines, 0 AUDV0 writes\n" or die "bad static enhanced timing: $out";
$err eq '' or die "static enhanced timing stderr: $err";

my$source_head=<<'C26';
include "vcs.c26"
include "frame_ntsc.c26"
include "color_ntsc.c26"
instantiate "renderers/enhanced_multisprite/enhanced_multisprite.c26" as game
include "multisprite_interactive_common.c26"

inline void initialize_enhanced_scene(void) {
   initialize_multisprite_scene();
   game_PLAYER0_Y := 76;
   game_PLAYER1_Y := 76;
   game_PLAYER2_Y := 76;
   game_PLAYER3_Y := 42;
   game_PLAYER4_Y := 42;
   game_PLAYER5_Y := 16;
}

void main(void) {
   SWACNT := 0;
   SWBCNT := 0;
   VBLANK := 2;
   initialize_enhanced_scene();
   while (1) {
      vcs_ntsc_vsync();
      vcs_ntsc_begin_vblank();
      game_vblank();
      vcs_ntsc_end_vblank();
      game_draw();
      vcs_ntsc_begin_overscan();
      game_overscan();
C26
my$move_y=<<'C26';
      game_PLAYER0_Y++; if (game_PLAYER0_Y > game_PLAYER0_MAX_Y) { game_PLAYER0_Y := 0; }
      game_PLAYER1_Y++; if (game_PLAYER1_Y > game_PLAYER1_MAX_Y) { game_PLAYER1_Y := 0; }
      game_PLAYER2_Y++; if (game_PLAYER2_Y > game_PLAYER1_MAX_Y) { game_PLAYER2_Y := 0; }
      game_PLAYER3_Y++; if (game_PLAYER3_Y > game_PLAYER1_MAX_Y) { game_PLAYER3_Y := 0; }
      game_PLAYER4_Y++; if (game_PLAYER4_Y > game_PLAYER1_MAX_Y) { game_PLAYER4_Y := 0; }
      game_PLAYER5_Y++; if (game_PLAYER5_Y > game_PLAYER1_MAX_Y) { game_PLAYER5_Y := 0; }
C26
my$move_x=<<'C26';
      game_PLAYER0_X++; if (game_PLAYER0_X > 159) { game_PLAYER0_X := 0; }
      game_PLAYER1_X++; if (game_PLAYER1_X > 159) { game_PLAYER1_X := 0; }
      game_PLAYER2_X++; if (game_PLAYER2_X > 159) { game_PLAYER2_X := 0; }
      game_PLAYER3_X++; if (game_PLAYER3_X > 159) { game_PLAYER3_X := 0; }
      game_PLAYER4_X++; if (game_PLAYER4_X > 159) { game_PLAYER4_X := 0; }
      game_PLAYER5_X++; if (game_PLAYER5_X > 159) { game_PLAYER5_X := 0; }
C26
my$source_tail=<<'C26';
      vcs_ntsc_end_overscan();
   }
}
C26

for my$kind (['y',$move_y],['xy',$move_y.$move_x]) {
   my($name,$motion)=@$kind;
   my$src=File::Spec->catfile($tmp,"enhanced_${name}_sweep.c26");
   my$bin=File::Spec->catfile($tmp,"enhanced_${name}_sweep.bin");
   write_file($src,$source_head.$motion.$source_tail);
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$common,$src,'-o',$bin);
   $rc==0 && !$sig or die "$name sweep build failed\n$out$err";
   $out=without_usage($out); $out eq '' or die "$name sweep build stdout: $out";
   $err eq '' or die "$name sweep build stderr: $err";
   ($rc,$sig,$out,$err)=capture($timing,$bin,'1000','--no-audio','--raw-lines','264');
   $rc==0 && !$sig or die "$name sweep timing failed\n$out$err";
   $out eq "vcs_frame_timing ok: 997 frames at 262 lines, 0 AUDV0 writes\n" or die "bad $name sweep timing: $out";
   $err eq '' or die "$name sweep timing stderr: $err";
}

my$arb=File::Spec->catfile($tmp,'enhanced_arbitration');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_enhanced_multisprite.cpp)),@mi,'-o',$arb);
$rc==0 && !$sig or die "arbitration harness build failed\n$out$err";
$out eq '' && $err eq '' or die "arbitration harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($arb,$smoke);
$rc==0 && !$sig or die "arbitration regression failed\n$out$err";
$out eq "vcs_enhanced_multisprite arbitration ok: both lanes active, 3-way fair 2-of-3 rotation, 2-way solid\n" or die "bad arbitration output: $out";
$err eq '' or die "arbitration stderr: $err";

print "vcs_enhanced_multisprite ok: 192-line symmetric P0/P1 multiplexer, 997-frame Y/XY timing sweeps, fair 3-way 2-of-3 rotation\n";
