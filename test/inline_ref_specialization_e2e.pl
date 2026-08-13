#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Inline ref specialization E2E passed
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
sub function_load_size {
   my ($map, $name) = @_;
   $map =~ /^\s*CODE\.__vcsc_function\$\Q$name\E\s+load=\$([0-9A-Fa-f]{4})\s+size=\$([0-9A-Fa-f]{4})\b/m
      or die "map is missing code placement for $name\n$map";
   return (hex($1), hex($2));
}

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $sim = File::Spec->catfile($repo, 'simulator', 'vcsc-sim');
my $test_inc = File::Spec->catdir($repo, 'test');
my $cfg = File::Spec->catfile($tmp, 'inline-ref.cfg');
my $source = File::Spec->catfile($tmp, 'inline-ref.c26');
my $hex = File::Spec->catfile($tmp, 'inline-ref.hex');
my $map_path = File::Spec->catfile($tmp, 'inline-ref.map');
my $sym_path = File::Spec->catfile($tmp, 'inline-ref.sym');

write_file($cfg, <<'CFG');
MEMORY {
    ZEROPAGE: start = $0000, size = $0100, type = rw, define = yes;
    CPUSTACK: start = $0100, size = $0100, type = rw, define = yes;
    RAM:      start = $0200, size = $1E00, type = rw, define = yes;
    splitram: read_start = $3003, write_start = $5007, size = $0001, type = rw, define = yes;
    ROM:      start = $8000, size = $8000, type = ro, define = yes;
}
SEGMENTS {
    ZEROPAGE: load = ROM, run = ZEROPAGE, type = zp, define = yes;
    CODE:     load = ROM,                 type = ro, define = yes;
    RODATA:   load = ROM,                 type = ro, define = yes;
    BSS:      load = RAM,                 type = bss, define = yes;
    DATA:     load = ROM, run = RAM,      type = data, define = yes;
}
CFG

write_file($source, <<'SOURCE');
include "machine_6502.c26"
mem rom { $start:0x8000 $size:0x8000 $ro $priority:1 };
mem splitram { $read_start:0x3003 $write_start:0x5007 $size:0x0001 $rw };

uint8_t target;
uint8_t chain_target;
uint8_t mixed_target;
zeropage uint8_t zptarget;
splitram uint8_t split_target;
uint8_t values[4];
uint8_t index;
uint8_t status;

static void specialized(ref uint8_t value) { value++; }
static void specialized_zp(ref uint8_t value) { value++; }
static void specialized_split(ref uint8_t value) { value++; }
static void fallback(ref uint8_t value) { value++; }
static void chain_leaf(ref uint8_t value) { value++; }
static void chain_middle(ref uint8_t value) { chain_leaf(value); }
static void specialized_mixed(uint8_t add1, ref uint8_t value, uint8_t add2) {
   value += add1;
   value += add2;
}
static void fallback_mixed(uint8_t add1, ref uint8_t value, uint8_t add2) {
   value += add1;
   value += add2;
}

void simulator_done(void) { while (1) {} }
void main(void) {
   target := 0x10;
   chain_target := 0x50;
   mixed_target := 0x60;
   zptarget := 0x20;
   split_target := 0x30;
   values[2] := 0x40;
   index := 2;
   specialized(target);
   specialized_zp(zptarget);
   specialized_split(split_target);
   fallback(values[index]);
   chain_middle(chain_target);
   specialized_mixed(2, mixed_target, 3);
   fallback_mixed(2, values[index], 3);
   if (target != 0x11) { status := 1; asm jmp simulator_done; }
   if (zptarget != 0x21) { status := 2; asm jmp simulator_done; }
   if (split_target != 0x31) { status := 3; asm jmp simulator_done; }
   if (values[2] != 0x46) { status := 4; asm jmp simulator_done; }
   if (chain_target != 0x51) { status := 5; asm jmp simulator_done; }
   if (mixed_target != 0x65) { status := 6; asm jmp simulator_done; }
   status := 0xaa;
   asm jmp simulator_done;
}
SOURCE

require_ok('build inline-ref specialization fixture',
   $driver, '-I', $test_inc, '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $cfg,
   '-Map', $map_path, '-Sym', $sym_path, $source, '-o', $hex);

my $map = read_file($map_path);
for my $name (qw(specialized specialized_zp specialized_split chain_leaf chain_middle)) {
   $map !~ /^\s*(?:BSS|ZEROPAGE)\.[^\n]*__vcsc_activation\$\Q$name\E\b/m
      or die "specialized function $name unexpectedly owns activation RAM\n$map";
}
$map =~ /^\s*BSS\.__vcsc_activation\$fallback\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0002\b/m
   or die "runtime-index fallback did not retain its two-byte ref slot\n$map";
$map =~ /^\s*BSS\.__vcsc_activation\$specialized_mixed\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0003\b/m
   or die "specialized mixed-parameter function has unexpected activation size\n$map";
$map =~ /^\s*BSS\.__vcsc_activation\$fallback_mixed\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0005\b/m
   or die "fallback mixed-parameter function should be exactly two bytes larger for its ref slot\n$map";

my $sym = read_file($sym_path);
my $zp = parse_symbol($sym, 'zptarget');
my ($zp_fn, $zp_size) = function_load_size($map, 'specialized_zp');
$zp_size == 8 or die "specialized_zp size is $zp_size, expected 8-byte zero-page body\n";
my $image = parse_dump(read_file($hex));
my @want_zp = (0xA5, $zp, 0x18, 0x69, 0x01, 0x85, $zp, 0x60);
for my $i (0 .. $#want_zp) {
   $image->[$zp_fn + $i] == $want_zp[$i]
      or die sprintf("specialized_zp byte %d is %02X, expected %02X\n",
                     $i, $image->[$zp_fn + $i], $want_zp[$i]);
}
my ($split_fn, $split_size) = function_load_size($map, 'specialized_split');
$split_size == 10 or die "specialized_split size is $split_size, expected 10-byte direct split body\n";
my @want_split = (0xAD, 0x03, 0x30, 0x18, 0x69, 0x01, 0x8D, 0x07, 0x50, 0x60);
for my $i (0 .. $#want_split) {
   $image->[$split_fn + $i] == $want_split[$i]
      or die sprintf("specialized_split byte %d is %02X, expected %02X\n",
                     $i, $image->[$split_fn + $i], $want_split[$i]);
}

my $done = parse_symbol($sym, 'simulator_done');
my $status_addr = parse_symbol($sym, 'status');
my ($dump, $sim_err) = require_ok('simulate inline-ref specialization fixture',
   $sim, '-T', $cfg, sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $hex);
$sim_err eq '' or die "inline-ref simulator wrote stderr:\n$sim_err";
my $mem = parse_dump($dump);
$mem->[$status_addr] == 0xaa
   or die sprintf("inline-ref status is %02X, expected AA\n", $mem->[$status_addr]);
$mem->[0x3003] == 0x31 && $mem->[0x5007] == 0x31
   or die sprintf("split specialized ref read/write aliases are %02X/%02X, expected 31/31\n",
                  $mem->[0x3003], $mem->[0x5007]);

print "Inline ref specialization E2E passed\n";
