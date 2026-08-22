#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_enhanced_multisprite_asymmetric ok: stable full-PF 192-line raster, 12-phase edge coverage, continuous X sweep, combined X/Y stress
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
my$example_dir=File::Spec->catdir($repo,qw(examples 18_enhanced_multisprite 01_192 02_asymmetric));
my$example=File::Spec->catfile($example_dir,'enhanced_multisprite_192_asymmetric.c26');
my$startup=File::Spec->catfile($example_dir,'enhanced_multisprite_192_asymmetric_startup.s26');
my$text=read_file($renderer);

$text =~ /TEMPLATE_HARDWARE_LANES\s*:=\s*2/ or die "asymmetric renderer lost two-lane contract\n";
$text =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*192/ or die "asymmetric renderer lost 192-line contract\n";
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
$text =~ /\@TEMPLATE_PreloadTopLoop:;.*?asm cmp #95;.*?asm bcc\.same \@TEMPLATE_PreloadTopDone;/s
   or die "band-95 setup is no longer preloaded during VBLANK\n";
$text !~ /TEMPLATE_TopTrigger/
   or die "obsolete visible action_y=95 trigger path returned\n";
$text =~ /TEMPLATE_ChooseLane:;.*?ldy\.z TEMPLATE_setup_index;.*?ldx\.z TEMPLATE_priority \+ 1;.*?lda\.zx TEMPLATE_y,X;.*?sbc\.z TEMPLATE_pair_y;.*?cmp #6;.*?bcc\.same \@TEMPLATE_ChooseFirstP1/s
   or die "first-candidate scheduler lookahead missing\n";

# Recovered visual-fix contracts.  These are deliberately structural: the
# timing harness below proves the resulting cycle balance while these checks
# prevent the exact color/stale-GRP/PF regressions from being silently restored.
$text =~ /TEMPLATE_PostSetup0LineA:;.*?lda\.ay TEMPLATE_lane_for,Y;\s*asm sta\.z TEMPLATE_pair_y;.*?asm adc #5;/s
   or die "P0 post-setup per-event color refresh missing\n";
$text =~ /TEMPLATE_Setup1LineB:;.*?asm iny;.*?asm sta\.a TEMPLATE_gfx_index \+ 1;.*?asm sta PF1;\s*.*?asm sty\.z TEMPLATE_setup_index;.*?lda\.ay TEMPLATE_lane_for,Y;\s*asm sta\.z TEMPLATE_pair_y;/s
   or die "P1 setup per-event color refresh/timing balance missing\n";
$text =~ /TEMPLATE_PostSetupLineA:;\s*.*?asm lda\.z TEMPLATE_current_gfx;\s*asm sta GRP0;/s
   or die "P1 post-setup stale-GRP suppression missing\n";
$text =~ /TEMPLATE_PostSetupLineBBody:;.*?asm sta PF2;\s*.*?asm ldy\.z TEMPLATE_gfx_index \+ 1;\s*asm lda\.ax TEMPLATE_playfield_right_pf0,X;\s*asm sta PF0;\s*asm lda\.ax TEMPLATE_playfield_right \+ 96,X;\s*asm sta PF1;\s*asm lda\.ay TEMPLATE_graphics_next,Y;/s
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
my($rc,$sig,$out,$err)=capture($driver,'-nostdlib','-I',$vcs,'-DVCS_NTSC_EXTENDED_VBLANK','-DMULTISPRITE_NO_RETAINED_PF_ROWS','-T',File::Spec->catfile($vcs,'vcs.cfg'),$example,$startup,'-o',$bin);
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
my($x_hex)=$sym_text =~ /^game_x\s+([0-9a-fA-F]{4})\s*$/m;
my($y_hex)=$sym_text =~ /^game_y\s+([0-9a-fA-F]{4})\s*$/m;
defined($x_hex) && defined($y_hex) or die "could not locate asymmetric X/Y arrays\n";
my$x_addr=hex($x_hex); my$y_addr=hex($y_hex);
$x_addr<=0xff && $y_addr<=0xff or die "asymmetric X/Y arrays left zero page\n";
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
$out =~ /asymmetric scheduler monte carlo ok: 250000 layouts, min=2, worst-gap=\d+, hist=1:0,/
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

print "vcs_enhanced_multisprite_asymmetric ok: stable full-PF 192-line raster, 12-phase edge coverage, continuous X sweep, combined X/Y stress\n";
