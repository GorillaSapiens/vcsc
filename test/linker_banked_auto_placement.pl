#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: banked automatic placement deterministic
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
sub require_fail {
   my ($label, $fragment, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   ($exit != 0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n";
   index($err, $fragment) >= 0
      or die "$label stderr missing '$fragment'\nstdout:\n$out\nstderr:\n$err";
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $cc1 = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $ld = File::Spec->catfile($repo, 'linker', 'vcsc-ld');
my $test_inc = File::Spec->catdir($repo, 'test');
my $runtime_inc = File::Spec->catdir($repo, 'libraries', 'runtime');
my $cfg = File::Spec->catfile($tmp, 'auto-f8.cfg');
my $src = File::Spec->catfile($tmp, 'auto.s26');
my $obj = File::Spec->catfile($tmp, 'auto.o26');
my $bin1 = File::Spec->catfile($tmp, 'auto1.bin');
my $bin2 = File::Spec->catfile($tmp, 'auto2.bin');
my $map1 = File::Spec->catfile($tmp, 'auto1.map');
my $map2 = File::Spec->catfile($tmp, 'auto2.map');

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
   RAM: start=$0080, size=$0080, type=rw;
   bank1: start=$D000, size=$0020, type=ro, bank=BANK1;
   BANK1_TRAMPOLINE: start=$DF00, size=$00E0, bank=BANK1;
   BANK1_VECTOR_BRIDGE: start=$DFE0, size=$0012, bank=BANK1;
   BANK1_TAIL: start=$DFF2, size=$0008, bank=BANK1;
   BANK1_VECTORS: start=$DFFA, size=$0006, bank=BANK1;
   ROM: start=$F000, size=$0020, type=ro, bank=BANK0;
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
   RODATA.bank1: load=bank1, type=ro;
   VECTORS: load=BANK0_VECTORS, type=ro, start=$FFFA;
}
CFG

write_file($src, <<'ASM');
.export __reset
.export __nmi
.export __irqbrk
.export main
.export keep_home
.export spill
.export uses_table
.export bank1_table
.segment "CODE"
.proc __reset
   RTS
.endproc
.proc __nmi
   RTS
.endproc
.proc __irqbrk
   RTS
.endproc
.proc main
   JSR keep_home
   JSR spill
   JSR uses_table
   RTS
.endproc
.proc keep_home
   NOP
   NOP
   NOP
   NOP
   NOP
   RTS
.endproc
.proc spill
   NOP
   NOP
   NOP
   NOP
   NOP
   RTS
.endproc
.proc uses_table
   LDA bank1_table
   RTS
.endproc
.segment "RODATA.bank1.__vcsc_object$bank1_table"
bank1_table:
   .byte $42
ASM

require_ok('assemble automatic placement fixture', $as, '-o', $obj, $src);
for my $pair ([$bin1, $map1], [$bin2, $map2]) {
   require_ok('link automatic placement fixture',
      $ld, '-T', $cfg, '-Map', $pair->[1], '--no-sym', '--no-list', '--no-cfg',
      '-o', $pair->[0], $obj);
}
slurp($bin1) eq slurp($bin2) or die "automatic placement binary was not deterministic\n";
my $map = slurp($map1);
$map =~ /BANK PLACEMENT\n/ or die "map omitted BANK PLACEMENT section\n$map";
$map =~ /automatic CODE\.__vcsc_function\$keep_home\s+region=ROM\s+size=\$0006/
   or die "call-connected keep_home was not kept automatically in BANK0\n$map";
$map =~ /automatic CODE\.__vcsc_function\$spill\s+region=bank1\s+size=\$0006/
   or die "capacity did not spill the stable second function into BANK1\n$map";
$map =~ /component=\d+ assignment=pinned bank=BANK1 bytes=\$0005 cut-weight=\$000F\n\s+automatic CODE\.__vcsc_function\$uses_table\s+region=bank1.*\n\s+pinned\s+RODATA\.bank1\.__vcsc_object\$bank1_table/s
   or die "hard ROM-data component did not pull its unpinned function into BANK1\n$map";
$map =~ /entries=2 jmp=0 jsr=2/
   or die "automatic placement did not produce the expected two cross-bank calls\n$map";
length(slurp($bin1)) == 8192 or die "automatic placement image was not 8K\n";

# Prove the same hard-component behavior from VCSC source, not merely from
# hand-authored private segment names.  A const object in a named $ro region
# must become RODATA.bank1; its unpinned reader follows it, while main remains
# in BANK0 and calls through one generated bridge.
my $source_cfg = File::Spec->catfile($tmp, 'source-f8.cfg');
my $source_c26 = File::Spec->catfile($tmp, 'source.c26');
my $source_s26 = File::Spec->catfile($tmp, 'source.s26');
my $source_obj = File::Spec->catfile($tmp, 'source.o26');
my $handlers_s26 = File::Spec->catfile($tmp, 'handlers.s26');
my $handlers_obj = File::Spec->catfile($tmp, 'handlers.o26');
my $source_bin = File::Spec->catfile($tmp, 'source.bin');
my $source_map = File::Spec->catfile($tmp, 'source.map');
write_file($source_cfg, <<'CFG');
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
   RAM: start=$0080, size=$0080, type=rw;
   bank1: start=$D000, size=$0100, type=ro, bank=BANK1;
   BANK1_TRAMPOLINE: start=$DF00, size=$00E0, bank=BANK1;
   BANK1_VECTOR_BRIDGE: start=$DFE0, size=$0012, bank=BANK1;
   BANK1_TAIL: start=$DFF2, size=$0008, bank=BANK1;
   BANK1_VECTORS: start=$DFFA, size=$0006, bank=BANK1;
   ROM: start=$F000, size=$0100, type=ro, bank=BANK0;
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
   RODATA.bank1: load=bank1, type=ro;
   VECTORS: load=BANK0_VECTORS, type=ro, start=$FFFA;
}
CFG
write_file($source_c26, <<'C26');
include "machine_6502.c26"
mem bank1 { $start:0xD000 $size:0x0100 $ro };

bank1 const uint8_t bank1_table := 0x42;

uint8_t uses_table(void) {
   return bank1_table;
}

void main(void) {
   _ := uses_table();
}
C26
write_file($handlers_s26, <<'ASM');
.import main
.export __reset
.export __nmi
.export __irqbrk
.segment "STARTUP"
.proc __reset
   JSR main
   RTS
.endproc
.proc __nmi
   RTS
.endproc
.proc __irqbrk
   RTS
.endproc
ASM
require_ok('compile source-level placement fixture',
   $cc1, '-quiet', '-I', $test_inc, $source_c26, '-o', $source_s26);
require_ok('assemble source-level placement fixture',
   $as, '-I', $runtime_inc, '-o', $source_obj, $source_s26);
require_ok('assemble source-level reset fixture',
   $as, '-o', $handlers_obj, $handlers_s26);
require_ok('link source-level placement fixture',
   $ld, '-T', $source_cfg, '-Map', $source_map, '--no-sym', '--no-list', '--no-cfg',
   '-o', $source_bin, $handlers_obj, $source_obj);
my $source_map_text = slurp($source_map);
$source_map_text =~ /pinned\s+RODATA\.bank1\.__vcsc_object\$bank1_table\s+region=bank1/
   or die "source-level named \$ro object was not pinned into BANK1\n$source_map_text";
$source_map_text =~ /automatic CODE\.__vcsc_function\$uses_table\s+region=bank1/
   or die "source-level ROM-data edge did not pull uses_table into BANK1\n$source_map_text";
$source_map_text =~ /pinned\s+CODE\.__vcsc_function\$main\s+region=ROM/
   or die "source-level main was not pinned into BANK0\n$source_map_text";
$source_map_text =~ /entries=1 jmp=0 jsr=1/
   or die "source-level placement did not produce exactly one cross-bank call\n$source_map_text";
length(slurp($source_bin)) == 8192 or die "source-level placement image was not 8K\n";

my $conflict_src = File::Spec->catfile($tmp, 'conflict.s26');
my $conflict_obj = File::Spec->catfile($tmp, 'conflict.o26');
write_file($conflict_src, <<'ASM');
.export __reset
.export __nmi
.export __irqbrk
.export main
.export bank1_table
.segment "CODE"
.proc __reset
   RTS
.endproc
.proc __nmi
   RTS
.endproc
.proc __irqbrk
   RTS
.endproc
.proc main
   LDA bank1_table
   RTS
.endproc
.segment "RODATA.bank1.__vcsc_object$bank1_table"
bank1_table:
   .byte $42
ASM
require_ok('assemble contradictory-pin fixture', $as, '-o', $conflict_obj, $conflict_src);
require_fail('contradictory hard pins', 'hard bank-placement component',
   $ld, '-T', $cfg, '--no-map', '--no-sym', '--no-list', '--no-cfg',
   '-o', File::Spec->catfile($tmp, 'conflict.bin'), $conflict_obj);

print "banked automatic placement deterministic\n";
