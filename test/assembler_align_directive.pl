#!/usr/bin/perl

use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);

my $repo = shift @ARGV // die "usage: $0 REPO TMP\n";
my $tmp  = shift @ARGV // die "usage: $0 REPO TMP\n";

$repo = abs_path($repo) // die "could not resolve repo root\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $asm = File::Spec->catfile($repo, 'assembler', 'n65asm');
-x $asm or die "missing executable assembler: $asm\n";

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or return '';
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
}

sub run_asm {
   my ($name, $body) = @_;
   my $src = File::Spec->catfile($tmp, "$name.s");
   my $hex = File::Spec->catfile($tmp, "$name.hex");
   my $out = File::Spec->catfile($tmp, "$name.out");
   my $err = File::Spec->catfile($tmp, "$name.err");

   write_file($src, $body);

   my @cmd = ($asm, "--hex=$hex", $src);
   my $pid = fork();
   die "fork failed: $!\n" if !defined($pid);
   if ($pid == 0) {
      open(STDOUT, '>', $out) or die "open stdout failed: $!\n";
      open(STDERR, '>', $err) or die "open stderr failed: $!\n";
      exec @cmd;
      die "exec failed: $!\n";
   }

   waitpid($pid, 0);
   return ($? >> 8, slurp($out), slurp($err), $hex, join(' ', @cmd));
}

sub parse_ihex {
   my ($path) = @_;
   my %mem;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   while (my $line = <$fh>) {
      chomp $line;
      next if $line eq '';
      die "bad ihex line: $line\n" if $line !~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my ($len_hex, $addr_hex, $type_hex, $data_hex) = ($1, $2, $3, $4);
      my $len = hex($len_hex);
      my $addr = hex($addr_hex);
      my $type = hex($type_hex);
      next if $type == 1;
      die "unsupported ihex record type $type\n" if $type != 0;
      die "bad ihex data length\n" if length($data_hex) != $len * 2;
      for my $i (0 .. $len - 1) {
         $mem{$addr + $i} = hex(substr($data_hex, $i * 2, 2));
      }
   }
   close($fh);
   return \%mem;
}

my ($exit, undef, $err, $hex, $cmd) = run_asm('align_good', <<'ASM');
.segmentdef "CODE", $8000, $0100
.segment "CODE"
.byte $AA
.align 4
middle:
.byte $BB
.word middle
.align 1
.byte $CC
ASM

if ($exit != 0) {
   die "align_good failed, exit $exit\n$cmd\n$err";
}

my $mem = parse_ihex($hex);
my @expect = (
   [ 0x8000, 0xAA ],
   [ 0x8001, 0x00 ],
   [ 0x8002, 0x00 ],
   [ 0x8003, 0x00 ],
   [ 0x8004, 0xBB ],
   [ 0x8005, 0x04 ],
   [ 0x8006, 0x80 ],
   [ 0x8007, 0xCC ],
);

for my $pair (@expect) {
   my ($addr, $want) = @$pair;
   my $got = $mem->{$addr};
   die sprintf("address %04X missing\n", $addr) if !defined($got);
   die sprintf("address %04X got %02X expected %02X\n", $addr, $got, $want) if $got != $want;
}

my @bad = (
   [ align_zero => ".align 0\n", '.align requires a positive boundary' ],
   [ align_extra_arg => ".align 4, 0\n", '.align expects exactly one expression' ],
);

for my $case (@bad) {
   my ($name, $body, $needle) = @$case;
   my ($bad_exit, undef, $bad_err, undef, $bad_cmd) = run_asm($name, $body);
   if ($bad_exit == 0) {
      die "$name unexpectedly assembled\n$bad_cmd\n";
   }
   if (index($bad_err, $needle) < 0) {
      die "$name stderr missing '$needle'\n$bad_cmd\nstderr:\n$bad_err";
   }
}

print "assembler align directive passed\n";
exit 0;
