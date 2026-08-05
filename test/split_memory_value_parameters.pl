#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Generic split-address value parameters passed
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
my $cfg = File::Spec->catfile($tmp, 'split-parameter.cfg');
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

    banana: read_start = $3003, write_start = $5007, size = $0003, type = rw, define = yes;
    pair:   read_start = $6205, write_start = $2201, size = $0008, type = rw, define = yes;
    orange: read_start = $7102, write_start = $4A11, size = $0004, type = rw, define = yes;

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
mem rom { $start:0x8000 $size:0x8000 $ro $priority:1 };
mem banana { $read_start:0x3003 $write_start:0x5007 $size:0x0003 $rw };
mem pair   { $read_start:0x6205 $write_start:0x2201 $size:0x0008 $rw };
mem orange { $read_start:0x7102 $write_start:0x4A11 $size:0x0004 $rw };
MEM

write_file($main, <<"MAIN");
include "machine_6502.c26"
$mem_decls
uint8_t result;
void banana_consume(banana uint8_t a, banana uint16_t b);
void pair_consume(pair uint32_t a, pair bcd32_t b);
void orange_outer(orange uint16_t value);
void simulator_done(void) { while (1) {} }
uint16_t make_word(void) { return 0x1234; }
void main(void) {
   banana_consume(5, make_word());
   pair_consume(0x12345678, 87654321);
   orange_outer(0x2001);
   if (result == 0) { result := 0xaa; }
   asm jmp simulator_done;
}
MAIN

write_file($defs, <<"DEFS");
include "machine_6502.c26"
$mem_decls
extern uint8_t result;
void banana_consume(banana uint8_t a, banana uint16_t b) {
   if (a != 5 || b != 0x1234) { result := 0xe1; }
   a += 1;
   b += 1;
}
void pair_consume(pair uint32_t a, pair bcd32_t b) {
   if (a != 0x12345678 || b != 87654321) { result := 0xe2; }
   a += 1;
   b += 1;
}
void orange_inner(orange uint16_t value) {
   value += 3;
   if (value != 0x2004) { result := 0xe3; }
}
void orange_outer(orange uint16_t value) {
   orange_inner(value);
   value += 2;
   if (value != 0x2003) { result := 0xe4; }
}
DEFS

require_ok('build separately compiled generic split-parameter fixture',
   $driver, '-I', $test_inc, '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $cfg, '-Map', $map_path, '-Sym', $sym_path,
   $main, $defs, '-o', $hex);

my $map = read_file($map_path);
for my $pattern (
   qr/^\s*banana\s+used=3 bytes\b.*\bobjects=3 bytes\b/m,
   qr/^\s*pair\s+used=8 bytes\b.*\bobjects=8 bytes\b/m,
   qr/^\s*orange\s+used=4 bytes\b.*\bobjects=4 bytes\b/m,
   qr/^\s*BSS\.banana\.__vcsc_activation\$banana_consume run=\$3003 write=\$5007 size=\$0003\b/m,
   qr/^\s*BSS\.pair\.__vcsc_activation\$pair_consume run=\$6205 write=\$2201 size=\$0008\b/m,
   qr/^\s*BSS\.orange\.__vcsc_activation\$orange_outer run=\$7102 write=\$4A11 size=\$0002\b/m,
   qr/^\s*BSS\.orange\.__vcsc_activation\$orange_inner run=\$7104 write=\$4A13 size=\$0002\b/m) {
   $map =~ $pattern or die "generic split-parameter map is missing $pattern\n$map";
}

my $sym = read_file($sym_path);
my $done = parse_symbol($sym, 'simulator_done');
my $result = parse_symbol($sym, 'result');
my ($dump, $sim_err) = require_ok('simulate generic split-parameter fixture',
   $sim, '-T', $cfg, sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $hex);
$sim_err eq '' or die "generic split-parameter simulator wrote stderr:\n$sim_err";
my $mem = parse_dump($dump);
$mem->[$result] == 0xaa
   or die sprintf("generic split-parameter result is %02X, expected AA\n", $mem->[$result]);

my @checks = (
   ['banana_consume$a', 0x06, 0x3003, 0x5007],
   ['banana_consume$b', 0x35, 0x3004, 0x5008],
   ['pair_consume$a',   0x79, 0x6205, 0x2201],
   ['pair_consume$b',   0x22, 0x6209, 0x2205],
   ['orange_outer$value', 0x03, 0x7102, 0x4A11],
   ['orange_inner$value', 0x04, 0x7104, 0x4A13],
);
for my $check (@checks) {
   my ($name, $want, $read_addr, $write_addr) = @$check;
   parse_symbol($sym, $name) == $read_addr
      or die "$name was not exported at its read window\n";
   $mem->[$read_addr] == $want
      or die sprintf("%s read-window byte is %02X, expected %02X\n",
                     $name, $mem->[$read_addr], $want);
   $mem->[$write_addr] == $want
      or die sprintf("%s write-window byte is %02X, expected %02X\n",
                     $name, $mem->[$write_addr], $want);
}

# The linker-visible ABI must distinguish parameter storage regions. A caller
# declaring banana and a definition using pair are not ABI-compatible even
# though the value type and width match.
my $bad_main = File::Spec->catfile($tmp, 'bad_main.c26');
my $bad_def = File::Spec->catfile($tmp, 'bad_def.c26');
write_file($bad_main, <<"BADMAIN");
include "machine_6502.c26"
$mem_decls
void mismatch(banana uint16_t value);
void main(void) { mismatch(1); }
BADMAIN
write_file($bad_def, <<"BADDEF");
include "machine_6502.c26"
$mem_decls
void mismatch(pair uint16_t value) {}
BADDEF
my ($bad_rc, $bad_sig, $bad_out, $bad_err) = run_capture(
   $driver, '-I', $test_inc, '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $cfg, $bad_main, $bad_def,
   '-o', File::Spec->catfile($tmp, 'bad.hex'));
$bad_rc != 0 && !$bad_sig
   or die "split-parameter ABI mismatch unexpectedly linked\n$bad_out\n$bad_err";
$bad_err =~ /ABI\/type fingerprint mismatch for function symbol 'mismatch' parameter 0/s
   or die "split-parameter ABI mismatch did not identify the parameter\n$bad_err";
$bad_err =~ /region=banana/ && $bad_err =~ /region=pair/
   or die "split-parameter ABI mismatch omitted the conflicting regions\n$bad_err";

print "Generic split-address value parameters passed\n";
