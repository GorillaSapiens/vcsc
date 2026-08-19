#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_enhanced_multisprite ok: 192-line symmetric P0/P1 multiplexer, randomized timing stress, fair 3-6-way arbitration
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
use Digest::SHA qw(sha256_hex);

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
$text =~ /Promoting only the last omission/ or die "fair persistent-priority rotation missing\n";
my($position_body)=$text =~ /TEMPLATE_position_table\[160\]\s*:=\s*\{(.*?)\};/s;
defined($position_body) or die "enhanced packed position table missing\n";
my@position=map { hex($_) } ($position_body =~ /0x([0-9a-fA-F]{2})/g);
@position==160 or die "enhanced packed position table is not 160 bytes\n";
sha256_hex(pack('C*',@position)) eq 'd550adb50aee0badf340a4dba0f6a66c4956afd41046408529813f8ba56db324'
   or die "enhanced packed position calibration changed; rerun Stella pixel calibration before accepting new bytes\n";
$text =~ /sta RESP0;\s*asm sta WSYNC;\s*asm \@TEMPLATE_Setup0LineB:;\s*asm sta HMOVE;/s
   or die "P0 setup lost immediate line-B HMOVE phase\n";
$text =~ /sta RESP1;\s*asm sta WSYNC;\s*asm \@TEMPLATE_Setup1LineB:;\s*asm sta HMOVE;/s
   or die "P1 setup lost immediate line-B HMOVE phase\n";
$text =~ /ChooseBelowOtherP1:.*?cmp #12;.*?ChooseAboveOtherP1:.*?cmp #12;/s
   or die "P1 same-lane attribute/setup exclusion window changed\n";
$text =~ /Below an existing P0.*?cmp #15;.*?Existing P0:.*?cmp #15;/s
   or die "P0 same-lane attribute/setup exclusion window changed\n";
$text =~ /ldy\.z TEMPLATE_current_gfx \+ 1;.*?ldx\.z TEMPLATE_position_packed;.*?sta WSYNC;.*?sty GRP1;.*?txa;.*?sta HMP0;/s
   or die "P0 setup no longer publishes the continuing P1 row at the calibrated phase\n";
$text =~ /ldy\.z TEMPLATE_current_gfx;.*?ldx\.z TEMPLATE_position_packed;.*?sta WSYNC;.*?sty GRP0;.*?txa;.*?sta HMP1;/s
   or die "P1 setup no longer publishes the continuing P0 row at the calibrated phase\n";

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

# Hammer all six Y values independently at each synchronized frame boundary.
# The original regression moved the whole formation together and therefore
# missed vertical permutations that made the VBLANK event scheduler overrun.
(my$sym=$smoke) =~ s/\.bin\z/.sym/;
my$sym_text=read_file($sym);
my($y_hex)=$sym_text =~ /^game_y\s+([0-9a-fA-F]{4})\s*$/m;
defined($y_hex) or die "could not locate game_y in enhanced symbol file\n";
my$y_addr=hex($y_hex);
$y_addr <= 0xff or die "enhanced game_y left zero page\n";
for my$seed (qw(0x6d2b79f5 0x1234567b 0xa5c39e17)) {
   ($rc,$sig,$out,$err)=capture($timing,$smoke,'5000','--no-audio','--raw-lines','264',
      '--randomize-zp',sprintf('0x%02x',$y_addr),'6','90',$seed);
   $rc==0 && !$sig or die "random Y stress $seed failed\n$out$err";
   $out eq "vcs_frame_timing ok: 4997 frames at 262 lines, 0 AUDV0 writes\n"
      or die "bad random Y stress $seed timing: $out";
   $err eq '' or die "random Y stress $seed stderr: $err";
}

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

# The interactive example moves one selected sprite while the other five stay
# put.  Moving the entire formation together misses conflict/order transitions,
# so exercise every logical sprite independently in both Y directions.
for my$i (0..5) {
   for my$dir (qw(up down)) {
      my$player="game_PLAYER${i}_Y";
      my$motion = $dir eq 'up'
         ? "      $player++; if ($player > 89) { $player := 0; }\n"
         : "      if ($player == 0) { $player := 89; } else { $player--; }\n";
      my$name="single_${i}_${dir}";
      my$src=File::Spec->catfile($tmp,"enhanced_${name}_sweep.c26");
      my$bin=File::Spec->catfile($tmp,"enhanced_${name}_sweep.bin");
      write_file($src,$source_head.$motion.$source_tail);
      ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$common,$src,'-o',$bin);
      $rc==0 && !$sig or die "$name sweep build failed\n$out$err";
      $out=without_usage($out); $out eq '' or die "$name sweep build stdout: $out";
      $err eq '' or die "$name sweep build stderr: $err";
      ($rc,$sig,$out,$err)=capture($timing,$bin,'1000','--no-audio','--raw-lines','264');
      $rc==0 && !$sig or die "$name sweep timing failed\n$out$err";
      $out eq "vcs_frame_timing ok: 997 frames at 262 lines, 0 AUDV0 writes\n"
         or die "bad $name sweep timing: $out";
      $err eq '' or die "$name sweep timing stderr: $err";
   }
}

my$arb=File::Spec->catfile($tmp,'enhanced_arbitration');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,File::Spec->catfile($repo,qw(test vcs_enhanced_multisprite.cpp)),@mi,'-o',$arb);
$rc==0 && !$sig or die "arbitration harness build failed\n$out$err";
$out eq '' && $err eq '' or die "arbitration harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($arb,$smoke,'3');
$rc==0 && !$sig or die "3-way arbitration regression failed\n$out$err";
$out eq "vcs_enhanced_multisprite arbitration ok: 3-way pile fair 2-of-3 rotation, both lanes active\n" or die "bad 3-way arbitration output: $out";
$err eq '' or die "3-way arbitration stderr: $err";

for my$n (4..6) {
   my@ys=(76,76,76,76,42,16);
   $ys[4]=76 if$n>=5;
   $ys[5]=76 if$n>=6;
   my$init=join('',map { "   game_PLAYER${_}_Y := $ys[$_];\n" } 0..5);
   my$src_text=<<"C26";
include "vcs.c26"
include "frame_ntsc.c26"
include "color_ntsc.c26"
instantiate "renderers/enhanced_multisprite/enhanced_multisprite.c26" as game
include "multisprite_interactive_common.c26"
void main(void) {
   SWACNT := 0; SWBCNT := 0; VBLANK := 2;
   initialize_multisprite_scene();
$init   while (1) {
      vcs_ntsc_vsync(); vcs_ntsc_begin_vblank(); game_vblank(); vcs_ntsc_end_vblank();
      game_draw(); vcs_ntsc_begin_overscan(); game_overscan(); vcs_ntsc_end_overscan();
   }
}
C26
   my$src=File::Spec->catfile($tmp,"enhanced_pile_${n}.c26");
   my$bin=File::Spec->catfile($tmp,"enhanced_pile_${n}.bin");
   write_file($src,$src_text);
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$common,$src,'-o',$bin);
   $rc==0 && !$sig or die "$n-way pile build failed\n$out$err";
   $out=without_usage($out); $out eq '' or die "$n-way pile build stdout: $out";
   $err eq '' or die "$n-way pile build stderr: $err";
   ($rc,$sig,$out,$err)=capture($arb,$bin,"$n");
   $rc==0 && !$sig or die "$n-way arbitration regression failed\n$out$err";
   $out eq "vcs_enhanced_multisprite arbitration ok: $n-way pile fair 2-of-$n rotation, both lanes active\n"
      or die "bad $n-way arbitration output: $out";
   $err eq '' or die "$n-way arbitration stderr: $err";
}

print "vcs_enhanced_multisprite ok: 192-line symmetric P0/P1 multiplexer, randomized timing stress, fair 3-6-way arbitration\n";
