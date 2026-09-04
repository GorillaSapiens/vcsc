#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_enhanced_multisprite_asymmetric ok: stable full-PF 192-line raster, held-layout dense-X stress, 12-phase edge coverage, continuous X sweep, combined X/Y stress
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
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my$repo=shift@ARGV // usage(); my$tmp=shift@ARGV // usage(); usage() if@ARGV;
$repo=abs_path($repo)//die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp)//die "resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$renderer=File::Spec->catfile($vcs,qw(renderers enhanced_multisprite_asymmetric enhanced_multisprite.c26));
my$example_dir=File::Spec->catdir($repo,qw(examples 18_enhanced_multisprite 01_192 01_asymmetric));
my$example=File::Spec->catfile($example_dir,'enhanced_multisprite_192_asymmetric.c26');
my$startup=File::Spec->catfile($example_dir,'enhanced_multisprite_192_asymmetric_startup.s26');
my$text=read_file($renderer);

$text =~ /TEMPLATE_HARDWARE_LANES\s*:=\s*2/ or die "asymmetric renderer lost two-lane contract\n";
$text =~ /parameter lines;/ or die "asymmetric renderer lost lines parameter\n";
$text =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_lines/ or die "asymmetric renderer lost parameterized visible-line contract\n";
$text =~ /TEMPLATE_lines == 228.*?TEMPLATE_LOGICAL_BAND_COUNT 114.*?TEMPLATE_LOGICAL_HEIGHT 113/s
   or die "asymmetric renderer lost native 228-line geometry\n";
$text =~ /asm \.def TEMPLATE_PF0_LEFT TEMPLATE_playfield_left_pf0;/ &&
$text =~ /asm \.def TEMPLATE_PF0_RIGHT TEMPLATE_playfield_right_pf0;/
   or die "PF0 aliases no longer preserve relocatable table symbols\n";
$text !~ /TEMPLATE_playfield_(?:left|right)\s*\+\s*97\b/
   or die "hard-coded 192-only +97 playfield-plane offset returned\n";
$text =~ /TEMPLATE_P0RespSlot5:;.*?asm bit\.a TEMPLATE_event_stage;/s
   or die "P0 slot-5 calibrated four-cycle delay missing\n";
$text =~ /TEMPLATE_P0RespSlot8:;.*?asm bit\.z TEMPLATE_event_stage;/s
   or die "P0 slot-8 calibrated three-cycle delay missing\n";
$text =~ /TEMPLATE_P1RespSlot5:;.*?asm bit\.a TEMPLATE_event_stage;/s
   or die "P1 slot-5 calibrated four-cycle delay missing\n";
$text =~ /TEMPLATE_P1RespSlot8:;.*?asm bit\.z TEMPLATE_event_stage;/s
   or die "P1 slot-8 calibrated three-cycle delay missing\n";
$text !~ /sta\.a RESP[01]/ or die "late RESP slots regressed to exact-boundary absolute TIA stores\n";
$text =~ /TEMPLATE_Position0Boundary:;.*?asm sta WSYNC;\s*asm jmp TEMPLATE_Position0LineA;/s
   or die "P0 top-edge entry no longer matches ordinary position phase\n";
$text =~ /TEMPLATE_Position1Boundary:;.*?asm sta WSYNC;\s*asm jmp TEMPLATE_Position1LineA;/s
   or die "P1 top-edge entry no longer matches ordinary position phase\n";
$text =~ /bmi\.(?:same|cross) \@TEMPLATE_PostSetupBottom;/
   or die "bottom-edge X-underflow termination guard missing\n";
$text =~ /TEMPLATE_PostSetup0Immediate:/
   or die "immediate opposite-lane event handoff missing\n";
$text =~ /\@TEMPLATE_PreloadTopLoop:;.*?asm cmp #TEMPLATE_LOGICAL_HEIGHT;.*?asm bcc\.same \@TEMPLATE_PreloadTopDone;/s
   or die "top-band setup is no longer parameterized/preloaded during VBLANK\n";
$text !~ /TEMPLATE_TopTrigger/
   or die "obsolete visible action_y=95 trigger path returned\n";
$text =~ /TEMPLATE_ChooseLane:;.*?ldy\.z TEMPLATE_setup_index;.*?ldx\.z TEMPLATE_priority \+ 1;.*?lda\.zx TEMPLATE_y,X;.*?sbc\.z TEMPLATE_pair_y;.*?cmp #7;.*?bcc\.same \@TEMPLATE_ChooseFirstP1/s
   or die "first-candidate scheduler lookahead missing\n";
$text =~ /\@TEMPLATE_ChooseCandidateAtOrAbove:;\s*(?:\/\/[^\n]*\n\s*)*asm lda\.z TEMPLATE_pending0_valid;/s
   or die "close-above scheduler delta is clobbered before lane test\n";
# Same-X reuse is a measured 13-band scheduler invariant, separate from the
# ordinary P0=15/P1=12 full-position reservations.  P0 may use retained-X only
# at 13..14; P1's exact-12 ordinary reuse must reject identical X in both scan
# directions while preserving exact-12 reuse for differing X coordinates.
$text =~ /\@TEMPLATE_ChooseBelowClose:;.*?asm lda\.z TEMPLATE_pending0_valid;.*?asm bne\.same \@TEMPLATE_ChooseBelowOtherP1;.*?asm txa;\s*asm cmp #13;\s*asm bcc\.same \@TEMPLATE_ChooseBelowP0Conflict;.*?asm cmp\.zx TEMPLATE_x,X;\s*asm bne\.same \@TEMPLATE_ChooseBelowP0Conflict;\s*asm jsr TEMPLATE_ProveP0Retain;/s
   or die "same-X delta-13 P0 retain threshold regressed\n";
$text =~ /\@TEMPLATE_ChooseBelowOtherP1:;.*?asm txa;\s*asm cmp #13;\s*asm bcs\.same \@TEMPLATE_ChooseBelowP1SameClear;\s*asm cmp #12;\s*asm bcc\.same \@TEMPLATE_ChooseBelowP1Conflict;.*?asm cmp\.zx TEMPLATE_x,X;\s*asm bne\.same \@TEMPLATE_ChooseBelowP1SameClear;\s*asm \@TEMPLATE_ChooseBelowP1Conflict:/s
   or die "same-X exact-12 below-P1 rejection regressed\n";
$text =~ /\@TEMPLATE_ChooseAboveOtherP1:;.*?asm txa;\s*asm cmp #13;\s*asm bcs\.same \@TEMPLATE_ChooseAfterOther;\s*asm cmp #12;\s*asm bcc\.same \@TEMPLATE_ChooseAboveP1Conflict;.*?asm cmp\.zx TEMPLATE_x,X;\s*asm bne\.same \@TEMPLATE_ChooseAfterOther;\s*asm \@TEMPLATE_ChooseAboveP1Conflict:/s
   or die "same-X exact-12 above-P1 rejection regressed\n";
# Ordinary P1-above-P0 gaps 1..6 are unsafe.  Retained-X P0 continuation
# deliberately makes the exact six-band case safe by moving the P0 action one
# band later, so pin both the 1..5 rejection and the narrowly qualified +6
# exception rather than requiring the pre-retained blanket cmp #7 shape.
$text =~ /TEMPLATE_ChooseBelowOtherP1:;.*?asm cmp #7;\s*asm bcs\.same \@TEMPLATE_ChooseAfterOther;.*?asm cmp #6;\s*asm bne\.same \@TEMPLATE_ChooseBelowP1P0Conflict;.*?asm jsr TEMPLATE_exact_six_p0;\s*asm bmi\.same \@TEMPLATE_ChooseAfterOther;/s
   or die "below-P1 six-band hazard/retained-P0 exception contract regressed\n";
$text =~ /void TEMPLATE_exact_six_p0\(void\) \{.*?asm lda\.z TEMPLATE_position_packed;\s*asm bmi\.same \@TEMPLATE_ExactSixP0Done;\s*asm lsr;\s*asm ror;\s*asm sta\.z TEMPLATE_position_packed;\s*asm \@TEMPLATE_ExactSixP0Done:;/s
   or die "below-P1 exact-six deferred retained-P0 proof regressed\n";
$text =~ /TEMPLATE_ProveP0Retain:;.*?asm bmi\.same \@TEMPLATE_ProveP0Marker;.*?asm \@TEMPLATE_ProveP0Marker:;\s*asm ora #1;\s*asm bne\.same \@TEMPLATE_ProveP0Store;/s
   or die "deferred exact-six marker no longer resolves on retained-P0 proof\n";
$text =~ /\@TEMPLATE_ChooseCandidateAtOrAbove:;.*?asm beq\.same \@TEMPLATE_ChooseAfterOther;\s*asm cmp #7;\s*asm bcs\.same \@TEMPLATE_ChooseAfterOther;.*?asm cmp #6;\s*asm bne\.same \@TEMPLATE_ChooseAboveP0P1Conflict;.*?asm and TEMPLATE_draw_code \+ 6;\s*asm bne\.same \@TEMPLATE_ChooseAfterOther;/s
   or die "above-P0 six-band hazard/retained-P0 exception contract regressed\n";

# Recovered visual-fix contracts.  These are deliberately structural: the
# timing harness below proves the resulting cycle balance while these checks
# prevent the exact color/stale-GRP/PF regressions from being silently restored.
$text =~ /TEMPLATE_PostSetup0LineA:;.*?lda\.ay TEMPLATE_lane_for,Y;\s*asm sta\.z TEMPLATE_pair_y;.*?asm adc #5;/s
   or die "P0 post-setup per-event color refresh missing\n";
$text =~ /TEMPLATE_Setup1LineB:;.*?asm iny;.*?asm sta\.a TEMPLATE_gfx_index \+ 1;.*?asm sta PF1;\s*.*?asm sty\.z TEMPLATE_setup_index;.*?lda\.ay TEMPLATE_lane_for,Y;\s*asm sta\.z TEMPLATE_pair_y;/s
   or die "P1 setup per-event color refresh/timing balance missing\n";
$text =~ /TEMPLATE_PostSetupLineA:;\s*.*?asm lda\.z TEMPLATE_current_gfx;\s*asm sta GRP0;/s
   or die "P1 post-setup stale-GRP suppression missing\n";
$text =~ /TEMPLATE_PostSetupLineBBody:;.*?asm sta PF2;\s*.*?asm ldy\.z TEMPLATE_gfx_index \+ 1;\s*asm lda\.ax TEMPLATE_PF0_RIGHT,X;\s*asm sta PF0;\s*asm lda\.ax TEMPLATE_playfield_right \+ TEMPLATE_PLAYFIELD_HALF,X;\s*asm sta PF1;\s*asm lda\.ay TEMPLATE_graphics_next,Y;/s
   or die "P0 post-setup PF seam timing redistribution missing\n";
$text =~ /TEMPLATE_P0RespSlot11:;.*?lda\.ax TEMPLATE_playfield_left,X;\s*asm sta PF1;\s*asm jmp TEMPLATE_P0RespAfterLeftPF1;/s
   or die "P0 phase-63 early left-PF1 correction missing\n";
$text =~ /TEMPLATE_P1RespSlot11:;.*?lda\.ax TEMPLATE_playfield_left,X;\s*asm sta PF1;\s*asm jmp TEMPLATE_P1RespAfterLeftPF1;/s
   or die "P1 phase-63 early left-PF1 correction missing\n";
$text =~ /TEMPLATE_P0RespAfterLeftPF1:;.*?lda\.ax TEMPLATE_playfield_right,X;\s*asm dex;\s*asm nop;\s*asm sta PF2;\s*asm sta RESP0;/s
   or die "P0 late-family right-PF2 correction missing\n";
$text =~ /TEMPLATE_P1RespAfterLeftPF1:;.*?lda\.ax TEMPLATE_playfield_right,X;\s*asm dex;\s*asm nop;\s*asm sta PF2;\s*asm sta RESP1;/s
   or die "P1 late-family right-PF2 correction missing\n";

my$bin=File::Spec->catfile($tmp,'enhanced_asymmetric.bin');
my($rc,$sig,$out,$err)=capture($driver,'-nostdlib','-I',$vcs,'-DVCS_NTSC_EXTENDED_VBLANK','-DMULTISPRITE_NO_RETAINED_PF_ROWS',$example,$startup,'-o',$bin);
$rc==0 && !$sig or die "asymmetric example build failed\n$out$err";
$out=without_usage($out); $out eq '' or die "asymmetric example build stdout: $out";
$err eq '' or die "asymmetric example build stderr: $err";
(-s $bin)==4096 or die "asymmetric example is not a 4K ROM\n";

# The public diagnostic is deliberately back on an ordinary unbanked 4K
# cartridge.  This removes every visible-time bankswitch hazard and proves the
# enhanced renderer itself does not require F8SC or Superchip RAM.
(my$map=$bin) =~ s/\.bin\z/.map/;
my$map_text=read_file($map);
$map_text =~ /output-size=\$00001000/
   or die "asymmetric example lost 4K cartridge topology\n";
$map_text =~ /CODE\.__vcsc_function\$game_draw\s+load=\$[0-9A-Fa-f]+/m
   or die "asymmetric game_draw is not in unbanked ROM\n";
$map_text =~ /CODE\.__vcsc_function\$run_asymmetric_frame\s+load=\$[0-9A-Fa-f]+/m
   or die "asymmetric frame driver is not in unbanked ROM\n";

(my$sym=$bin) =~ s/\.bin\z/.sym/;
my$sym_text=read_file($sym);
my($pf0_left_hex)=$sym_text =~ /^game_playfield_left_pf0\s+([0-9a-fA-F]{4})\s*$/m;
my($pf0_right_hex)=$sym_text =~ /^game_playfield_right_pf0\s+([0-9a-fA-F]{4})\s*$/m;
defined($pf0_left_hex) && defined($pf0_right_hex)
   or die "could not locate linked asymmetric PF0 tables\n";
my$linked_image=read_file($bin);
sub absx_operand_count {
   my($image,$addr)=@_;
   my$needle=pack('C3',0xbd,$addr&0xff,($addr>>8)&0xff);
   my$count=0; my$at=-1;
   while(1){ $at=index($image,$needle,$at+1); last if$at<0; ++$count; }
   return$count;
}
my$pf0_left_addr=hex($pf0_left_hex); my$pf0_right_addr=hex($pf0_right_hex);
absx_operand_count($linked_image,$pf0_left_addr)>=10 &&
absx_operand_count($linked_image,$pf0_left_addr+1)>=2 &&
absx_operand_count($linked_image,$pf0_right_addr)>=20 &&
absx_operand_count($linked_image,$pf0_right_addr+1)>=2
   or die sprintf("linked PF0 indexed operands do not target ROM tables left=%04x right=%04x\n",$pf0_left_addr,$pf0_right_addr);
absx_operand_count($linked_image,0)==0
   or die "linked PF0 relocation regressed to LDA \$0000,X\n";
my($x_hex)=$sym_text =~ /^game_x\s+([0-9a-fA-F]{4})\s*$/m;
my($y_hex)=$sym_text =~ /^game_y\s+([0-9a-fA-F]{4})\s*$/m;
my($color_hex)=$sym_text =~ /^game_color\s+([0-9a-fA-F]{4})\s*$/m;
my($priority_hex)=$sym_text =~ /^game_priority\s+([0-9a-fA-F]{4})\s*$/m;
my($graphics_hex)=$sym_text =~ /^game_graphics\s+([0-9a-fA-F]{4})\s*$/m;
my($draw_hex)=$sym_text =~ /^game_draw_code\s+([0-9a-fA-F]{4})\s*$/m;
my($count_hex)=$sym_text =~ /^game_setup_count\s+([0-9a-fA-F]{4})\s*$/m;
defined($x_hex) && defined($y_hex) && defined($color_hex) &&
   defined($priority_hex) && defined($graphics_hex) && defined($draw_hex) && defined($count_hex)
   or die "could not locate asymmetric scheduler/visibility symbols\n";
my$x_addr=hex($x_hex); my$y_addr=hex($y_hex); my$color_addr=hex($color_hex);
my$priority_addr=hex($priority_hex); my$graphics_addr=hex($graphics_hex); my$draw_addr=hex($draw_hex);
my$count_addr=hex($count_hex);
$x_addr<=0xff && $y_addr<=0xff && $color_addr<=0xff &&
   $priority_addr<=0xff && $draw_addr<=0xff && $count_addr<=0xff
   or die "asymmetric scheduler state left zero page\n";
$y_addr==$x_addr+6 or die "asymmetric X/Y array layout changed\n";

# Run the independent host copy of the lane allocator before the CPU timing
# sweeps.  It exists specifically to catch greedy-allocation failures that a
# stable 262-line frame cannot reveal (including the historical one-sprite
# frame).
my$cc=$ENV{CC}||'cc';
my$scheduler_model=File::Spec->catfile($tmp,'asymmetric_scheduler_model');
($rc,$sig,$out,$err)=capture($cc,'-std=c99','-O2','-Wall','-Wextra','-Werror',
   File::Spec->catfile($repo,qw(test vcs_enhanced_multisprite_asymmetric_scheduler.c)),
   '-o',$scheduler_model);
$rc==0 && !$sig or die "scheduler model build failed\n$out$err";
$out eq '' && $err eq '' or die "scheduler model build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($scheduler_model,'250000','0x31415927');
$rc==0 && !$sig or die "scheduler Monte Carlo failed\n$out$err";
$out =~ /asymmetric scheduler monte carlo ok: 250000 layouts, min=2, worst-gap=2, hist=1:0,/
   or die "bad scheduler Monte Carlo output: $out";
$err eq '' or die "scheduler Monte Carlo stderr: $err";

my$cxx=$ENV{CXX}||'c++';
my$mos=File::Spec->catdir($repo,qw(simulator mos6502));
my$mo=File::Spec->catfile($mos,'mos6502.o');
my@mi=-f$mo?($mo):(File::Spec->catfile($mos,'mos6502.cpp'));
my$timing=File::Spec->catfile($tmp,'asymmetric_timing');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mi,'-o',$timing);
$rc==0 && !$sig or die "timing harness build failed\n$out$err";
$out eq '' && $err eq '' or die "timing harness build wrote output\n$out$err";

sub expect_timing {
   my($name,$assertions,@args)=@_;
   my($r,$s,$o,$e)=capture($timing,$bin,$assertions,'--no-audio','--raw-lines','264',@args);
   $r==0 && !$s or die "$name failed\n$o$e";
   my$checked=$assertions-3;
   $o eq "vcs_frame_timing ok: $checked frames at 262 lines, 1 AUDV0 writes\n"
      or die "bad $name output: $o";
   $e eq '' or die "$name stderr: $e";
}

expect_timing('static asymmetric timing',100);

# 6502/raster witness for the scheduler/model divergence that could mark five
# sprites accepted while only one actually reached a nonzero GRP write.  The
# historical allocator's close-above path clobbered dy with the prior lane and
# also admitted an unsupported six-band P1->P0 handoff; this exact state lost
# sprite 5 (among others) despite draw_code claiming it was scheduled.
expect_timing('scheduled sprite visibility witness',100,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$x_addr+0),'143',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'82',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'135',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'107',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'49',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'159',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'9',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'18',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'67',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'73',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'60',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'23',
   '--set-zp',sprintf('0x%02x',$priority_addr+0),'5',
   '--set-zp',sprintf('0x%02x',$priority_addr+1),'1',
   '--set-zp',sprintf('0x%02x',$priority_addr+2),'2',
   '--set-zp',sprintf('0x%02x',$priority_addr+3),'0',
   '--set-zp',sprintf('0x%02x',$priority_addr+4),'3',
   '--set-zp',sprintf('0x%02x',$priority_addr+5),'4',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr));

# Screenshot-family witness: sprite 0 moved near the bottom while 1/2 and 3/4
# retain the diagnostic's paired Y positions and sprite 5 remains at Y=16.
# This geometry is fully drawable with the corrected scheduler; every logical
# sprite must actually appear, not merely rotate through an internal schedule.
expect_timing('all-six persistent visibility witness',100,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$x_addr+0),'18',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'36',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'88',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'114',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'140',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'12',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'76',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'76',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'16',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr),
   '--require-visible-mask','0x3f',
   '--expect-memory',sprintf('0x%02x',$count_addr),'6');

# Staggered same-X fallback regression.  Sprites 0 and 2 share X and are
# vertically disjoint while sprite 1 overlaps each separately.  Although the
# bitmap occupancy is only two, reusing P0 inside its 8..14-band setup exclusion
# window requires a fragile live-glyph/color handoff.  Prefer a rare, fair
# omission instead: every scheduled sprite must render all eight exact glyph
# rows and the persistent priority rotation must give 0/1/2 equal exposure.
expect_timing('staggered same-X fair-flicker witness',100,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$x_addr+0),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'72',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'88',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'114',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'140',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'86',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'82',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'76',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'16',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr),
   '--require-visible-mask','0x3f',
   '--require-visible-spread','0x07','1',
   '--verify-asymmetric-glyphs',sprintf('0x%04x',$graphics_addr),'0x05',
   '--expect-memory',sprintf('0x%02x',$count_addr),'5');

# Exact boundary reported by the user: same-X sprites eight bands apart.
# Sprite 1 overlaps both endpoints, so forcing 0+2 onto retained P0 used to
# expose the live handoff defect.  The scheduler should instead rotate the
# single omission fairly while every accepted endpoint emits a complete glyph.
expect_timing('same-X delta-8 fair-flicker boundary',100,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$x_addr+0),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'72',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'88',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'114',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'140',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'84',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'80',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'76',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'16',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr),
   '--require-visible-mask','0x3f',
   '--require-visible-spread','0x07','1',
   '--verify-asymmetric-glyphs',sprintf('0x%04x',$graphics_addr),'0x05',
   '--expect-memory',sprintf('0x%02x',$count_addr),'5');

# Measured same-X threshold boundary.  At delta 12 the scheduler must not reuse
# the same hardware player; this six-sprite column can still render continuously
# by alternating P0/P1.  The historical same-X reuse path corrupts this witness.
expect_timing('same-X delta-12 no-reuse boundary',100,
   '--released-inputs',
   (map { ('--set-zp',sprintf('0x%02x',$x_addr+$_),'62') } 0..5),
   '--set-zp',sprintf('0x%02x',$y_addr+0),'90',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'78',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'66',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'54',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'30',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr),
   '--require-visible-mask','0x3f',
   '--verify-asymmetric-glyphs',sprintf('0x%04x',$graphics_addr),'0x3f',
   '--expect-memory',sprintf('0x%02x',$count_addr),'6');

# At the threshold itself same-player reuse is allowed again.  Repeated delta-13
# reuse down one column must preserve all six complete eight-byte glyph streams.
expect_timing('same-X delta-13 reuse boundary',100,
   '--released-inputs',
   (map { ('--set-zp',sprintf('0x%02x',$x_addr+$_),'62') } 0..5),
   '--set-zp',sprintf('0x%02x',$y_addr+0),'90',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'77',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'64',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'51',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'38',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'25',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr),
   '--require-visible-mask','0x3f',
   '--verify-asymmetric-glyphs',sprintf('0x%04x',$graphics_addr),'0x3f',
   '--expect-memory',sprintf('0x%02x',$count_addr),'6');

# Historical equal-X delta-12 bridge.  The old bridge oracle forced endpoints
# 2/4 onto P1 so all six could be scheduled, but real-raster threshold testing
# showed same-X reuse below 13 is not generally safe.  Accept one omission here
# and require persistent priority to rotate it fairly among 2/3/4; every accepted
# endpoint must still emit its complete glyph.
expect_timing('same-X delta-12 bridge fair-flicker',100,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$x_addr+0),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'72',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'140',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'95',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'95',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'71',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'64',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'59',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'12',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr),
   '--require-visible-mask','0x3f',
   '--require-visible-spread','0x1c','1',
   '--verify-asymmetric-glyphs',sprintf('0x%04x',$graphics_addr),'0x1c',
   '--expect-memory',sprintf('0x%02x',$count_addr),'5');

# Two independent three-way same-Y piles require two omissions per frame.  The
# historical policy promoted only the *last* omission, which heavily favored
# two members of each pile over the third.  The renderer now stable-partitions
# every omitted sprite ahead of every shown sprite in overscan.  Over 97 checked
# frames all six logical sprites must therefore receive service within one frame
# of each other; count actual GRP visibility, not just scheduler records.
expect_timing('two-pile persistent fairness',100,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'76',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'76',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'76',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'42',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'42',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr),
   '--require-visible-spread','0x3f','1');

# Top-edge lane-consistency witness for the phosphor-visible vertical jitter.
# Three same-Y sprites force fair priority rotation to move each logical sprite
# between P0 and P1 on successive displayed frames.  Y=90 is deliberately in
# the historical P0-only preload range (89..91): before the extra predecessor
# state fix, P0 began two physical scanlines above P1 and the same glyph visibly
# hopped up/down as its lane assignment rotated.
expect_timing('top-edge lane vertical stability',100,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$x_addr+0),'34',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'46',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'70',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'90',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'90',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'90',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'55',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'35',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'15',
   '--verify-asymmetric-visibility',
      sprintf('0x%02x',$y_addr),sprintf('0x%02x',$color_addr),
      sprintf('0x%02x',$draw_addr),sprintf('0x%02x',$count_addr),
   '--require-stable-first-visible-line','0x07');

# Persistent top-left dual-preload deadline witness from the interactive
# example.  With the old 51/25 extended split this scene can begin near the
# nominal frame length, then fairness changes priority and the VBLANK scheduler
# settles into an expensive ordering: its first deadline poll occurs after the
# 51 preload has already expired, producing a 265-line frame in Stella 7.0.
# Leave game_priority[] unpinned so overscan must evolve the real persistent
# schedule; pinning identity priority would miss the regression.
expect_timing('persistent top-left dual-preload deadline',120,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$x_addr+0),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'88',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'114',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'140',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'95',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'95',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'82',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'74',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'66',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'58');

# Keep the former bridge-oracle deadline state as a dense same-column scheduler
# timing witness.  The bridge look-ahead itself is gone, but this priority/Y
# arrangement remains useful for detecting VBLANK deadline regressions.
expect_timing('same-column scheduler deadline',120,
   '--released-inputs',
   '--set-zp',sprintf('0x%02x',$x_addr+0),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'0',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'0',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'94',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'93',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'46',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'81',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'62',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'65',
   '--set-zp',sprintf('0x%02x',$priority_addr+0),'5',
   '--set-zp',sprintf('0x%02x',$priority_addr+1),'2',
   '--set-zp',sprintf('0x%02x',$priority_addr+2),'4',
   '--set-zp',sprintf('0x%02x',$priority_addr+3),'0',
   '--set-zp',sprintf('0x%02x',$priority_addr+4),'3',
   '--set-zp',sprintf('0x%02x',$priority_addr+5),'1');

# Hold each randomized geometry for sixteen complete frames.  Per-frame
# randomization badly under-samples the scheduler's persistent priority cycle:
# some timing failures occur only on one of several fairness permutations for
# a fixed layout.  Dense 1..4-column populations deliberately hammer the
# same/near-column scheduler cases that exposed that blind spot.
for my$columns (1..4) {
   expect_timing("held-layout dense-X stress $columns columns",1603,
      '--released-inputs',
      '--randomize-zp-held',sprintf('0x%02x',$x_addr),'6',$columns,
         sprintf('0x%08x',0x51000000+$columns),'16',
      '--randomize-zp-held',sprintf('0x%02x',$y_addr),'6','96',
         sprintf('0x%08x',0x61000000+$columns),'16',
      '--dump-zp',sprintf('0x%02x',$x_addr),'6',
      '--dump-zp',sprintf('0x%02x',$y_addr),'6',
      '--dump-zp',sprintf('0x%02x',$priority_addr),'6');
}

my$phases='23,28,33,37,42,47,50,53,58,63,68,73';
expect_timing('12-phase randomized X stress',5000,
   '--randomize-zp',sprintf('0x%02x',$x_addr),'6','160','0x31415927',
   '--require-resp-phases',$phases);

# The visual-fix checkpoint deliberately retired the experimental adjacent-line
# pair path while ordinary positioning is stabilized.  Pin all six sprites to
# the final far-right class instead and require phase 73 on both hardware lanes.
expect_timing('phase-73 ordinary edge class',500,
   '--set-zp',sprintf('0x%02x',$x_addr+0),'159',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'159',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'159',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'159',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'159',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'159',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'6',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'18',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'34',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'50',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'66',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'82',
   '--require-resp-phases','73');

# Movement-sensitive edge regression: mutate sprite 0 once per synchronized
# frame as 0..159..0.  Static X sweeps missed the historical one-frame line
# count glitches at transitions.
expect_timing('continuous X up/down sweep',647,
   '--sweep-zp',sprintf('0x%02x',$x_addr),'0','159');

# Historical stream-interruption repro: sprites 0/3 share Y=89 and coarse slot
# 6. The top-edge dispatcher has its own balanced one-RESP entry, so this case
# deliberately falls back to the proven split events rather than carrying the
# pair marker into the top boundary.
expect_timing('two simultaneous Y=95 top-edge sprites',500,
   '--set-zp',sprintf('0x%02x',$x_addr+0),'18',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'126',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'62',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'88',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'114',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'140',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'95',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'95',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'72',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'48',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'24',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'8');

expect_timing('top-edge Y 89 through 95 sweep',64,
   '--sweep-zp',sprintf('0x%02x',$y_addr),'89','95');

expect_timing('top-edge pair split fallback',500,
   '--set-zp',sprintf('0x%02x',$x_addr+0),'90',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'124',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'76',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'88',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'94',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'102',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'89',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'8',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'49',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'89',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'55',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'30');

# These paired seeds include the historical top-edge Y=89/late-X exact-cycle-76
# regression, close opposite-lane events, all-six accepted layouts, and bottom
# placements that previously underflowed X into the $ff action sentinel.
for my$spec (
   ['0x31415927','0x27182819'],
   ['0x6d2b79f5','0x1234567b'],
   ['0xa5c39e17','0xdeadbeef'],
) {
   my($xs,$ys)=@$spec;
   expect_timing("combined X/Y stress $xs/$ys",5000,
      '--randomize-zp',sprintf('0x%02x',$x_addr),'6','160',$xs,
      '--randomize-zp',sprintf('0x%02x',$y_addr),'6','96',$ys,
      '--require-resp-phases',$phases);
}

print "vcs_enhanced_multisprite_asymmetric ok: stable full-PF 192-line raster, held-layout dense-X stress, 12-phase edge coverage, continuous X sweep, combined X/Y stress\n";
