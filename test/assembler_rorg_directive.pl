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

my $asm = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
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

my ($exit, undef, $err, $hex, $cmd) = run_asm('rorg_good', <<'ASM');
.segmentdef "CODE", $8000, $1000
.segment "CODE"
.org $8100
.rorg $F000
start:
   jmp start
   beq later
   .byte <*, >*
later:
   nop
   .word start, later
.rend
.org $8120
after:
   .word after
ASM

if ($exit != 0) {
   die "rorg_good failed, exit $exit\n$cmd\n$err";
}

my $mem = parse_ihex($hex);
my @expect = (
   [ 0x8100, 0x4C ], [ 0x8101, 0x00 ], [ 0x8102, 0xF0 ],
   [ 0x8103, 0xF0 ], [ 0x8104, 0x02 ],
   [ 0x8105, 0x05 ], [ 0x8106, 0xF0 ],
   [ 0x8107, 0xEA ],
   [ 0x8108, 0x00 ], [ 0x8109, 0xF0 ],
   [ 0x810A, 0x07 ], [ 0x810B, 0xF0 ],
   [ 0x8120, 0x20 ], [ 0x8121, 0x81 ],
);

for my $pair (@expect) {
   my ($addr, $want) = @$pair;
   my $got = $mem->{$addr};
   die sprintf("address %04X missing\n", $addr) if !defined($got);
   die sprintf("address %04X got %02X expected %02X\n", $addr, $got, $want) if $got != $want;
}

my ($align_exit, undef, $align_err, $align_hex, $align_cmd) = run_asm('rorg_align', <<'ASM');
.segmentdef "CODE", $8000, $1000
.segment "CODE"
.org $8001
.rorg $F0FE
.byte $AA
.align $100
.byte $BB
.rend
ASM

if ($align_exit != 0) {
   die "rorg_align failed, exit $align_exit\n$align_cmd\n$align_err";
}

my $align_mem = parse_ihex($align_hex);
my @align_expect = (
   [ 0x8001, 0xAA ],
   [ 0x8002, 0x00 ],
   [ 0x8003, 0xBB ],
);

for my $pair (@align_expect) {
   my ($addr, $want) = @$pair;
   my $got = $align_mem->{$addr};
   die sprintf("align address %04X missing\n", $addr) if !defined($got);
   die sprintf("align address %04X got %02X expected %02X\n", $addr, $got, $want) if $got != $want;
}

my @bad = (
   [ rorg_org_error => ".segmentdef \"CODE\", \$8000, \$1000\n.segment \"CODE\"\n.rorg \$F000\n.org \$8100\n", '.org is not allowed while .rorg is active' ],
   [ rend_without_rorg => ".rend\n", '.rend without active .rorg' ],
   [ rorg_no_arg => ".rorg\n", '.rorg expects exactly one expression' ],
   [ rend_arg => ".rorg \$F000\n.rend 1\n", '.rend expects no arguments' ],
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

print "assembler rorg directive passed\n";
exit 0;
