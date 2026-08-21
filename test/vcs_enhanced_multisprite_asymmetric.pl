#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_enhanced_multisprite_asymmetric ok: stable full-PF 192-line raster, phase-73 adjacent-line pair proof, combined X/Y stress
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
my$example=File::Spec->catfile($repo,qw(examples 18_enhanced_multisprite 01_192 02_asymmetric enhanced_multisprite_192_asymmetric.c26));
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

my$bin=File::Spec->catfile($tmp,'enhanced_asymmetric.bin');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$example,'-o',$bin);
$rc==0 && !$sig or die "asymmetric example build failed\n$out$err";
$out=without_usage($out); $out eq '' or die "asymmetric example build stdout: $out";
$err eq '' or die "asymmetric example build stderr: $err";
(-s $bin)==4096 or die "asymmetric example is not a 4K ROM\n";

(my$sym=$bin) =~ s/\.bin\z/.sym/;
my$sym_text=read_file($sym);
my($x_hex)=$sym_text =~ /^game_x\s+([0-9a-fA-F]{4})\s*$/m;
my($y_hex)=$sym_text =~ /^game_y\s+([0-9a-fA-F]{4})\s*$/m;
defined($x_hex) && defined($y_hex) or die "could not locate asymmetric X/Y arrays\n";
my$x_addr=hex($x_hex); my$y_addr=hex($y_hex);
$x_addr<=0xff && $y_addr<=0xff or die "asymmetric X/Y arrays left zero page\n";
$y_addr==$x_addr+6 or die "asymmetric X/Y array layout changed\n";

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
   $o eq "vcs_frame_timing ok: $checked frames at 262 lines, 0 AUDV0 writes\n"
      or die "bad $name output: $o";
   $e eq '' or die "$name stderr: $e";
}

expect_timing('static asymmetric timing',100);

my$phases='14,19,24,28,33,37,42,47,50,53,58,63';
expect_timing('13-phase randomized X stress',5000,
   '--randomize-zp',sprintf('0x%02x',$x_addr),'6','160','0x31415927',
   '--require-resp-phases',$phases);

# Pin the first hardware-derived far-right 152-cycle feasibility class.
# Sprites 2/3 share Y=74 at public X=159; RESP0 and RESP1 must occur on
# adjacent physical lines at phase 73, followed by HMOVE at absolute cycle 152.
expect_timing('phase-73 adjacent-line pair',500,
   '--set-zp',sprintf('0x%02x',$x_addr+0),'93',
   '--set-zp',sprintf('0x%02x',$x_addr+1),'115',
   '--set-zp',sprintf('0x%02x',$x_addr+2),'159',
   '--set-zp',sprintf('0x%02x',$x_addr+3),'159',
   '--set-zp',sprintf('0x%02x',$x_addr+4),'24',
   '--set-zp',sprintf('0x%02x',$x_addr+5),'136',
   '--set-zp',sprintf('0x%02x',$y_addr+0),'6',
   '--set-zp',sprintf('0x%02x',$y_addr+1),'0',
   '--set-zp',sprintf('0x%02x',$y_addr+2),'74',
   '--set-zp',sprintf('0x%02x',$y_addr+3),'74',
   '--set-zp',sprintf('0x%02x',$y_addr+4),'2',
   '--set-zp',sprintf('0x%02x',$y_addr+5),'1',
   '--require-resp-phases','73',
   '--require-adjacent-resp');

# Historical stream-interruption repro: sprites 0/3 share Y=89 and coarse slot
# 6. The top-edge dispatcher has its own balanced one-RESP entry, so this case
# deliberately falls back to the proven split events rather than carrying the
# pair marker into the top boundary.
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
      '--randomize-zp',sprintf('0x%02x',$y_addr),'6','90',$ys,
      '--require-resp-phases',$phases);
}

print "vcs_enhanced_multisprite_asymmetric ok: stable full-PF 192-line raster, phase-73 adjacent-line pair proof, combined X/Y stress\n";
