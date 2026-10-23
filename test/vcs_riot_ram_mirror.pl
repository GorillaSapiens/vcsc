#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_riot_ram_mirror ok
# expectexit: 0

# RIOT's 128 bytes are shared by zero page, hardware stack and RAM mirrors.
# A stock-RAM scheduler may use RTS over a prefilled return vector; the CPU
# oracle must not silently model separate zero-page and hardware-stack RAM.
use strict;
use warnings;
use Cwd qw(abs_path);
my($repo,$tmp,$timing_source)=@ARGV;
$repo=abs_path($repo);$tmp=abs_path($tmp);
$timing_source //= "$repo/test/vcs_frame_timing.cpp";
sub run { system(@_)==0 or die "@_ failed\n"; }
open(my$f,'>',"$tmp/probe.c26") or die$!;
print{$f} <<'SOURCE';
include "vcs.c26"
include "frame_ntsc.c26"
uint8_t result;
uint8_t saved_s;
void main(void) {
   VBLANK := 2;
   result := 0;
   asm lda #$5a;
   asm sta.z $c0;
   asm lda.a $01c0;
   asm cmp #$5a;
   asm bne @one_done;
   asm inc.z result;
   asm @one_done:;
   asm lda #$a5;
   asm sta.a $01c0;
   asm lda.z $c0;
   asm cmp #$a5;
   asm bne @two_done;
   asm inc.z result;
   asm @two_done:;
   asm lda #$3c;
   asm sta.a $05c0;
   asm lda.a $0dc0;
   asm cmp #$3c;
   asm bne @three_done;
   asm inc.z result;
   asm @three_done:;
   asm tsx;
   asm stx.z saved_s;
   asm ldx #$bf;
   asm txs;
   asm lda #$69;
   asm pha;
   asm lda.z $bf;
   asm cmp #$69;
   asm bne @four_done;
   asm inc.z result;
   asm @four_done:;
   asm ldx #$be;
   asm txs;
   asm lda #$96;
   asm sta.z $bf;
   asm pla;
   asm cmp #$96;
   asm bne @five_done;
   asm inc.z result;
   asm @five_done:;
   asm ldx.z saved_s;
   asm txs;
   while (1) {
      vcs_ntsc_vsync();
      vcs_ntsc_begin_vblank();
      COLUBK := 0x84;
      vcs_ntsc_end_vblank();
      asm ldx #192;
      asm @visible:;
      asm sta WSYNC;
      asm dex;
      asm bne @visible;
      vcs_ntsc_begin_overscan();
      vcs_ntsc_end_overscan();
   }
}
SOURCE
close$f or die$!;
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/probe.c26",'-o',"$tmp/probe.bin");
open($f,'<',"$tmp/probe.sym") or die$!;local$/;my$sym=<$f>;close$f;
$sym =~ /^result\s+([0-9a-fA-F]{4})\s*$/m or die 'missing result';my$result=hex$1;
my$mos="$repo/simulator/mos6502";my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$timing_source,$obj,'-o',"$tmp/timing");
run("$tmp/timing","$tmp/probe.bin",'200','--no-audio','--released-inputs','--raw-lines','264',
   '--expect-memory',$result,5,'--expect-memory',0x00c0,0x3c,
   '--expect-memory',0x01c0,0x3c,'--expect-memory',0x05c0,0x3c,
   '--expect-memory',0x0dc0,0x3c,'--expect-memory',0x01bf,0x96);
print "vcs_riot_ram_mirror ok\n";
