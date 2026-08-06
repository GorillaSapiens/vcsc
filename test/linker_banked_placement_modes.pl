#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: banked placement modes and local optimization
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
sub cfg_text {
   my ($size) = @_;
   return sprintf(<<'CFG', $size, $size);
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
   bank1: start=$D000, size=$%04X, type=ro, bank=BANK1;
   BANK1_TRAMPOLINE: start=$DF00, size=$00E0, bank=BANK1;
   BANK1_VECTOR_BRIDGE: start=$DFE0, size=$0012, bank=BANK1;
   BANK1_TAIL: start=$DFF2, size=$0008, bank=BANK1;
   BANK1_VECTORS: start=$DFFA, size=$0006, bank=BANK1;
   ROM: start=$F000, size=$%04X, type=ro, bank=BANK0;
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
}
sub compile_fixture {
   my (%arg) = @_;
   my $dir = $arg{dir};
   my $size = $arg{size};
   my $source = $arg{source};
   my $cfg = File::Spec->catfile($dir, 'fixture.cfg');
   my $c26 = File::Spec->catfile($dir, 'fixture.c26');
   my $s26 = File::Spec->catfile($dir, 'fixture.s26');
   my $obj = File::Spec->catfile($dir, 'fixture.o26');
   my $handlers_s26 = File::Spec->catfile($dir, 'handlers.s26');
   my $handlers_obj = File::Spec->catfile($dir, 'handlers.o26');
   make_path($dir);
   write_file($cfg, cfg_text($size));
   write_file($c26, $source);
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
   require_ok('compile placement fixture', $arg{cc1}, '-quiet', '-I', $arg{test_inc},
      '-DMACHINE_6502_NO_DEFAULT_ZEROPAGE', '-DMACHINE_6502_NO_DEFAULT_CPUSTACK',
      '-DMACHINE_6502_NO_DEFAULT_RAM', '-DMACHINE_6502_NO_DEFAULT_ROM',
      $c26, '-o', $s26);
   require_ok('assemble placement fixture', $arg{as}, '-I', $arg{runtime_inc},
      '-o', $obj, $s26);
   require_ok('assemble placement handlers', $arg{as}, '-o', $handlers_obj,
      $handlers_s26);
   return ($cfg, $handlers_obj, $obj);
}
sub link_mode {
   my (%arg) = @_;
   my $stem = File::Spec->catfile($arg{dir}, $arg{mode});
   my $bin = "$stem.bin";
   my $map = "$stem.map";
   my @mode_arg = $arg{mode} eq 'default'
      ? () : ("--bank-placement=$arg{mode}");
   my ($out, $err) = require_ok("link $arg{mode} placement fixture",
      $arg{ld}, '-T', $arg{cfg}, @mode_arg, '--explain-bank-placement',
      '-Map', $map, '--no-sym', '--no-list', '--no-cfg', '-o', $bin,
      @{$arg{objects}});
   return ($bin, $map, $out, $err);
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
my ($help) = require_ok('read linker placement help', $ld, '--help');
$help =~ /--bank-placement=MODE/ && $help =~ /--explain-bank-placement/
   or die "linker help omitted bank-placement controls\n$help";
require_fail('reject bad placement mode', "bad bank-placement mode 'mystical'",
   $ld, '--bank-placement=mystical');

my $order_dir = File::Spec->catdir($tmp, 'ordering');
my $order_source = <<'C26';
include "machine_6502.c26"
mem ZEROPAGE { $start:0x0000 $size:0x0080 $rw $priority:3 };
mem RAM { $start:0x0080 $size:0x0080 $rw $priority:2 };
mem ROM { $start:0xF000 $size:0x003D $ro $priority:2 };
mem bank1 { $start:0xD000 $size:0x003D $ro };
void b(void);
void c(void);
void a(void) {
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
   b();
}
void b(void) {
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
   c();
}
void c(void) { asm nop; asm nop; asm nop; asm nop; }
void main(void) { a(); }
C26
my ($order_cfg, @order_objects) = compile_fixture(
   dir => $order_dir, size => 0x003D, source => $order_source,
   cc1 => $cc1, as => $as, test_inc => $test_inc, runtime_inc => $runtime_inc);
my ($order_simple_bin, $order_simple_map) = link_mode(
   dir => $order_dir, mode => 'simple', ld => $ld, cfg => $order_cfg,
   objects => \@order_objects);
my ($order_opt_bin, $order_opt_map, undef, $order_opt_err) = link_mode(
   dir => $order_dir, mode => 'optimized', ld => $ld, cfg => $order_cfg,
   objects => \@order_objects);
my ($order_default_bin, $order_default_map, undef, $order_default_err) = link_mode(
   dir => $order_dir, mode => 'default', ld => $ld, cfg => $order_cfg,
   objects => \@order_objects);
my $order_simple = slurp($order_simple_map);
my $order_opt = slurp($order_opt_map);
$order_simple =~ /mode=simple/ &&
$order_simple =~ /entries=2 jmp=0 jsr=2/ &&
$order_simple =~ /weighted-depth=6 bank-extra-slots=2/
   or die "simple ordering fixture did not expose the expected two bank crossings\n$order_simple";
$order_opt =~ /mode=optimized/ &&
$order_opt =~ /entries=1 jmp=0 jsr=1/ &&
$order_opt =~ /weighted-depth=5 bank-extra-slots=1/
   or die "optimized ordering did not reduce bridges and stack depth\n$order_opt";
$order_opt_err =~ /candidate component=\d+ bank=BANK[01]/ &&
$order_opt_err =~ /final cut-byte-weight=\$000F cut-cycle-weight=25 cut-sites=1/
   or die "placement explanation omitted candidate or final metrics\n$order_opt_err";
slurp($order_simple_bin) ne slurp($order_opt_bin)
   or die "simple and optimized ordering images unexpectedly matched\n";
slurp($order_default_bin) eq slurp($order_opt_bin) &&
slurp($order_default_map) eq slurp($order_opt_map) &&
$order_default_err =~ /BANK PLACEMENT EXPLANATION mode=optimized/
   or die "default bank placement did not exactly match explicit optimized mode\n";

my $local_dir = File::Spec->catdir($tmp, 'local-move');
my $local_source = <<'C26';
include "machine_6502.c26"
mem ZEROPAGE { $start:0x0000 $size:0x0080 $rw $priority:3 };
mem RAM { $start:0x0080 $size:0x0080 $rw $priority:2 };
mem ROM { $start:0xF000 $size:0x0100 $ro $priority:2 };
mem bank1 { $start:0xD000 $size:0x0100 $ro };
void b(void);
bank1 void p0(void);
bank1 void p1(void);
bank1 void p2(void);
bank1 void p3(void);
void a(void) {
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
   asm nop; asm nop; asm nop; asm nop;
   b(); b(); b();
}
void b(void) { p0(); p1(); p2(); p3(); }
bank1 void p0(void) { asm nop; }
bank1 void p1(void) { asm nop; }
bank1 void p2(void) { asm nop; }
bank1 void p3(void) { asm nop; }
void main(void) { a(); }
C26
my ($local_cfg, @local_objects) = compile_fixture(
   dir => $local_dir, size => 0x0100, source => $local_source,
   cc1 => $cc1, as => $as, test_inc => $test_inc, runtime_inc => $runtime_inc);
my (undef, $local_simple_map) = link_mode(
   dir => $local_dir, mode => 'simple', ld => $ld, cfg => $local_cfg,
   objects => \@local_objects);
my ($local_opt_bin, $local_opt_map, undef, $local_opt_err) = link_mode(
   dir => $local_dir, mode => 'optimized', ld => $ld, cfg => $local_cfg,
   objects => \@local_objects);
my ($local_opt_bin2, $local_opt_map2) = link_mode(
   dir => $local_dir, mode => 'optimized', ld => $ld, cfg => $local_cfg,
   objects => \@local_objects);
my $local_simple = slurp($local_simple_map);
my $local_opt = slurp($local_opt_map);
$local_simple =~ /entries=4 jmp=0 jsr=4/
   or die "simple local-move fixture did not retain four bridges\n$local_simple";
$local_opt =~ /entries=1 jmp=0 jsr=1/ &&
$local_opt =~ /automatic CODE\.__vcsc_function\$a\?\s+region=bank1/ &&
$local_opt =~ /automatic CODE\.__vcsc_function\$b\s+region=bank1/ &&
$local_opt =~ /pinned\s+CODE\.__vcsc_function\$main\s+region=ROM/ &&
$local_opt =~ /pinned\s+CODE\.bank1\.__vcsc_function\$p0\s+region=bank1/
   or die "optimized local move changed a pin or failed to co-locate automatic code\n$local_opt";
$local_opt_err =~ /local-move component=\d+ from=BANK0 to=BANK1/ &&
$local_opt_err =~ /cut-byte-weight=\$002D->\$000F/ &&
$local_opt_err =~ /weighted-depth=5->5/
   or die "local-move explanation omitted the measured improvement\n$local_opt_err";
slurp($local_opt_bin) eq slurp($local_opt_bin2) &&
slurp($local_opt_map) eq slurp($local_opt_map2)
   or die "optimized local placement was not deterministic\n";
length(slurp($local_opt_bin)) == 8192
   or die "optimized local-move image was not 8K\n";

my $stack_dir = File::Spec->catdir($tmp, 'stack-guard');
my $stack_source = <<'C26';
include "machine_6502.c26"
mem ZEROPAGE { $start:0x0000 $size:0x0080 $rw $priority:3 };
mem RAM { $start:0x0080 $size:0x0080 $rw $priority:2 };
mem ROM { $start:0xF000 $size:0x0052 $ro $priority:2 };
mem bank1 { $start:0xD000 $size:0x0052 $ro };
void neighbor(void);
ROM void deep0(void);
ROM void deep1(void);
ROM void deep2(void);
void pivot(void) {
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
   asm nop; asm nop; asm nop; asm nop;
   deep0(); neighbor(); neighbor(); neighbor(); neighbor();
}
void neighbor(void) {
   asm nop; asm nop; asm nop; asm nop; asm nop; asm nop; asm nop;
}
ROM void deep0(void) { deep1(); }
ROM void deep1(void) { deep2(); }
ROM void deep2(void) { asm nop; }
void main(void) { pivot(); }
C26
my ($stack_cfg, @stack_objects) = compile_fixture(
   dir => $stack_dir, size => 0x0052, source => $stack_source,
   cc1 => $cc1, as => $as, test_inc => $test_inc, runtime_inc => $runtime_inc);
my (undef, $stack_map, undef, $stack_err) = link_mode(
   dir => $stack_dir, mode => 'optimized', ld => $ld, cfg => $stack_cfg,
   objects => \@stack_objects);
my $stack_text = slurp($stack_map);
$stack_text =~ /automatic CODE\.__vcsc_function\$pivot\s+region=ROM/ &&
$stack_text =~ /automatic CODE\.__vcsc_function\$neighbor\s+region=bank1/ &&
$stack_text =~ /entries=1 jmp=0 jsr=1/ &&
$stack_text =~ /weighted-depth=5 bank-extra-slots=0/
   or die "weighted-depth guard fixture did not retain the safe greedy placement\n$stack_text";
$stack_err =~ /local-candidate component=\d+ bank=BANK1 rejected=weighted-depth-increase/ &&
$stack_err =~ /byte-weight=\$003C->\$001E weighted-depth=5->7/
   or die "placement explanation did not show the stack-depth guard rejection\n$stack_err";

print "banked placement modes and local optimization\n";
