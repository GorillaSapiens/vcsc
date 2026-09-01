#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: Superchip function returns passed for F8SC, F6SC, and F4SC
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
include "__MAPPER__/mapper.c26"

uint8_t result;
void simulator_done(void) { while (true) {} }

cartram uint8_t r8(void) {
   return 0xa5;
}
cartram uint16_t r16(void) {
   $$ := 0x1233;
   if ($$ != 0x1233) { return 0; }
   $$ += 1;
   return;
}
cartram uint24_t r24(void) {
   return 0x345678;
}
cartram uint32_t r32(void) {
   $$ := 0x12345677;
   $$ += 1;
   return;
}
cartram bcd8_t br8(void) {
   return 98;
}
cartram bcd16_t br16(void) {
   $$ := 1233;
   if ($$ != 1233) { return 0; }
   $$ += 1;
   return;
}
cartram bcd24_t br24(void) {
   return 345678;
}
cartram bcd32_t br32(void) {
   $$ := 12345677;
   $$ += 1;
   return;
}

void check_same_bank(void) {
   if (r8() != 0xa5 || r16() != 0x1234 || r24() != 0x345678 ||
       r32() != 0x12345678 || br8() != 98 || br16() != 1234 ||
       br24() != 345678 || br32() != 12345678) {
      result := 0xe1;
   }
}

bank1 void check_cross_bank(void) {
   if (r8() != 0xa5 || r16() != 0x1234 || r24() != 0x345678 ||
       r32() != 0x12345678 || br8() != 98 || br16() != 1234 ||
       br24() != 345678 || br32() != 12345678) {
      result := 0xe2;
   }
}

void main(void) {
   check_same_bank();
   check_cross_bank();
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
   ['F8SC', 2],
   ['F6SC', 4],
   ['F4SC', 8],
);

for my $profile (@profiles) {
   my ($mapper, $banks) = @$profile;
   my $stem = lc($mapper) . '_returns';
   my $src = File::Spec->catfile($tmp, "$stem.c26");
   my $bin = File::Spec->catfile($tmp, "$stem.bin");
   my $map_path = File::Spec->catfile($tmp, "$stem.map");
   my $sym_path = File::Spec->catfile($tmp, "$stem.sym");
   my $profile_source = $source;
   $profile_source =~ s/__MAPPER__/$mapper/g;
   write_file($src, $profile_source);
   require_ok("build $mapper Superchip-return test",
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-Map', $map_path, '-Sym', $sym_path,
      $src, '-o', $bin);
   -s $bin == $banks * 4096 or die "$mapper output has wrong size\n";

   my $map = read_file($map_path);
   $map =~ /^\s*cartram\s+used=4 bytes\b.*\bobjects=4 bytes\b/m
      or die "$mapper map does not count four physical return bytes exactly once\n$map";
   for my $item (
      ['r8', 1], ['r16', 2], ['r24', 3], ['r32', 4],
      ['br8', 1], ['br16', 2], ['br24', 3], ['br32', 4]) {
      my ($name, $size) = @$item;
      $map =~ /^\s*BSS\.cartram\.__vcsc_activation\$\Q$name\E run=\$F080 write=\$F000 size=\$@{[sprintf('%04X', $size)]}\b/m
         or die "$mapper map lost exact $name return storage\n$map";
      $map =~ /^\s*JSR entry=.*CODE(?:\.[^ ]+)?\.__vcsc_function\$\Q$name\E source=([^ ]+).* destination=([^ ]+)/m
         or die "$mapper map did not generate a cross-bank call for $name\n$map";
      $1 ne $2 or die "$mapper recorded a non-cross-bank trampoline for $name\n$map";
   }

   my $sym = read_file($sym_path);
   my $done = parse_symbol($sym, 'simulator_done');
   my $result = parse_symbol($sym, 'result');
   for my $name (qw(r8 r16 r24 r32 br8 br16 br24 br32)) {
      parse_symbol($sym, $name . '$__return') == 0xF080
         or die "$mapper $name return symbol was not placed at the read alias\n";
   }

   for my $physical_start (0 .. $banks - 1) {
      my ($dump, $err) = require_ok("simulate $mapper from physical bank $physical_start",
         $sim, '--map', $map_path, "--start-bank=$physical_start",
         sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $bin);
      $err eq '' or die "$mapper simulator wrote stderr:\n$err";
      my $mem = parse_dump($dump);
      $mem->[$result] == 0xaa
         or die sprintf("%s start bank %d result is %02X, expected AA\n",
                        $mapper, $physical_start, $mem->[$result]);
      my @expected = (0x78, 0x56, 0x34, 0x12);
      for my $offset (0 .. $#expected) {
         $mem->[0xF080 + $offset] == $expected[$offset]
            or die sprintf("%s return byte %d is %02X, expected %02X\n",
                           $mapper, $offset, $mem->[0xF080 + $offset],
                           $expected[$offset]);
         $mem->[0xF000 + $offset] == $expected[$offset]
            or die "$mapper Superchip aliases disagree at return offset $offset\n";
      }
   }
}

# Thirty-three simultaneously live four-byte result objects need 132 bytes,
# which must overflow the 128-byte Superchip region deterministically.
my $overflow_src = File::Spec->catfile($tmp, 'superchip_return_overflow.c26');
my $overflow_text = "include \"F8SC/mapper.c26\"\n";
$overflow_text .= "cartram uint32_t f32(void) { return 1; }\n";
for my $i (reverse 0 .. 31) {
   my $next = $i + 1;
   $overflow_text .= "cartram uint32_t f$i(void) { return f$next(); }\n";
}
$overflow_text .= "void main(void) { uint32_t v := f0(); while (true) {} }\n";
write_file($overflow_src, $overflow_text);
for my $attempt (1 .. 2) {
   my ($rc, $sig, $out, $err) = run_capture(
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM',
      $overflow_src, '-o', File::Spec->catfile($tmp, "return_overflow_$attempt.bin"));
   $rc != 0 && !$sig
      or die "Superchip return overflow attempt $attempt unexpectedly linked\n$out\n$err";
   $err =~ /cartram overflow while placing activation overlay from <call graph> in cartram/
      or die "Superchip return overflow attempt $attempt was not deterministic\n$err";
}

print "Superchip function returns passed for F8SC, F6SC, and F4SC\n";
