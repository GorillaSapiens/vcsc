#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: Superchip value parameters passed for F8SC, F6SC, and F4SC
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

my $source = <<'SOURCE';
include "vcs.c26"
include "4KSC/ram.c26"

mem bank0 { $start:0xF100 $size:0x0E00 $ro };
mem bank1 { $start:0xD100 $size:0x0E00 $ro };

uint8_t result;
void simulator_done(void) { while (true) {} }
uint16_t make16(void) { return 0x1234; }
bcd32_t make_bcd32(void) { return 12345678; }

bank1 void consume(cartram uint8_t a,
                   cartram uint16_t b,
                   cartram uint24_t c,
                   cartram uint32_t d,
                   cartram bcd8_t e,
                   cartram bcd16_t f,
                   cartram bcd24_t g,
                   cartram bcd32_t h) {
   if (a != 5 || b != 0x1234 || c != 0x345678 || d != 0x12345678 ||
       e != 98 || f != 1234 || g != 345678 || h != 12345678) {
      result := 0xe1;
   }
   a += 1;
   b += 1;
   c += 1;
   d += 1;
   e += 1;
   f += 1;
   g += 1;
   h += 1;
   if (a != 6 || b != 0x1235 || c != 0x345679 || d != 0x12345679 ||
       e != 99 || f != 1235 || g != 345679 || h != 12345679) {
      result := 0xe2;
   }
}

inline uint8_t bump(cartram uint8_t value) {
   value += 2;
   return value;
}

bank1 void inner(cartram uint16_t value) {
   value += 3;
   if (value != 0x2004) { result := 0xe3; }
}

void outer(cartram uint16_t value) {
   inner(value);
   value += 2;
   if (value != 0x2003) { result := 0xe4; }
}

void main(void) {
   consume(5, make16(), 0x345678, 0x12345678,
           98, 1234, 345678, make_bcd32());
   outer(0x2001);
   if (bump(7) != 9) { result := 0xe5; }
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
   my $stem = lc($mapper) . '_parameters';
   my $src = File::Spec->catfile($tmp, "$stem.c26");
   my $bin = File::Spec->catfile($tmp, "$stem.bin");
   my $map_path = File::Spec->catfile($tmp, "$stem.map");
   my $sym_path = File::Spec->catfile($tmp, "$stem.sym");
   my $cfg = File::Spec->catfile($vcs, $cfg_name);
   write_file($src, $source);
   require_ok("build $mapper Superchip-parameter test",
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', $cfg, '-Map', $map_path, '-Sym', $sym_path,
      $src, '-o', $bin);
   -s $bin == $banks * 4096 or die "$mapper output has wrong size\n";

   my $map = read_file($map_path);
   $map =~ /^\s*cartram\s+used=21 bytes\b.*\bobjects=21 bytes\b/m
      or die "$mapper map does not count 21 physical parameter bytes exactly once\n$map";
   $map =~ /^\s*BSS\.cartram\.__vcsc_activation\$main run=\$F080 write=\$F000 size=\$0001\b/m
      or die "$mapper map lost the inline parameter in main's activation\n";
   $map =~ /^\s*BSS\.cartram\.__vcsc_activation\$consume run=\$F081 write=\$F001 size=\$0014\b/m
      or die "$mapper map lost the twenty-byte consume parameter object\n";
   $map =~ /^\s*BSS\.cartram\.__vcsc_activation\$outer run=\$F081 write=\$F001 size=\$0002\b/m
      or die "$mapper map lost outer's overlaid parameter object\n";
   $map =~ /^\s*BSS\.cartram\.__vcsc_activation\$inner run=\$F083 write=\$F003 size=\$0002\b/m
      or die "$mapper map overlapped simultaneously live outer/inner parameters\n";

   my $sym = read_file($sym_path);
   my $done = parse_symbol($sym, 'simulator_done');
   my $result = parse_symbol($sym, 'result');
   my @expected = (0x09,
                   0x03, 0x20,
                   0x04, 0x20,
                   0x56, 0x34,
                   0x79, 0x56, 0x34, 0x12,
                   0x99,
                   0x35, 0x12,
                   0x79, 0x56, 0x34,
                   0x79, 0x56, 0x34, 0x12);
   for my $physical_start (0 .. $banks - 1) {
      my ($dump, $err) = require_ok("simulate $mapper from physical bank $physical_start",
         $sim, '-T', $cfg, "--start-bank=$physical_start",
         sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $bin);
      $err eq '' or die "$mapper simulator wrote stderr:\n$err";
      my $mem = parse_dump($dump);
      $mem->[$result] == 0xaa
         or die sprintf("%s start bank %d result is %02X, expected AA\n",
                        $mapper, $physical_start, $mem->[$result]);
      for my $offset (0 .. $#expected) {
         $mem->[0xF080 + $offset] == $expected[$offset]
            or die sprintf("%s parameter byte %d is %02X, expected %02X\n",
                           $mapper, $offset, $mem->[0xF080 + $offset],
                           $expected[$offset]);
         $mem->[0xF000 + $offset] == $mem->[0xF080 + $offset]
            or die "$mapper Superchip aliases disagree at parameter offset $offset\n";
      }
   }
}

# A single callee activation larger than the selected split window must fail
# deterministically. Thirty-three four-byte value parameters require 132 bytes.
my $overflow_src = File::Spec->catfile($tmp, 'superchip_parameter_overflow.c26');
my @params = map { "cartram uint32_t p$_" } 0 .. 32;
my @args = (0) x 33;
write_file($overflow_src,
   "include \"vcs.c26\"\ninclude \"4KSC/ram.c26\"\n" .
   "void too_many(" . join(', ', @params) . ") { while (true) {} }\n" .
   "void main(void) { too_many(" . join(', ', @args) . "); while (true) {} }\n");
for my $attempt (1 .. 2) {
   my ($rc, $sig, $out, $err) = run_capture(
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', File::Spec->catfile($vcs, 'F8SC/mapper.cfg'),
      $overflow_src, '-o', File::Spec->catfile($tmp, "parameter_overflow_$attempt.bin"));
   $rc != 0 && !$sig
      or die "Superchip parameter overflow attempt $attempt unexpectedly linked\n$out\n$err";
   $err =~ /cartram overflow while placing activation overlay from <call graph> in cartram/
      or die "Superchip parameter overflow attempt $attempt was not deterministic\n$err";
}

print "Superchip value parameters passed for F8SC, F6SC, and F4SC\n";
