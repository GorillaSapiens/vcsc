#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: automatic Superchip allocation passed for F8SC, F6SC, and F4SC
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

sub source_for_profile {
   my ($banks) = @_;
   my @seed = map { sprintf('0x%02x', 0x10 + $_) } 0 .. 15;
   my $src = <<'HEAD';
include "vcs.c26"
include "superchip.c26"

HEAD
   for my $bank (0 .. $banks - 1) {
      my $start = 0xF100 - $bank * 0x2000;
      $src .= sprintf("mem bank%d { \$start:0x%04X \$size:0x0E00 \$ro };\n", $bank, $start);
   }
   $src .= <<'GLOBALS';

uint8_t result;
uint8_t index;
superchip uint8_t scalar;
superchip uint8_t initialized_scalar := 0x5a;
superchip uint8_t zeroed[16];
GLOBALS
   $src .= 'superchip uint8_t seeded[16] := { ' . join(', ', @seed) . " };\n\n";

   for my $bank (0 .. $banks - 1) {
      my $fail = 0xE0 + $bank;
      my $seed = 0x10 + $bank;
      $src .= sprintf(<<'VISIT', $bank, $bank, $seed, $fail);
bank%d void visit%d(void) {
   if (zeroed[index] != 0 || seeded[index] != 0x%02x) {
      result := 0x%02x;
   }
   seeded[index] += 1;
   zeroed[index] := seeded[index];
}

VISIT
   }

   $src .= "void simulator_done(void) { while (1) {} }\n\nvoid main(void) {\n";
   $src .= "   if (scalar != 0 || initialized_scalar != 0x5a) { result := 0xd0; }\n";
   for my $i (0 .. 15) {
      my $seed = 0x10 + $i;
      $src .= sprintf("   if (zeroed[%d] != 0 || seeded[%d] != 0x%02x) { result := 0xd1; }\n",
                      $i, $i, $seed);
   }
   $src .= "   scalar := initialized_scalar;\n   scalar += 1;\n";
   for my $bank (0 .. $banks - 1) {
      my $expected = 0x11 + $bank;
      $src .= sprintf("   index := %d;\n   visit%d();\n", $bank, $bank);
      $src .= sprintf("   if (zeroed[index] != 0x%02x || seeded[index] != 0x%02x) { result := 0xc%d; }\n",
                      $expected, $expected, $bank);
   }
   $src .= <<'TAIL';
   if (result == 0 && scalar == 0x5b) {
      result := 0xaa;
   }
   asm jmp simulator_done;
}
TAIL
   return $src;
}

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
   my $stem = lc($mapper) . '_allocated';
   my $src = File::Spec->catfile($tmp, "$stem.c26");
   my $bin = File::Spec->catfile($tmp, "$stem.bin");
   my $map_path = File::Spec->catfile($tmp, "$stem.map");
   my $sym_path = File::Spec->catfile($tmp, "$stem.sym");
   my $cfg = File::Spec->catfile($vcs, $cfg_name);
   write_file($src, source_for_profile($banks));
   require_ok("build $mapper allocated Superchip test",
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', $cfg, '-Map', $map_path, '-Sym', $sym_path,
      $src, '-o', $bin);
   -s $bin == $banks * 4096
      or die "$mapper output is not exactly " . ($banks * 4096) . " bytes\n";

   my $map = read_file($map_path);
   $map =~ /^\s*superchip\s+read_start=\$F080 write_start=\$F000 size=\$0080 type=rw shared=yes.*$/m
      or die "$mapper map does not describe the shared split-address region\n";
   $map =~ /^\s*superchip\s+used=34 bytes\b.*\bobjects=34 bytes\b.*\bhardware-stack=0 bytes\s*$/m
      or die "$mapper map does not count the 34 physical Superchip bytes exactly once\n";
   $map =~ /^STARTUP INITIALIZATION\n\s+policy=every-reset bss=zero data=copy-through-write-alias$/m
      or die "$mapper map does not describe the reset-time initialization policy\n";
   for my $required (
      qr/^\s+COPY DATA\.superchip\.__vcsc_object\$initialized_scalar\s+load=\$[0-9A-F]{4} read=\$[0-9A-F]{4} write=\$[0-9A-F]{4} size=\$0001 split=yes$/m,
      qr/^\s+COPY DATA\.superchip\.__vcsc_object\$seeded\s+load=\$[0-9A-F]{4} read=\$[0-9A-F]{4} write=\$[0-9A-F]{4} size=\$0010 split=yes$/m,
      qr/^\s+ZERO BSS\.superchip\.__vcsc_object\$scalar\s+read=\$[0-9A-F]{4} write=\$[0-9A-F]{4} size=\$0001 split=yes$/m,
      qr/^\s+ZERO BSS\.superchip\.__vcsc_object\$zeroed\s+read=\$[0-9A-F]{4} write=\$[0-9A-F]{4} size=\$0010 split=yes$/m,
   ) {
      $map =~ $required
         or die "$mapper map omits a Superchip DATA copy or BSS clear record\n$map";
   }
   my $object_count = 0;
   while ($map =~ /^\s+(?:BSS|DATA)\.superchip\.__vcsc_object\$\S+\s+(?:load=\$[0-9A-F]{4}\s+)?run=\$([0-9A-F]{4}) write=\$([0-9A-F]{4}) size=\$([0-9A-F]{4})\b/mg) {
      my ($read, $write, $size) = (hex($1), hex($2), hex($3));
      $read - $write == 0x80
         or die "$mapper object aliases do not retain the required read/write delta\n";
      $object_count++ if $size;
   }
   $object_count == 4
      or die "$mapper map reports $object_count allocated Superchip objects, expected 4\n";

   my $sym = read_file($sym_path);
   my $done = parse_symbol($sym, 'simulator_done');
   my $result = parse_symbol($sym, 'result');
   for my $physical_start (0 .. $banks - 1) {
      my ($dump, $err) = require_ok("simulate $mapper from physical bank $physical_start",
         $sim, '-T', $cfg, "--start-bank=$physical_start", '--split-fill=0xA7',
         sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $bin);
      $err eq '' or die "$mapper simulator wrote stderr:\n$err";
      my $mem = parse_dump($dump);
      $mem->[$result] == 0xAA
         or die sprintf("%s start bank %d result is %02X, expected AA\n",
                        $mapper, $physical_start, $mem->[$result]);
      $mem->[0xF080] == 0x5B && $mem->[0xF091] == 0x5A
         or die "$mapper scalar BSS/DATA aliases were not initialized and updated correctly\n";
      for my $bank (0 .. $banks - 1) {
         my $expected = 0x11 + $bank;
         $mem->[0xF081 + $bank] == $expected &&
         $mem->[0xF092 + $bank] == $expected
            or die "$mapper did not preserve allocated Superchip arrays across bank $bank\n";
      }
      for my $offset (0 .. 33) {
         $mem->[0xF000 + $offset] == $mem->[0xF080 + $offset]
            or die "$mapper read/write windows disagree at physical offset $offset\n";
      }
   }
}

# The compiler metadata must make cfg disagreement impossible to ignore.
my $probe_src = File::Spec->catfile($tmp, 'split_cfg_probe.c26');
write_file($probe_src, <<'PROBE');
include "vcs.c26"
include "superchip.c26"
superchip uint8_t probe;
void main(void) { probe := 1; while (1) {} }
PROBE
my $base_cfg = read_file(File::Spec->catfile($vcs, 'vcs_8k_f8sc.cfg'));
my @mismatches = (
   ['read_start', sub { my $x = shift; $x =~ s/(superchip:\s+(?:start|read_start)\s*=\s*)\$F080/$1\$F081/i or die "cannot mutate read_start\n"; return $x; }],
   ['write_start', sub { my $x = shift; $x =~ s/(superchip:.*?write_start\s*=\s*)\$F000/$1\$F001/i or die "cannot mutate write_start\n"; return $x; }],
   ['size', sub { my $x = shift; $x =~ s/(superchip:.*?size\s*=\s*)\$0080/$1\$007F/i or die "cannot mutate size\n"; return $x; }],
   ['banked', sub { my $x = shift; $x =~ s/(superchip:.*?define\s*=\s*yes)/$1, bank = BANK0/i or die "cannot bank split region\n"; return $x; }],
);
my $probe_baseline = File::Spec->catfile($tmp, 'split_baseline.bin');
my ($base_rc, $base_sig, $base_out, $base_err) = run_capture(
   $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', File::Spec->catfile($vcs, 'vcs_8k_f8sc.cfg'),
   $probe_src, '-o', $probe_baseline);
$base_rc == 0 && !$base_sig
   or die "authoritative Superchip baseline failed\n$base_out\n$base_err";
my $probe_bytes = read_file($probe_baseline);
for my $case (@mismatches) {
   my ($name, $mutate) = @$case;
   my $cfg = File::Spec->catfile($tmp, "split_$name.cfg");
   my $bin = File::Spec->catfile($tmp, "split_$name.bin");
   write_file($cfg, $mutate->($base_cfg));
   my ($rc, $sig, $out, $err) = run_capture(
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', $cfg, $probe_src,
      '-o', $bin);
   $rc == 0 && !$sig or die "C26-authoritative split $name link failed\n$out\n$err";
   read_file($bin) eq $probe_bytes
      or die "stale cfg split $name changed the authoritative C26 image\n";
}

# Allocation order and the named object in the overflow diagnostic are stable.
my $overflow_src = File::Spec->catfile($tmp, 'split_overflow.c26');
write_file($overflow_src, <<'OVERFLOW');
include "vcs.c26"
include "superchip.c26"
superchip uint8_t fits[128];
superchip uint8_t spill;
void main(void) { while (1) {} }
OVERFLOW
for my $attempt (1 .. 2) {
   my ($rc, $sig, $out, $err) = run_capture(
      $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', File::Spec->catfile($vcs, 'vcs_8k_f8sc.cfg'),
      $overflow_src, '-o', File::Spec->catfile($tmp, "split_overflow_$attempt.bin"));
   $rc != 0 && !$sig or die "Superchip overflow attempt $attempt unexpectedly linked\n$out\n$err";
   $err =~ /superchip overflow while placing BSS\.superchip\.__vcsc_object\$spill\b.*\bin superchip\b/s
      or die "Superchip overflow attempt $attempt did not deterministically identify spill\n$err";
}

print "automatic Superchip allocation passed for F8SC, F6SC, and F4SC\n";
