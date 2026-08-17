#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: Return-local coalescing passed
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
my $cfg = File::Spec->catfile($tmp, 'return-coalesce.cfg');
my $source = File::Spec->catfile($tmp, 'return-coalesce.c26');
my $hex = File::Spec->catfile($tmp, 'return-coalesce.hex');
my $map_path = File::Spec->catfile($tmp, 'return-coalesce.map');
my $sym_path = File::Spec->catfile($tmp, 'return-coalesce.sym');

write_file($cfg, <<'CFG');
MEMORY {
    ZEROPAGE: start = $0000, size = $0100, type = rw, define = yes;
    CPUSTACK: start = $0100, size = $0100, type = rw, define = yes;
    RAM:      start = $0200, size = $1E00, type = rw, define = yes;
    result_ram: start = $2200, size = $0020, type = rw, define = yes;
    cartram: read_start = $3003, write_start = $5007, size = $0040, type = rw, define = yes;
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
mem result_ram { $start:0x2200 $size:0x0020 $rw };
mem cartram { $read_start:0x3003 $write_start:0x5007 $size:0x0040 $rw };

uint8_t selector;
uint8_t status;

zeropage uint8_t value8(void) {
   zeropage uint8_t result8 := 0x5a;
   return result8;
}
zeropage uint16_t value16(void) {
   zeropage uint16_t result16 := 0x1234;
   return result16;
}
zeropage uint24_t value24(void) {
   zeropage uint24_t result24 := 0x345678;
   return result24;
}
zeropage uint32_t value32(void) {
   zeropage uint32_t result32 := 0x12345678;
   return result32;
}
zeropage bcd8_t bcd8_value(void) {
   zeropage bcd8_t result_bcd8 := 42;
   return result_bcd8;
}
zeropage bcd16_t bcd16_value(void) {
   zeropage bcd16_t result_bcd16 := 1234;
   return result_bcd16;
}
zeropage bcd24_t bcd24_value(void) {
   zeropage bcd24_t result_bcd24 := 123456;
   return result_bcd24;
}
zeropage bcd32_t bcd32_value(void) {
   zeropage bcd32_t result_bcd32 := 12345678;
   return result_bcd32;
}
result_ram uint16_t absolute_value(void) {
   result_ram uint16_t absolute_result := 0xbeef;
   return absolute_result;
}
zeropage uint16_t branched_value(void) {
   zeropage uint16_t branch_result := 0x1111;
   if (selector) {
      branch_result := 0xabcd;
      return branch_result;
   }
   branch_result := 0x2345;
   return branch_result;
}
cartram uint32_t split_value(void) {
   cartram uint32_t split_result := 0x12345678;
   split_result += 1;
   return split_result;
}

void simulator_done(void) { while (1) {} }
void fail(uint8_t code) {
   status := code;
   asm jmp simulator_done;
}
void main(void) {
   if (value8() != 0x5a) { fail(1); }
   if (value16() != 0x1234) { fail(2); }
   if (value24() != 0x345678) { fail(3); }
   if (value32() != 0x12345678) { fail(4); }
   if (bcd8_value() != 42) { fail(5); }
   if (bcd16_value() != 1234) { fail(6); }
   if (bcd24_value() != 123456) { fail(7); }
   if (bcd32_value() != 12345678) { fail(8); }
   if (absolute_value() != 0xbeef) { fail(9); }
   selector := 0;
   if (branched_value() != 0x2345) { fail(10); }
   selector := 1;
   if (branched_value() != 0xabcd) { fail(11); }
   if (split_value() != 0x12345679) { fail(12); }
   status := 0xaa;
   asm jmp simulator_done;
}
SOURCE

require_ok('build return-local coalescing fixture',
   $driver, '-I', $test_inc, '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $cfg, '-Map', $map_path, '-Sym', $sym_path,
   $source, '-o', $hex);

my $map = read_file($map_path);
my @entries = (
   ['value8', 'result8', 'zeropage', 1],
   ['value16', 'result16', 'zeropage', 2],
   ['value24', 'result24', 'zeropage', 3],
   ['value32', 'result32', 'zeropage', 4],
   ['bcd8_value', 'result_bcd8', 'zeropage', 1],
   ['bcd16_value', 'result_bcd16', 'zeropage', 2],
   ['bcd24_value', 'result_bcd24', 'zeropage', 3],
   ['bcd32_value', 'result_bcd32', 'zeropage', 4],
   ['absolute_value', 'absolute_result', 'result_ram', 2],
   ['branched_value', 'branch_result', 'zeropage', 2],
   ['split_value', 'split_result', 'cartram', 4],
);
for my $entry (@entries) {
   my ($function, $local, $region, $size) = @$entry;
   $map =~ /^\s*function=\Q$function\E local=\Q$local\E return=\Q$function\E\$__return region=\Q$region\E read=\$[0-9A-F]{4} write=\$[0-9A-F]{4} bytes=\Q$size\E object=/m
      or die "map is missing return coalescing for $function/$local\n$map";
   my $hexsize = sprintf('%04X', $size);
   if ($region eq 'zeropage') {
      $map =~ /^\s*ZEROPAGE\.zeropage\.__vcsc_activation\$\Q$function\E run=\$[0-9A-F]{4} size=\$$hexsize\b/m
         or die "coalesced activation for $function is not exactly $size bytes\n$map";
   }
   elsif ($region eq 'cartram') {
      $map =~ /^\s*BSS\.cartram\.__vcsc_activation\$\Q$function\E run=\$3003 write=\$5007 size=\$$hexsize\b/m
         or die "split coalesced activation for $function is not exactly $size bytes\n$map";
   }
   else {
      $map =~ /^\s*BSS\.result_ram\.__vcsc_activation\$\Q$function\E run=\$2200 size=\$$hexsize\b/m
         or die "absolute coalesced activation for $function is not exactly $size bytes\n$map";
   }
}
$map =~ /\nRETURN COALESCING\n/ or die "map has no RETURN COALESCING section\n$map";

my $sym = read_file($sym_path);
my $done = parse_symbol($sym, 'simulator_done');
my $status = parse_symbol($sym, 'status');
for my $entry (@entries) {
   parse_symbol($sym, "$entry->[0]\$__return");
}
parse_symbol($sym, 'split_value$__return') == 0x3003
   or die "split return symbol was not allocated at the read alias\n";

my ($dump, $sim_err) = require_ok('simulate return-local coalescing fixture',
   $sim, '-T', $cfg, sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $hex);
$sim_err eq '' or die "return-local coalescing simulator wrote stderr:\n$sim_err";
my $mem = parse_dump($dump);
$mem->[$status] == 0xaa
   or die sprintf("return-local coalescing status is %02X, expected AA\n", $mem->[$status]);
my @split_bytes = (0x79, 0x56, 0x34, 0x12);
for my $offset (0 .. $#split_bytes) {
   $mem->[0x3003 + $offset] == $split_bytes[$offset]
      or die sprintf("split read alias %04X is %02X, expected %02X\n",
                     0x3003 + $offset, $mem->[0x3003 + $offset], $split_bytes[$offset]);
   $mem->[0x5007 + $offset] == $split_bytes[$offset]
      or die sprintf("split write alias %04X is %02X, expected %02X\n",
                     0x5007 + $offset, $mem->[0x5007 + $offset], $split_bytes[$offset]);
}

print "Return-local coalescing passed\n";
