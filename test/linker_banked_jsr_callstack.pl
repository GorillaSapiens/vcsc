#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: banked JSR call stack weighted
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}
sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not read $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
}
sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub require_ok {
   my ($label, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit == 0 && !$sig
      or die "$label failed: exit=$exit signal=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out, $err);
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $include = File::Spec->catfile($repo, 'test');
my $src = File::Spec->catfile($tmp, 'weighted.c26');
my $cfg = File::Spec->catfile($tmp, 'f8.cfg');
my $bin = File::Spec->catfile($tmp, 'weighted.bin');
my $map = File::Spec->catfile($tmp, 'weighted.map');

write_file($src, <<'SRC');
include "machine_6502.c26"
mem ZEROPAGE { $start:0x0000 $size:0x0080 $rw $priority:3 };
mem ram { $start:0x0080 $size:0x0080 $rw $priority:2 };
mem bank1 { $start:0xD000 $size:0x0F00 $ro };
mem ROM { $start:0xF000 $size:0x0F00 $ro $priority:2 };

ROM void home_leaf(void) {
   asm nop;
}

bank1 void remote(void) {
   home_leaf();
}

void main(void) {
   remote();
}
SRC

write_file($cfg, <<'CFG');
CARTRIDGE {
   mapper = F8;
   fillval = $FF;
   trampoline = $0F00;
   trampolinesize = $00E0;
   vectorbridge = $0FE0;
}
BANKS {
   BANK0: start=$F000, size=$1000, hotspot=$1FF9, startup=yes;
   BANK1: start=$D000, size=$1000, hotspot=$1FF8, startup=no;
}
MEMORY {
   ZEROPAGE: start=$0000, size=$0080, type=rw;
   RAM: start=$0080, size=$0080, type=rw, callstack=callgraph;
   bank1: start=$D000, size=$0F00, type=ro, bank=BANK1;
   BANK1_TRAMPOLINE: start=$DF00, size=$00E0, bank=BANK1;
   BANK1_VECTOR_BRIDGE: start=$DFE0, size=$0012, bank=BANK1;
   BANK1_TAIL: start=$DFF2, size=$0008, bank=BANK1;
   BANK1_VECTORS: start=$DFFA, size=$0006, bank=BANK1;
   ROM: start=$F000, size=$0F00, type=ro, bank=BANK0;
   BANK0_TRAMPOLINE: start=$FF00, size=$00E0, bank=BANK0;
   BANK0_VECTOR_BRIDGE: start=$FFE0, size=$0012, bank=BANK0;
   BANK0_TAIL: start=$FFF2, size=$0008, bank=BANK0;
   BANK0_VECTORS: start=$FFFA, size=$0006, bank=BANK0;
}
SEGMENTS {
   ZEROPAGE: load=ROM, run=ZEROPAGE, type=zp;
   DATA: load=ROM, run=RAM, type=data;
   BSS: load=RAM, type=bss;
   STARTUP: load=ROM, type=ro;
   CODE: load=ROM, type=ro;
   CODE.bank1: load=bank1, type=ro;
   RODATA: load=ROM, type=ro;
   VECTORS: load=BANK0_VECTORS, type=ro, start=$FFFA;
}
CFG

require_ok('compile and link weighted banked call graph',
           $vcsc, '-I', $include, '-DMACHINE_6502_NO_DEFAULT_ZEROPAGE', '-DMACHINE_6502_NO_DEFAULT_CPUSTACK', '-DMACHINE_6502_NO_DEFAULT_RAM', '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $cfg, '-Map', $map,
           '-o', $bin, $src);
my $map_text = slurp($map);
length(slurp($bin)) == 8192 or die "weighted banked program was not 8K\n";
$map_text =~ /CALL STACK\n  region=ram depth=2 bytes=\$0008 physical=\$00F8-\$00FF extra=\$0000 weighted-depth=4 bank-extra-slots=2/
   or die "cross-bank edges did not add two weighted return-address slots\n$map_text";
$map_text =~ /^\s*\$0002\s+__call_stack_depth\b/m
   or die "ordinary source call depth symbol is wrong\n$map_text";
$map_text =~ /^\s*\$0004\s+__call_stack_weighted_depth\b/m
   or die "weighted hardware-return depth symbol is wrong\n$map_text";
$map_text =~ /^\s*\$0002\s+__call_stack_bank_extra_slots\b/m
   or die "bank bridge stack-slot symbol is wrong\n$map_text";
$map_text =~ /entries=2 jmp=0 jsr=2 jmp-size=\$08 jsr-size=\$0F/
   or die "source-level cross-bank calls did not generate two JSR entries\n$map_text";
$map_text =~ /JSR entry=.*source=BANK0 hotspot=\$1FF9 destination=BANK1 hotspot=\$1FF8/
   or die "map omitted BANK0-to-BANK1 source call\n$map_text";
$map_text =~ /JSR entry=.*source=BANK1 hotspot=\$1FF8 destination=BANK0 hotspot=\$1FF9/
   or die "map omitted BANK1-to-BANK0 nested source call\n$map_text";

print "banked JSR call stack weighted\n";
