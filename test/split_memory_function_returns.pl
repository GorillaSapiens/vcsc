#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Generic split-address function returns passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my ($fh) = @_; local $/; return <$fh> // ''; }
sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   my $stdout = slurp_fh($out);
   my $stderr = slurp_fh($err);
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub require_ok {
   my ($label, @cmd) = @_;
   my ($rc, $sig, $out, $err) = run_capture(@cmd);
   $rc == 0 && !$sig
      or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out, $err);
}
sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "write $path: $!\n";
   print {$fh} $text or die "write $path: $!\n";
   close($fh) or die "close $path: $!\n";
}
sub read_file {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "read $path: $!\n";
   local $/;
   my $text = <$fh> // '';
   close($fh);
   return $text;
}
sub parse_symbol {
   my ($sym, $name) = @_;
   $sym =~ /^\Q$name\E\s+([0-9A-Fa-f]{4})\s*$/m
      or die "symbol file is missing $name\n";
   return hex($1);
}
sub parse_dump {
   my ($text) = @_;
   my @mem = (0) x 65536;
   for my $line (split /\n/, $text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my ($count, $addr, $bytes) = (hex($1), hex($2), $3);
      length($bytes) == $count * 2 or die "bad Intel HEX dump record\n";
      for my $i (0 .. $count - 1) {
         $mem[$addr + $i] = hex(substr($bytes, $i * 2, 2));
      }
   }
   return \@mem;
}

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $sim = File::Spec->catfile($repo, 'simulator', 'vcsc-sim');
my $test_inc = File::Spec->catdir($repo, 'test');
my $cfg = File::Spec->catfile($tmp, 'split-return.cfg');
my $main = File::Spec->catfile($tmp, 'main.c26');
my $defs = File::Spec->catfile($tmp, 'defs.c26');
my $hex = File::Spec->catfile($tmp, 'out.hex');
my $map_path = File::Spec->catfile($tmp, 'out.map');
my $sym_path = File::Spec->catfile($tmp, 'out.sym');

write_file($cfg, <<'CFG');
MEMORY {
    ZEROPAGE: start = $0000, size = $0100, type = rw, define = yes;
    CPUSTACK: start = $0100, size = $0100, type = rw, define = yes;
    RAM:      start = $0200, size = $1E00, type = rw, define = yes;

    banana: read_start = $3003, write_start = $5007, size = $0002, type = rw, define = yes;
    pair:   read_start = $6205, write_start = $2201, size = $0004, type = rw, define = yes;
    orange: read_start = $7102, write_start = $4A11, size = $0003, type = rw, define = yes;

    ROM: start = $8000, size = $8000, type = ro, define = yes;
}
SEGMENTS {
    ZEROPAGE: load = ROM, run = ZEROPAGE, type = zp, define = yes;
    CODE:     load = ROM,                 type = ro, define = yes;
    RODATA:   load = ROM,                 type = ro, define = yes;
    BSS:      load = RAM,                 type = bss, define = yes;
    DATA:     load = ROM, run = RAM,      type = data, define = yes;
}
CFG

my $mem_decls = <<'MEM';
mem banana { $read_start:0x3003 $write_start:0x5007 $size:0x0002 $rw };
mem pair   { $read_start:0x6205 $write_start:0x2201 $size:0x0004 $rw };
mem orange { $read_start:0x7102 $write_start:0x4A11 $size:0x0003 $rw };
MEM

write_file($main, <<"MAIN");
include "machine_6502.c26"
$mem_decls
uint8_t result;
uint8_t anchor;
banana uint8_t banana_value(void);
banana uint8_t *banana_pointer(void);
pair uint32_t pair_value(void);
orange uint24_t orange_value(void);
void simulator_done(void) { while (1) {} }
void main(void) {
   if (banana_value() != 0x5a) { result := 0xe1; }
   if (pair_value() != 0x12345678) { result := 0xe2; }
   if (orange_value() != 0x345678) { result := 0xe3; }
   if (banana_pointer() != &anchor) { result := 0xe4; }
   if (result == 0) { result := 0xaa; }
   asm jmp simulator_done;
}
MAIN

write_file($defs, <<"DEFS");
include "machine_6502.c26"
$mem_decls
extern uint8_t anchor;
banana uint8_t banana_value(void) {
   return 0x5a;
}
banana uint8_t *banana_pointer(void) {
   return &anchor;
}
pair uint32_t pair_value(void) {
   \$\$ := 0x12345670;
   if (\$\$ != 0x12345670) { return 0; }
   \$\$ += 8;
   return;
}
orange uint24_t orange_value(void) {
   \$\$ := 0x345677;
   \$\$ += 1;
   return;
}
DEFS

require_ok('build separately compiled generic split-return fixture',
   $driver, '-I', $test_inc, '-T', $cfg, '-Map', $map_path, '-Sym', $sym_path,
   $main, $defs, '-o', $hex);

my $map = read_file($map_path);
for my $pattern (
   qr/^\s*banana\s+used=2 bytes\b.*\bobjects=2 bytes\b/m,
   qr/^\s*pair\s+used=4 bytes\b.*\bobjects=4 bytes\b/m,
   qr/^\s*orange\s+used=3 bytes\b.*\bobjects=3 bytes\b/m,
   qr/^\s*BSS\.banana\.__vcsc_activation\$banana_value run=\$3003 write=\$5007 size=\$0001\b/m,
   qr/^\s*BSS\.banana\.__vcsc_activation\$banana_pointer run=\$3003 write=\$5007 size=\$0002\b/m,
   qr/^\s*BSS\.pair\.__vcsc_activation\$pair_value run=\$6205 write=\$2201 size=\$0004\b/m,
   qr/^\s*BSS\.orange\.__vcsc_activation\$orange_value run=\$7102 write=\$4A11 size=\$0003\b/m) {
   $map =~ $pattern or die "generic split-return map is missing $pattern\n$map";
}

my $sym = read_file($sym_path);
my $done = parse_symbol($sym, 'simulator_done');
my $result = parse_symbol($sym, 'result');
my $anchor = parse_symbol($sym, 'anchor');
parse_symbol($sym, 'banana_value$__return') == 0x3003
   or die "banana value return symbol was not placed at the read window\n";
parse_symbol($sym, 'banana_pointer$__return') == 0x3003
   or die "banana pointer return symbol was not placed at the read window\n";
parse_symbol($sym, 'pair_value$__return') == 0x6205
   or die "pair return symbol was not placed at the read window\n";
parse_symbol($sym, 'orange_value$__return') == 0x7102
   or die "orange return symbol was not placed at the read window\n";

my ($dump, $sim_err) = require_ok('simulate generic split-return fixture',
   $sim, '-T', $cfg, sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $hex);
$sim_err eq '' or die "generic split-return simulator wrote stderr:\n$sim_err";
my $mem = parse_dump($dump);
$mem->[$result] == 0xaa
   or die sprintf("generic split-return result is %02X, expected AA\n", $mem->[$result]);

my @windows = (
   [0x3003, 0x5007, [$anchor & 0xff, ($anchor >> 8) & 0xff]],
   [0x6205, 0x2201, [0x78, 0x56, 0x34, 0x12]],
   [0x7102, 0x4A11, [0x78, 0x56, 0x34]],
);
for my $window (@windows) {
   my ($read_start, $write_start, $expected) = @$window;
   for my $offset (0 .. $#$expected) {
      $mem->[$read_start + $offset] == $expected->[$offset]
         or die sprintf("read alias %04X is %02X, expected %02X\n",
                        $read_start + $offset, $mem->[$read_start + $offset],
                        $expected->[$offset]);
      $mem->[$write_start + $offset] == $expected->[$offset]
         or die sprintf("write alias %04X is %02X, expected %02X\n",
                        $write_start + $offset, $mem->[$write_start + $offset],
                        $expected->[$offset]);
   }
}

# Return storage is part of the function ABI. The linker must reject a caller
# and definition that agree on value type but disagree on the result region.
my $bad_main = File::Spec->catfile($tmp, 'bad_main.c26');
my $bad_def = File::Spec->catfile($tmp, 'bad_def.c26');
write_file($bad_main, <<"BADMAIN");
include "machine_6502.c26"
$mem_decls
orange uint24_t mismatch(void);
void main(void) { uint24_t v := mismatch(); }
BADMAIN
write_file($bad_def, <<"BADDEF");
include "machine_6502.c26"
$mem_decls
pair uint24_t mismatch(void) { return 1; }
BADDEF
my ($bad_rc, $bad_sig, $bad_out, $bad_err) = run_capture(
   $driver, '-I', $test_inc, '-T', $cfg, $bad_main, $bad_def,
   '-o', File::Spec->catfile($tmp, 'bad.hex'));
$bad_rc != 0 && !$bad_sig
   or die "split-return ABI mismatch unexpectedly linked\n$bad_out\n$bad_err";
$bad_err =~ /ABI\/type fingerprint mismatch for function symbol 'mismatch' return/s
   or die "split-return ABI mismatch did not identify the return object\n$bad_err";
$bad_err =~ /region=orange/ && $bad_err =~ /region=pair/
   or die "split-return ABI mismatch omitted the conflicting regions\n$bad_err";

# A return object larger than its selected region must fail deterministically.
my $overflow = File::Spec->catfile($tmp, 'overflow.c26');
write_file($overflow, <<"OVERFLOW");
include "machine_6502.c26"
$mem_decls
banana uint32_t too_big(void) { return 1; }
void main(void) { uint32_t v := too_big(); }
OVERFLOW
for my $attempt (1 .. 2) {
   my ($rc, $sig, $out, $err) = run_capture(
      $driver, '-I', $test_inc, '-T', $cfg, $overflow,
      '-o', File::Spec->catfile($tmp, "overflow_$attempt.hex"));
   $rc != 0 && !$sig
      or die "split-return overflow attempt $attempt unexpectedly linked\n$out\n$err";
   $err =~ /banana overflow while placing activation overlay from <call graph> in banana/
      or die "split-return overflow attempt $attempt was not deterministic\n$err";
}

print "Generic split-address function returns passed\n";
