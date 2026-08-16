#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_multisprite_profiles ok: parameterized 192/181 modern multisprite, exhaustive legal X/Y frame timing, persistent overlap flicker in all profiles, clipped P0 bottom edge, exact six-player/playfield and 123456 score rasters, page-safe glyph layout, hard branch-page timing contracts, compact score glyph state, RAM/ROM contracts, and interactive examples locked
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
sub read_file { my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>; close($fh); return defined($d)?$d:''; }
sub write_file { my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n"; print {$fh} $d; close($fh) or die "close $p: $!\n"; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve tmp\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $renderer=File::Spec->catfile($vcs,qw(renderers multisprite multisprite.c26));
my $text=read_file($renderer);
$text =~ /parameter\s+lines\s*;/ or die "multisprite lines parameter is missing\n";
$text =~ /#if\s+TEMPLATE_lines\s*==\s*192/ or die "multisprite 192 profile is missing\n";
$text =~ /#elif\s+TEMPLATE_lines\s*==\s*181/ or die "multisprite 181 profile is missing\n";
my $persistent_sort_contracts=()=$text =~ /alias\s+TEMPLATE_PERSISTENT_SORT_BYTES\s+3\b/g;
my $module_ram_contracts=()=$text =~ /alias\s+TEMPLATE_MODULE_RAM_BYTES_VALUE\s+72\b/g;
$persistent_sort_contracts==2 && $module_ram_contracts==2 &&
$text =~ /TEMPLATE_MODULE_RAM_BYTES\s*:=\s*TEMPLATE_MODULE_RAM_BYTES_VALUE/
   or die "multisprite profile RAM contract changed\n";
$text =~ /uint8_t\s+TEMPLATE_sprite_sort\[3\]/ &&
$text =~ /TEMPLATE_sprite_sort \+ 2/ &&
$text =~ /ora\s+TEMPLATE_state \+ 60/
   or die "persistent flicker-sort packed storage contract is missing\n";
$text =~ /TEMPLATE_DRAW_HMOVE_COUNT\s*:=\s*TEMPLATE_DRAW_HMOVE_COUNT_VALUE/ or die "multisprite HMOVE contract is missing\n";
$text =~ /asm\s+lax\s+\(TEMPLATE_state\s*\+\s*49\),y;/ or die "retained stable/common LAX path is missing\n";
$text =~ /asm\s+\.callstackextra\s+2;/ or die "multisprite hidden call-stack declaration changed\n";
my $borrow_propagations=()=$text =~ /asm\s+sbc\s+#0;/g;
$borrow_propagations >= 3 or die "multisprite no longer propagates full 16-bit graphics-pointer borrow\n";
$text =~ /extern\s+const\s+uint8_t\s+TEMPLATE_graphics\[145\]/ or die "page-safe graphics block contract is missing\n";
$text =~ /TEMPLATE_GRAPHICS_DATA_OFFSET\s*:=\s*96\b/ or die "graphics data offset contract changed\n";
$text =~ /TEMPLATE_PLAYER5_GRAPHICS_OFFSET\s+137\b/ or die "P5 graphics offset changed\n";
$text =~ /TEMPLATE_PLAYER0_MAX_Y\s+95\b/ && $text =~ /TEMPLATE_PLAYER1_MAX_Y\s+92\b/
   or die "192 legal Y bounds changed\n";
$text =~ /TEMPLATE_PLAYER0_MAX_Y\s+89\b/ && $text =~ /TEMPLATE_PLAYER1_MAX_Y\s+86\b/
   or die "181 legal Y bounds changed\n";
# Every conditional edge in draw() is part of the beam-cycle contract.  The
# faithful renderer and the repaired composable profiles require the ordinary
# three-cycle taken-branch case for every one of these edges; none requires a
# four-cycle page-crossing branch.  Keep the exact labels explicit so a future
# edit cannot add a bare timing-sensitive branch unnoticed.
$text =~ /require\s+inline\s+void\s+TEMPLATE_draw\s*\(void\)\s*\{(.*?)\n\}/s
   or die "multisprite draw body is missing\n";
my $draw=$1;
my @draw_same=qw(
   SwitchDrawP0K1 WaitDrawP0K1 SkipDrawP1K1 pagewraphandler
   RepoRenderer RendererLoopa RendererLoopb updateXKR SwitchDrawP0KR
   WaitDrawP0KR PackedPositionLoopK skipthis SwitchDrawP0KV WaitDrawP0KV
   SetNextLine nodec DrawDivideBy15Loop
);
for my $label (@draw_same) {
   $draw =~ /asm\s+b(?:cc|cs|eq|ne|mi|pl|vc|vs)\.same\s+\@TEMPLATE_\Q$label\E;/
      or die "beam-critical branch to $label lost its required .same contract\n";
}
$draw !~ /asm\s+b(?:cc|cs|eq|ne|mi|pl|vc|vs)\s+\@TEMPLATE_/
   or die "bare conditional branch remains in beam-critical multisprite draw path\n";
$draw !~ /asm\s+b(?:cc|cs|eq|ne|mi|pl|vc|vs)\.cross\s+\@TEMPLATE_/
   or die "multisprite draw path unexpectedly requires a .cross branch\n";
$text =~ /asm\s+bcs\.same\s+\@TEMPLATE_DivideBy15Loop;/
   or die "VBLANK divide-by-15 position loop lost its same-page timing contract\n";
$text =~ /asm\s+jsr\s+\@TEMPLATE_DrawPositionASpriteSubroutine;/
   or die "181 score handoff no longer uses the full-range two-line P0 positioner\n";
$text =~ /asm\s+sta\s+HMCLR;/
   or die "full-range positioner lost its 3-cycle HMCLR store\n";
$text =~ /TEMPLATE_player_position_table\[160\]/ && $text =~ /asm\s+inx;\s*asm\s+\@TEMPLATE_PackedPositionLoopK:/s
   or die "packed full-range P1 positioner contract changed\n";
$text =~ /asm\s+lda\s+#\$80;\s*asm\s+sta\s+HMP0;\s*asm\s+nop;/s
   or die "181 late-HMOVE neutral P0 motion contract changed\n";
$text !~ /TEMPLATE_PrecomputeTopP1ControlReady/ && $text !~ /asm\s+adc\s+#9;/
   or die "obsolete 181 top-rank X+9 coordinate compensation returned\n";
$text =~ /three CPU cycles earlier than every later post-WSYNC reposition.*?asm\s+nop;\s*asm\s+bit\.z\s+TEMPLATE_state\s*\+\s*66;/s
   or die "181 first-rank three-cycle entry-phase alignment is missing\n";

my $score_component=read_file(File::Spec->catfile($vcs,'six_glyph_component.c26'));
$score_component =~ /#if TEMPLATE_compact_font(.*?)#else/s
   or die "six-glyph component has no compact branch\n";
my $score_compact=$1;
$score_compact =~ /uint8_t\s+TEMPLATE_offsets\[2\]/ &&
$score_compact =~ /uint16_t\s+TEMPLATE_pointers\[4\]/ &&
$score_compact !~ /TEMPLATE_row/ &&
$score_component =~ /parameter\s+mutable_color\s*:=\s*0/
   or die "six-glyph mutable-color compact pointer/offset contract changed\n";

my @examples=(
   ['192',qw(examples 14_multisprite 01_192 01_interactive multisprite_192_interactive.c26),2622,84,78,6],
   ['181-score-above',qw(examples 14_multisprite 02_181_score_above 01_interactive multisprite_181_score_above_interactive.c26),3418,99,93,6],
   ['181-score-below',qw(examples 14_multisprite 03_181_score_below 01_interactive multisprite_181_score_below_interactive.c26),3418,99,93,6],
);
my %bins;
my %state_bases;
for my $e (@examples) {
   my($mode,@parts)=@$e;
   my($rom_expected,$ram_expected,$obj_expected,$stack_expected)=splice(@parts,-4);
   my $src=File::Spec->catfile($repo,@parts);
   my $bin=File::Spec->catfile($tmp,"multisprite_$mode.bin");
   my $map=File::Spec->catfile($tmp,"multisprite_$mode.map");
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Wa,--illegals','-Map',$map,$src,'-o',$bin);
   $rc==0 && !$sig or die "$mode public example build failed\n$out$err";
   $err eq '' or die "$mode public example wrote stderr\n$err";
   $out =~ /^  rom\s+used=(\d+) bytes/m && $1==$rom_expected
      or die "$mode ROM accounting changed\n$out";
   $out =~ /^  ram\s+used=(\d+) bytes .*objects=(\d+) bytes hardware-stack=(\d+) bytes/m &&
      $1==$ram_expected && $2==$obj_expected && $3==$stack_expected
      or die "$mode RAM accounting changed\n$out";
   without_usage($out) eq '' or die "$mode public example wrote unexpected stdout\n$out";
   -s $bin==4096 or die "$mode public example is not a 4K cartridge\n";
   my $maptext=read_file($map);
   $maptext =~ /BSS\.__vcsc_object\$game_state\s+run=\$([0-9A-Fa-f]{4})\s+size=\$0043\b/
      or die "$mode game_state is not exactly 67 bytes\n";
   $state_bases{$mode}="0x$1";
   $maptext =~ /BSS\.__vcsc_object\$game_sprite_sort\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0003\b/
      or die "$mode persistent flicker-sort storage is not exactly three bytes\n";
   $maptext =~ /\$[0-9A-Fa-f]{4}\s+_vcsc_ptr0\b/ && $maptext =~ /\$[0-9A-Fa-f]{4}\s+_vcsc_ptr1\b/
      or die "$mode stock startup did not retain exactly its required pointer pair\n";
   $maptext !~ /\$[0-9A-Fa-f]{4}\s+_vcsc_(?:ptr2|arg0|arg1)\b/
      or die "$mode stock startup pulled unnecessary generic runtime workspace\n";
   $maptext !~ /BSS\.__vcsc_activation\$main\b/
      or die "$mode main unexpectedly regained permanent activation storage\n";
   if ($mode ne '192') {
      $maptext =~ /BSS\.__vcsc_object\$score_offsets\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0002\b/
         or die "$mode score offset workspace is not exactly two bytes\n";
      $maptext =~ /BSS\.__vcsc_object\$score_pointers\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0008\b/
         or die "$mode score pointer workspace is not exactly eight bytes\n";
      $maptext !~ /BSS\.__vcsc_object\$score_row\b/
         or die "$mode score row counter unexpectedly returned\n";
   }
   $maptext =~ /RODATA\.__vcsc_object\$game_graphics\s+load=\$[0-9A-Fa-f]{2}00\s+size=\$0091\b[^\n]*component-align=\$0100\b/
      or die "$mode graphics block is not 145 bytes at a 256-byte boundary\n$maptext";
   $bins{$mode}=$bin;
}

# The public interactive proof must exercise both axes for every logical player.
my $common=read_file(File::Spec->catfile($repo,qw(examples common multisprite_interactive_common.c26)));
$common =~ /inline\s+void\s+move_selected_multisprite_object\s*\(void\)\s*\{(.*?)\n\}/s
   or die "multisprite interactive motion helper is missing\n";
my $motion=$1;
$motion =~ /PLAYER0_X/ && $motion =~ /PLAYER5_X/ or die "interactive example does not move all six sprites horizontally\n";
$motion =~ /PLAYER0_Y/ && $motion =~ /PLAYER5_Y/ or die "interactive example does not move all six sprites vertically\n";
$motion =~ /game_PLAYER0_MAX_Y/ && $motion =~ /game_PLAYER1_MAX_Y/
   or die "interactive vertical motion does not honor renderer Y bounds\n";
$motion =~ /SWCHA\s*&\s*0x10/ && $motion =~ /SWCHA\s*&\s*0x20/
   or die "interactive example does not handle joystick up/down\n";
my($up_motion,$down_motion)=$motion =~
   /(if\s*\(!\(SWCHA\s*&\s*0x10\)\).*?)(?=else\s*\{\s*if\s*\(!\(SWCHA\s*&\s*0x20\)\))(.+)/s;
$up_motion && $down_motion or die "interactive up/down control structure changed\n";
$up_motion =~ /game_PLAYER0_Y\+\+/ && $up_motion =~ /game_PLAYER5_Y\+\+/ && $up_motion !~ /game_PLAYER[0-5]_Y--/
   or die "joystick up must increment multisprite Y coordinates\n";
$down_motion =~ /game_PLAYER0_Y--/ && $down_motion =~ /game_PLAYER5_Y--/ && $down_motion !~ /game_PLAYER[0-5]_Y\+\+/
   or die "joystick down must decrement multisprite Y coordinates\n";
$common =~ /SELECTED_OBJECT_COUNT\s+6\b/ or die "interactive Select cycle is not six sprites\n";
$common =~ /game_MISSILE0_Y\s*:=\s*250/ && $common =~ /game_MISSILE1_Y\s*:=\s*251/ && $common =~ /game_BALL_Y\s*:=\s*252/
   or die "maintained minimal profile no longer keeps M0/M1/Ball off the active raster\n";

# Unsupported scanline counts must fail during instantiation rather than silently
# selecting one of the calibrated raster profiles.
my $bad=File::Spec->catfile($tmp,'multisprite_bad_lines.c26');
write_file($bad,qq{include "vcs.c26"\ninstantiate "renderers/multisprite/multisprite.c26" as game (lines:=180)\nvoid main(void) { while (1) {} }\n});
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Wa,--illegals',$bad,'-o',File::Spec->catfile($tmp,'bad.bin'));
$rc!=0 && !$sig or die "lines:=180 unexpectedly compiled\n";
$err =~ /TEMPLATE_lines_must_be_181_or_192/ or die "lines:=180 did not fail through the renderer profile guard\n$err";

# Build the MOS6502 raster oracle and the independent score pixel oracle.
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $raster=File::Spec->catfile($tmp,'vcs_multisprite_profiles');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_multisprite_profiles.cpp)),@mos_input,'-o',$raster);
$rc==0 && !$sig && $out eq '' && $err eq '' or die "multisprite raster harness build failed\n$out$err";
for my $mode (qw(192 181-score-above 181-score-below)) {
   ($rc,$sig,$out,$err)=capture($raster,$bins{$mode},$mode,$state_bases{$mode});
   $rc==0 && !$sig or die "$mode raster oracle failed\n$out$err";
   $out =~ /^vcs_multisprite_profiles \Q$mode\E ok:/ or die "unexpected $mode raster output: $out";
   $err eq '' or die "$mode raster stderr: $err";
}

# The public scene must honor the graphics placement contract directly. The
# alignment keeps all retained cycle-critical (ptr),Y fetches on one ROM page.
$common =~ /align\(256\)\s+const\s+uint8_t\s+game_graphics\[145\]/
   or die "interactive examples no longer provide a page-aligned graphics block\n";

# Lock the user-visible score digits, not merely score activity. This catches
# renderer/score handoff timing corruption such as a bottom score changing from
# 123456 even when all six score pointers themselves remain intact.
my $score_raster=File::Spec->catfile($tmp,'vcs_multisprite_score_raster');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_six_glyph_raster.cpp)),@mos_input,'-o',$score_raster);
$rc==0 && !$sig && $out eq '' && $err eq '' or die "multisprite score raster harness build failed\n$out$err";
for my $case (['181-score-above',40],['181-score-below',221]) {
   my($mode,$entry)=@$case;
   ($rc,$sig,$out,$err)=capture($score_raster,$bins{$mode},$entry,'123456');
   $rc==0 && !$sig or die "$mode exact 123456 score raster failed\n$out$err";
   $out =~ /^vcs_six_glyph_raster ok: 1 exact 48x8 score rasters/
      or die "unexpected $mode score raster output: $out";
   $err eq '' or die "$mode score raster stderr: $err";
}

print "vcs_multisprite_profiles ok: parameterized 192/181 modern multisprite, exhaustive legal X/Y frame timing, persistent overlap flicker in all profiles, clipped P0 bottom edge, exact six-player/playfield and 123456 score rasters, page-safe glyph layout, hard branch-page timing contracts, compact score glyph state, RAM/ROM contracts, and interactive examples locked\n";
