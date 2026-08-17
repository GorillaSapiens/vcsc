#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Superchip automatic locals passed for F8SC, F6SC, and F4SC
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
include "superchip.c26"

mem bank0 { $start:0xF100 $size:0x0E00 $ro };
mem bank1 { $start:0xD100 $size:0x0E00 $ro };

struct Packed { uint8_t low:4; uint8_t high:4; };
uint8_t result;
void simulator_done(void) { while (true) {} }

inline uint8_t inline_bump(uint8_t seed) {
   cartram uint8_t inline_local := seed;
   inline_local += 2;
   return inline_local;
}

bank1 void visit(void) {
   cartram uint16_t word := 0x1234;
   cartram uint8_t values[2] := { 5, 6 };
   word += values[1];
   word++;
   values[0]++;
   if (word != 0x123b || values[0] != 6 || values[1] != 6) { result := 0xe1; }
}

void main(void) {
   cartram uint8_t scalar := 3;
   cartram uint8_t array[4] := { 1, 2, 3, 4 };
   cartram Packed bits;
   uint8_t index := 2;
   scalar += array[index];
   scalar++;
   bits.low := scalar;
   bits.high := bits.low + 1;
   scalar := inline_bump(scalar);
   visit();
   visit();
   if (scalar != 9 || array[0] != 1 || array[1] != 2 ||
       array[2] != 3 || array[3] != 4 || bits.low != 7 || bits.high != 8) {
      result := 0xe2;
   }
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
   ['F8SC', 2, 'vcs_8k_f8sc.cfg'],
   ['F6SC', 4, 'vcs_16k_f6sc.cfg'],
   ['F4SC', 8, 'vcs_32k_f4sc.cfg'],
);

for my $profile (@profiles) {
   my ($mapper, $banks, $cfg_name) = @$profile;
   my $stem = lc($mapper) . '_locals';
   my $src = File::Spec->catfile($tmp, "$stem.c26");
   my $bin = File::Spec->catfile($tmp, "$stem.bin");
   my $map_path = File::Spec->catfile($tmp, "$stem.map");
   my $sym_path = File::Spec->catfile($tmp, "$stem.sym");
   my $cfg = File::Spec->catfile($vcs, $cfg_name);
   write_file($src, $source);
   require_ok("build $mapper Superchip-local test",
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', $cfg, '-Map', $map_path, '-Sym', $sym_path, $src, '-o', $bin);
   -s $bin == $banks * 4096 or die "$mapper output has wrong size\n";

   my $map = read_file($map_path);
   $map =~ /^\s*cartram\s+used=11 bytes\b.*\bobjects=11 bytes\b/m
      or die "$mapper map does not count 11 physical local bytes exactly once\n";
   $map =~ /^\s*BSS\.cartram\.__vcsc_activation\$main run=\$F080 write=\$F000 size=\$0007\b/m
      or die "$mapper map lost the seven-byte main Superchip activation\n";
   $map =~ /^\s*BSS\.cartram\.__vcsc_activation\$visit run=\$F087 write=\$F007 size=\$0004\b/m
      or die "$mapper map lost the four-byte visit Superchip activation\n";

   my $sym = read_file($sym_path);
   my $done = parse_symbol($sym, 'simulator_done');
   my $result = parse_symbol($sym, 'result');
   for my $physical_start (0 .. $banks - 1) {
      my ($dump, $err) = require_ok("simulate $mapper from physical bank $physical_start",
         $sim, '-T', $cfg, "--start-bank=$physical_start",
         sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $bin);
      $err eq '' or die "$mapper simulator wrote stderr:\n$err";
      my $mem = parse_dump($dump);
      $mem->[$result] == 0xaa
         or die sprintf("%s start bank %d result is %02X, expected AA\n", $mapper, $physical_start, $mem->[$result]);
      my @expected = (9, 1, 2, 3, 4, 0x87, 9, 0x3b, 0x12, 6, 6);
      for my $offset (0 .. $#expected) {
         $mem->[0xF080 + $offset] == $expected[$offset]
            or die sprintf("%s local byte %d is %02X, expected %02X\n", $mapper, $offset,
                           $mem->[0xF080 + $offset], $expected[$offset]);
         $mem->[0xF000 + $offset] == $mem->[0xF080 + $offset]
            or die "$mapper Superchip aliases disagree at local offset $offset\n";
      }
   }
}

my $overflow_src = File::Spec->catfile($tmp, 'superchip_local_overflow.c26');
write_file($overflow_src, <<'OVERFLOW');
include "vcs.c26"
include "superchip.c26"
void main(void) {
   cartram uint8_t fits[128];
   cartram uint8_t spill;
   while (true) {}
}
OVERFLOW
for my $attempt (1 .. 2) {
   my ($rc, $sig, $out, $err) = run_capture(
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', File::Spec->catfile($vcs, 'vcs_8k_f8sc.cfg'),
      $overflow_src, '-o', File::Spec->catfile($tmp, "superchip_local_overflow_$attempt.bin"));
   $rc != 0 && !$sig or die "Superchip local overflow attempt $attempt unexpectedly linked\n$out\n$err";
   $err =~ /cartram overflow while placing activation overlay from <call graph> in cartram/
      or die "Superchip local overflow attempt $attempt was not deterministic\n$err";
}

print "Superchip automatic locals passed for F8SC, F6SC, and F4SC\n";
