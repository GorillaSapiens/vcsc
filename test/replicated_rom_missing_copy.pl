#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: replicated ROM missing-copy diagnostics and function fallback pass
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "write $path: $!\n";
   print {$fh} $text;
   close($fh) or die "close $path: $!\n";
}
sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "read $path: $!\n";
   local $/;
   my $text = <$fh> // '';
   close($fh);
   return $text;
}
sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub require_ok {
   my ($label, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit == 0 && !$sig
      or die "$label failed: exit=$exit signal=$sig\n@cmd\n$out$err";
   return ($out, $err);
}
sub require_fail {
   my ($label, $fragment, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   ($exit != 0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n$out";
   index($err, $fragment) >= 0
      or die "$label stderr omitted '$fragment'\n$out$err";
   return $err;
}
sub map_symbol {
   my ($map, $name) = @_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\s+/m
      or die "map omitted symbol $name\n";
   return hex($1);
}
sub parse_dump {
   my ($text) = @_;
   my @mem = (0) x 65536;
   for my $line (split /\n/, $text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my ($count, $addr, $bytes) = (hex($1), hex($2), $3);
      for my $i (0 .. $count - 1) {
         $mem[$addr + $i] = hex(substr($bytes, $i * 2, 2));
      }
   }
   return \@mem;
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp);

my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $sim = File::Spec->catfile($repo, 'simulator', 'vcsc-sim');
my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');
my $cfg = File::Spec->catfile($vcs, 'F6/mapper.cfg');

my $good_src = File::Spec->catfile($tmp, 'function_fallback.c26');
my $good_bin = File::Spec->catfile($tmp, 'function_fallback.bin');
my $good_map_path = File::Spec->catfile($tmp, 'function_fallback.map');
write_file($good_src, <<'SRC');
include "vcs.c26"
mem bank0 { $start:0xF000 $size:0x0F00 $ro };
mem bank1 { $start:0xD000 $size:0x0F00 $ro };
mem bank2 { $start:0xB000 $size:0x0F00 $ro };

bank1 bank0 uint8_t replicated(void) { return 0x5a; }
bank2 uint8_t from_bank2(void) { return replicated(); }
uint8_t result;
void simulator_done(void) { while (true) {} }
void main(void) { result := from_bank2(); simulator_done(); }
SRC
require_ok('build F6 replicated function fallback', $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM',
           '-T', $cfg, '-Map', $good_map_path, '-o', $good_bin, $good_src);
my $map = slurp($good_map_path);
$map =~ /kind=function symbol=replicated copies=2/
   or die "map omitted replicated function copies\n$map";
$map =~ /entries=2 jmp=0 jsr=2/
   or die "expected one call into BANK2 and one fallback call to a replicated function\n$map";
$map =~ /JSR entry=\d+ .*__vcsc_function\$replicated source=BANK2 .*destination=BANK0/
   or die "BANK2 call did not fall back through a trampoline to the primary replicated body\n$map";
my $done = map_symbol($map, 'simulator_done');
my $result = map_symbol($map, 'result');
for my $start_bank (0 .. 3) {
   my ($dump, $err) = require_ok("simulate F6 fallback from bank $start_bank",
      $sim, '-T', $cfg, "--start-bank=$start_bank",
      sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $good_bin);
   $err eq '' or die "simulator wrote stderr: $err";
   my $mem = parse_dump($dump);
   $mem->[$result] == 0x5a
      or die sprintf("start bank %d result is %02X, expected 5A\n",
                     $start_bank, $mem->[$result]);
}

my $three_src = File::Spec->catfile($tmp, 'three_copies.c26');
my $three_bin = File::Spec->catfile($tmp, 'three_copies.bin');
my $three_map_path = File::Spec->catfile($tmp, 'three_copies.map');
write_file($three_src, <<'SRC');
include "vcs.c26"
mem bank0 { $start:0xF000 $size:0x0F00 $ro };
mem bank1 { $start:0xD000 $size:0x0F00 $ro };
mem bank2 { $start:0xB000 $size:0x0F00 $ro };
bank2 bank0 bank1 const uint8_t table3[3] := { 1, 2, 3 };
bank1 bank2 bank0 uint8_t function3(uint8_t index) { return table3[index]; }
bank1 uint8_t caller1(void) { return function3(1); }
bank2 uint8_t caller2(void) { return function3(2); }
uint8_t result3;
void simulator_done3(void) { while (true) {} }
void main(void) { result3 := function3(0) + caller1() + caller2(); simulator_done3(); }
SRC
require_ok('build three-copy F6 image', $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', $cfg,
           '-Map', $three_map_path, '-o', $three_bin, $three_src);
my $three_map = slurp($three_map_path);
$three_map =~ /kind=function symbol=function3 copies=3/
   or die "map omitted three function copies\n$three_map";
$three_map =~ /kind=object symbol=table3 copies=3 bytes-each=\$0003 physical-total=\$00000009/
   or die "map omitted three object copies or cost\n$three_map";
$three_map =~ /entries=2 jmp=0 jsr=2/
   or die "three local function copies should avoid extra trampolines\n$three_map";
$three_map !~ /JSR entry=.*__vcsc_function\$function3/
   or die "three-copy local call unexpectedly used a trampoline\n$three_map";
my $done3 = map_symbol($three_map, 'simulator_done3');
my $result3 = map_symbol($three_map, 'result3');
my ($three_dump, $three_err) = require_ok('simulate three-copy F6 image',
   $sim, '-T', $cfg, '--start-bank=3', sprintf('--stop-pc=0x%04X', $done3),
   '--dump-on-stop', $three_bin);
$three_err eq '' or die "simulator wrote stderr: $three_err";
my $three_mem = parse_dump($three_dump);
$three_mem->[$result3] == 6
   or die sprintf("three-copy result is %02X, expected 06\n", $three_mem->[$result3]);

my $bad_src = File::Spec->catfile($tmp, 'missing_object_copy.c26');
my $bad_bin = File::Spec->catfile($tmp, 'missing_object_copy.bin');
write_file($bad_src, <<'SRC');
include "vcs.c26"
mem bank0 { $start:0xF000 $size:0x0F00 $ro };
mem bank1 { $start:0xD000 $size:0x0F00 $ro };
mem bank2 { $start:0xB000 $size:0x0F00 $ro };

bank0 bank1 const uint8_t table[1] := { 0x7e };
bank2 uint8_t illegal_reader(void) { return table[0]; }
void main(void) { uint8_t value := illegal_reader(); }
SRC
my $err = require_fail('link pinned reader without a local object copy',
   "pinned layout CODE.bank2.__vcsc_function\$illegal_reader",
   $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', $cfg, '-o', $bad_bin, $bad_src);
index($err, 'requires bank BANK2, which has no local copy') >= 0
   or die "missing-copy diagnostic omitted BANK2 locality\n$err";

print "replicated ROM missing-copy diagnostics and function fallback pass\n";
