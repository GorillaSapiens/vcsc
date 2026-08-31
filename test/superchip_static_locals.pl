#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Function-scope static Superchip locals passed for F8SC, F6SC, and F4SC
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
   $rc == 0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
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
   $sym =~ /^\Q$name\E\s+([0-9A-Fa-f]{4})\s*$/m or die "symbol file is missing $name\n";
   return hex($1);
}
sub parse_dump {
   my ($text) = @_;
   my @mem = (0) x 65536;
   for my $line (split /\n/, $text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my ($count, $addr, $bytes) = (hex($1), hex($2), $3);
      length($bytes) == $count * 2 or die "bad Intel HEX dump record\n";
      for my $i (0 .. $count - 1) { $mem[$addr + $i] = hex(substr($bytes, $i * 2, 2)); }
   }
   return \@mem;
}

my $source = <<'SOURCE';
include "vcs.c26"
include "4KSC/ram.c26"

mem bank0 { $start:0xF100 $size:0x0E00 $ro };
mem bank1 { $start:0xD100 $size:0x0E00 $ro };

struct Packed { uint8_t low:4; uint8_t high:4; };
uint8_t result;
void simulator_done(void) { while (true) {} }

uint8_t runtime_seed(void) { return 0x20; }

bank1 uint8_t next_value(void) {
   static cartram uint8_t zero;
   static cartram uint8_t fixed := 4;
   static cartram uint8_t runtime := runtime_seed();
   static cartram uint8_t values[2] := { 9, 10 };
   static cartram Packed bits;

   zero++;
   fixed += 2;
   runtime++;
   values[0]++;
   bits.low++;
   bits.high := bits.low + 1;
   return zero + fixed + runtime + values[0] + values[1] + bits.low + bits.high;
}

void main(void) {
   uint8_t first := next_value();
   uint8_t second := next_value();
   if (first != 0x3f || second != 0x46) { result := 0xe1; }
   if (result == 0) { result := 0xaa; }
   asm jmp simulator_done;
}
SOURCE

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $sim = File::Spec->catfile($repo, 'simulator', 'vcsc-sim');
my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');
my @profiles = (
   ['F8SC', 2, 'F8SC/mapper.cfg'],
   ['F6SC', 4, 'F6SC/mapper.cfg'],
   ['F4SC', 8, 'F4SC/mapper.cfg'],
);

for my $profile (@profiles) {
   my ($mapper, $banks, $cfg_name) = @$profile;
   my $stem = lc($mapper) . '_static_locals';
   my $src = File::Spec->catfile($tmp, "$stem.c26");
   my $bin = File::Spec->catfile($tmp, "$stem.bin");
   my $map_path = File::Spec->catfile($tmp, "$stem.map");
   my $sym_path = File::Spec->catfile($tmp, "$stem.sym");
   my $cfg = File::Spec->catfile($vcs, $cfg_name);
   write_file($src, $source);
   require_ok("build $mapper static-Superchip-local test",
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', $cfg, '-Map', $map_path, '-Sym', $sym_path, $src, '-o', $bin);
   -s $bin == $banks * 4096 or die "$mapper output has wrong size\n";

   my $map = read_file($map_path);
   $map =~ /^\s*cartram\s+used=6 bytes\b.*\bobjects=6 bytes\b/m
      or die "$mapper map does not count six persistent static-local bytes exactly once\n";
   $map =~ /^\s*BSS\.cartram\s+run=\$F080 write=\$F000 size=\$0003\b/m
      or die "$mapper map lost the three-byte static-local BSS allocation\n";
   $map =~ /^\s*DATA\.cartram\s+load=\$[0-9A-F]{4} run=\$F083 write=\$F003 size=\$0003\b/m
      or die "$mapper map lost the three-byte static-local DATA allocation\n";
   $map !~ /BSS\.cartram\.__vcsc_activation\$next_value/
      or die "$mapper incorrectly placed static Superchip locals in an activation overlay\n";

   my $sym = read_file($sym_path);
   my $done = parse_symbol($sym, 'simulator_done');
   my $result = parse_symbol($sym, 'result');
   for my $physical_start (0 .. $banks - 1) {
      my ($dump, $err) = require_ok("simulate $mapper static locals from physical bank $physical_start",
         $sim, '-T', $cfg, "--start-bank=$physical_start",
         sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $bin);
      $err eq '' or die "$mapper simulator wrote stderr:\n$err";
      my $mem = parse_dump($dump);
      $mem->[$result] == 0xaa
         or die sprintf("%s start bank %d result is %02X, expected AA\n", $mapper, $physical_start, $mem->[$result]);
      my @expected = (2, 0x22, 0x32, 8, 11, 10);
      for my $offset (0 .. $#expected) {
         $mem->[0xF080 + $offset] == $expected[$offset]
            or die sprintf("%s static byte %d is %02X, expected %02X\n", $mapper, $offset,
                           $mem->[0xF080 + $offset], $expected[$offset]);
         $mem->[0xF000 + $offset] == $mem->[0xF080 + $offset]
            or die "$mapper Superchip aliases disagree at static-local offset $offset\n";
      }
   }
}

print "Function-scope static Superchip locals passed for F8SC, F6SC, and F4SC\n";
