#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Generic split-address fruit regions passed
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
sub check_alias_bytes {
   my ($mem, $name, $read_start, $write_start, $expected) = @_;
   for my $offset (0 .. $#$expected) {
      my $want = $expected->[$offset];
      my $got_read = $mem->[$read_start + $offset];
      my $got_write = $mem->[$write_start + $offset];
      $got_read == $want
         or die sprintf("%s read byte %d is %02X, expected %02X\n",
                        $name, $offset, $got_read, $want);
      $got_write == $want
         or die sprintf("%s write byte %d is %02X, expected %02X\n",
                        $name, $offset, $got_write, $want);
   }
}

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $sim = File::Spec->catfile($repo, 'simulator', 'vcsc-sim');
my $test_inc = File::Spec->catdir($repo, 'test');
my $cfg = File::Spec->catfile($tmp, 'fruit_split.cfg');
my $src = File::Spec->catfile($tmp, 'fruit_split.c26');
my $hex = File::Spec->catfile($tmp, 'fruit_split.hex');
my $map_path = File::Spec->catfile($tmp, 'fruit_split.map');
my $sym_path = File::Spec->catfile($tmp, 'fruit_split.sym');
my $asm_path = File::Spec->catfile($tmp, 'fruit_split.s26');

write_file($cfg, <<'CFG');
MEMORY {
    ZEROPAGE: start = $0000, size = $0100, type = rw, define = yes;
    CPUSTACK: start = $0100, size = $0100, type = rw, define = yes;
    RAM:      start = $0200, size = $1E00, type = rw, define = yes;

    # Different names, sizes, alignments, ordering, and spacing are deliberate.
    banana: read_start = $3003, write_start = $5007, size = $0007, type = rw, define = yes;
    pair:   read_start = $6205, write_start = $2201, size = $0009, type = rw, define = yes;
    orange: read_start = $7102, write_start = $4A11, size = $0005, type = rw, define = yes;

    ROM:      start = $8000, size = $8000, type = ro, define = yes;
}

SEGMENTS {
    ZEROPAGE: load = ROM, run = ZEROPAGE, type = zp,   define = yes;
    CODE:     load = ROM,                 type = ro,   define = yes;
    RODATA:   load = ROM,                 type = ro,   define = yes;
    BSS:      load = RAM,                 type = bss,  define = yes;
    DATA:     load = ROM, run = RAM,      type = data, define = yes;
}
CFG

write_file($src, <<'SOURCE');
include "machine_6502.c26"

mem rom { $start:0x8000 $size:0x8000 $ro $priority:1 };
mem banana { $read_start:0x3003 $write_start:0x5007 $size:0x0007 $rw };
mem pair   { $read_start:0x6205 $write_start:0x2201 $size:0x0009 $rw };
mem orange { $read_start:0x7102 $write_start:0x4A11 $size:0x0005 $rw };

struct Packed { uint8_t low:4; uint8_t high:4; };

uint8_t result;
banana uint8_t banana_zero;
banana uint8_t banana_data[6] := { 1, 2, 3, 4, 5, 6 };

void simulator_done(void) { while (1) {} }
uint8_t runtime_seed(void) { return 0x20; }

void pair_work(void) {
   pair uint16_t word := 0x1234;
   pair uint8_t values[6] := { 1, 2, 3, 4, 5, 6 };
   pair Packed bits;
   word += values[4];
   word++;
   values[1]++;
   bits.low := values[1];
   bits.high := bits.low + 4;
   if (word != 0x123a || values[1] != 3 || bits.low != 3 || bits.high != 7) {
      result := 0xe1;
   }
}

void orange_work(void) {
   static orange uint8_t zero;
   static orange uint8_t fixed := 4;
   static orange uint8_t runtime := runtime_seed();
   static orange uint8_t values[2] := { 9, 10 };
   zero++;
   fixed += 2;
   runtime++;
   values[0]++;
}

void main(void) {
   if (banana_zero != 0 || banana_data[0] != 1 || banana_data[5] != 6) {
      result := 0xe2;
   }
   banana_zero += banana_data[2];
   banana_zero++;
   banana_data[5]++;

   pair_work();
   pair_work();
   orange_work();
   orange_work();

   if (banana_zero != 4 || banana_data[5] != 7) { result := 0xe3; }
   if (result == 0) { result := 0xaa; }
   asm jmp simulator_done;
}
SOURCE

require_ok('compile generic split-address fruit source',
   File::Spec->catfile($repo, 'compiler', 'vcsc-cc1'), '-quiet', '-I', $test_inc, '-DMACHINE_6502_NO_DEFAULT_ROM',
   $src, '-o', $asm_path);
my $assembly = read_file($asm_path);
for my $metadata (
   '__memmeta$V2$banana$R3003$W5007$Z0007$Trw = 0',
   '__memmeta$V2$pair$R6205$W2201$Z0009$Trw = 0',
   '__memmeta$V2$orange$R7102$W4A11$Z0005$Trw = 0') {
   index($assembly, $metadata) >= 0
      or die "compiler did not emit generic split metadata '$metadata'\n";
}
index($assembly, 'cartram') < 0
   or die "generic fruit source unexpectedly produced a Superchip-named implementation artifact\n";

require_ok('link generic split-address fruit source',
   $driver, '-I', $test_inc, '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $cfg, '-Map', $map_path, '-Sym', $sym_path,
   $src, '-o', $hex);

my $map = read_file($map_path);
for my $line (
   qr/^\s*banana\s+read_start=\$3003 write_start=\$5007 size=\$0007 type=rw shared=yes.*$/m,
   qr/^\s*pair\s+read_start=\$6205 write_start=\$2201 size=\$0009 type=rw shared=yes.*$/m,
   qr/^\s*orange\s+read_start=\$7102 write_start=\$4A11 size=\$0005 type=rw shared=yes.*$/m,
   qr/^\s*banana\s+used=7 bytes\b.*\bobjects=7 bytes\b/m,
   qr/^\s*pair\s+used=9 bytes\b.*\bobjects=9 bytes\b/m,
   qr/^\s*orange\s+used=5 bytes\b.*\bobjects=5 bytes\b/m,
   qr/^\s*BSS\.banana\.__vcsc_object\$banana_zero\s+run=\$3003 write=\$5007 size=\$0001\b/m,
   qr/^\s*DATA\.banana\.__vcsc_object\$banana_data\s+load=\$[0-9A-F]{4} run=\$3004 write=\$5008 size=\$0006\b/m,
   qr/^\s*BSS\.pair\.__vcsc_activation\$pair_work run=\$6205 write=\$2201 size=\$0009\b/m,
   qr/^\s*BSS\.orange\s+run=\$7102 write=\$4A11 size=\$0002\b/m,
   qr/^\s*DATA\.orange\s+load=\$[0-9A-F]{4} run=\$7104 write=\$4A13 size=\$0003\b/m) {
   $map =~ $line or die "generic fruit map is missing expected line $line\n$map";
}

my $sym = read_file($sym_path);
my $done = parse_symbol($sym, 'simulator_done');
my $result = parse_symbol($sym, 'result');
my ($dump, $sim_err) = require_ok('simulate generic split-address fruit source',
   $sim, '-T', $cfg, sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $hex);
$sim_err eq '' or die "generic fruit simulator wrote stderr:\n$sim_err";
my $mem = parse_dump($dump);
$mem->[$result] == 0xaa
   or die sprintf("generic fruit result is %02X, expected AA\n", $mem->[$result]);
check_alias_bytes($mem, 'banana', 0x3003, 0x5007, [4, 1, 2, 3, 4, 5, 7]);
check_alias_bytes($mem, 'pair',   0x6205, 0x2201, [0x3a, 0x12, 1, 3, 3, 4, 5, 6, 0x73]);
check_alias_bytes($mem, 'orange', 0x7102, 0x4A11, [2, 0x22, 8, 11, 10]);

# Exact sizes are contracts, not hints. Each unrelated region must overflow by
# name after one byte beyond its own declared window.
for my $case (
   ['banana', 8, qr/banana overflow .* in banana/s],
   ['pair', 10, qr/pair overflow .* in pair/s],
   ['orange', 6, qr/orange overflow .* in orange/s]) {
   my ($name, $count, $pattern) = @$case;
   my $overflow_src = File::Spec->catfile($tmp, "${name}_overflow.c26");
   my $overflow_hex = File::Spec->catfile($tmp, "${name}_overflow.hex");
   write_file($overflow_src, qq{include "machine_6502.c26"\n}
      . qq{mem banana { \$read_start:0x3003 \$write_start:0x5007 \$size:0x0007 \$rw };\n}
      . qq{mem pair { \$read_start:0x6205 \$write_start:0x2201 \$size:0x0009 \$rw };\n}
      . qq{mem orange { \$read_start:0x7102 \$write_start:0x4A11 \$size:0x0005 \$rw };\n}
      . "$name uint8_t full[$count];\nvoid main(void) { while (1) {} }\n");
   my ($rc, $sig, $out, $err) = run_capture(
      $driver, '-I', $test_inc, '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $cfg, $overflow_src, '-o', $overflow_hex);
   $rc != 0 && !$sig or die "$name overflow unexpectedly linked\n$out\n$err";
   $err =~ $pattern or die "$name overflow did not identify its region\n$err";
}

print "Generic split-address fruit regions passed\n";
