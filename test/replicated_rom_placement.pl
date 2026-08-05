#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: replicated ROM objects and functions bind bank-locally
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
      length($bytes) == $count * 2 or die "bad Intel HEX dump record\n";
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
my $cfg = File::Spec->catfile($vcs, 'vcs_8k_f8sc.cfg');
my $src = File::Spec->catfile($tmp, 'replicated.c26');
my $bin = File::Spec->catfile($tmp, 'replicated.bin');
my $map_path = File::Spec->catfile($tmp, 'replicated.map');

write_file($src, <<'SRC');
include "vcs.c26"
include "superchip.c26"
mem bank0 { $start:0xF100 $size:0x0E00 $ro };
mem bank1 { $start:0xD100 $size:0x0E00 $ro };

extern bank0 bank1 const uint8_t table[2];
bank1 bank0 const uint8_t table[2] := { 0x31, 0x42 };

bank1 superchip bank0 uint8_t replicated(uint8_t index);
bank0 bank1 superchip uint8_t replicated(uint8_t index) {
   return table[index];
}

bank1 uint8_t from_bank1(void) {
   return replicated(1);
}

uint8_t automatic_reader(void) {
   return table[0];
}

uint8_t result;
void simulator_done(void) { while (true) {} }

void main(void) {
   uint8_t first := replicated(0);
   uint8_t second := from_bank1();
   uint8_t third := automatic_reader();
   result := first + second + third;
   simulator_done();
}
SRC

require_ok('build replicated F8SC image', $driver, '-I', $vcs, '-DVCS_NO_DEFAULT_ROM', '-T', $cfg,
           '-Map', $map_path, '-o', $bin, $src);
my $map = slurp($map_path);
my $rom = slurp($bin);
length($rom) == 8192 or die "replicated F8SC image is not 8K\n";

$map =~ /REPLICATED ROM\n/s or die "map omitted replicated-ROM section\n$map";
$map =~ /kind=function symbol=replicated copies=2 bytes-each=\$[0-9A-F]{4} physical-total=\$[0-9A-F]{8}/
   or die "map omitted replicated function cost\n$map";
$map =~ /kind=object symbol=table copies=2 bytes-each=\$0002 physical-total=\$00000004/
   or die "map omitted replicated object cost\n$map";
$map =~ /physical-total-all=\$[0-9A-F]{8}/
   or die "map omitted total replicated physical cost\n$map";

$map =~ /kind=object symbol=table.*?region=bank0\s+bank=BANK0\s+load=\$([0-9A-F]{4}).*?region=bank1\s+bank=BANK1\s+load=\$([0-9A-F]{4})/s
   or die "map omitted both table copies\n$map";
my ($table0, $table1) = (hex($1), hex($2));
(($table0 & 0x0fff) != ($table1 & 0x0fff))
   or die "replicated table copies were unnecessarily forced to one common offset\n";
substr($rom, 4096 + $table0 - 0xF000, 2) eq "\x31\x42"
   or die "BANK0 table bytes are wrong\n";
substr($rom, $table1 - 0xD000, 2) eq "\x31\x42"
   or die "BANK1 table bytes are wrong\n";

$map =~ /region=bank0\s+bank=BANK0\s+load=\$[0-9A-F]{4}.*layout=CODE\.bank0\.__vcsc_function\$replicated/
   or die "map omitted BANK0 replicated function body\n$map";
$map =~ /region=bank1\s+bank=BANK1\s+load=\$[0-9A-F]{4}.*layout=CODE\.bank1\.__vcsc_function\$replicated/
   or die "map omitted BANK1 replicated function body\n$map";
$map =~ /component=\d+ assignment=automatic bank=BANK[01].*?automatic CODE\.__vcsc_function\$automatic_reader\s+region=bank[01]/s
   or die "unpinned table reader was not placed with a local copy\n$map";
$map =~ /entries=1 jmp=0 jsr=1/
   or die "local replicated calls should leave exactly one cross-bank call to from_bank1\n$map";
$map =~ /JSR entry=0 .*CODE\.bank1\.__vcsc_function\$from_bank1 source=BANK0 .*destination=BANK1/
   or die "unexpected cross-bank trampoline target\n$map";
$map !~ /JSR entry=.*__vcsc_function\$replicated/
   or die "a call used a trampoline despite a source-bank-local replicated body\n$map";
$map =~ /BSS\.superchip\.__vcsc_activation\$replicated\s+run=\$F080 write=\$F000 size=\$0001/
   or die "replicated function did not retain one shared Superchip result object\n$map";

my $done = map_symbol($map, 'simulator_done');
my $result = map_symbol($map, 'result');
for my $start_bank (0, 1) {
   my ($dump, $err) = require_ok("simulate replicated image from bank $start_bank",
      $sim, '-T', $cfg, "--start-bank=$start_bank",
      sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $bin);
   $err eq '' or die "simulator wrote stderr: $err";
   my $mem = parse_dump($dump);
   $mem->[$result] == 0xA4
      or die sprintf("start bank %d result is %02X, expected A4\n",
                     $start_bank, $mem->[$result]);
   $mem->[0xF080] == 0x42
      or die sprintf("start bank %d shared Superchip result is %02X, expected 42\n",
                     $start_bank, $mem->[0xF080]);
}

print "replicated ROM objects and functions bind bank-locally\n";
