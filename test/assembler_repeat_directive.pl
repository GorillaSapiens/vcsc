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
   my @bytes;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   while (my $line = <$fh>) {
      chomp $line;
      next if $line eq '';
      die "bad ihex line: $line\n" if $line !~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my ($len_hex, $type_hex, $data_hex) = ($1, $3, $4);
      my $len = hex($len_hex);
      my $type = hex($type_hex);
      next if $type == 1;
      die "unsupported ihex record type $type\n" if $type != 0;
      die "bad ihex data length\n" if length($data_hex) != $len * 2;
      for my $i (0 .. $len - 1) {
         push @bytes, hex(substr($data_hex, $i * 2, 2));
      }
   }
   close($fh);
   return \@bytes;
}

my ($exit, undef, $err, $hex, $cmd) = run_asm('repeat_good', <<'ASM');
.segmentdef "CODE", $8000, $0100
.segment "CODE"
.byte $01
.repeat 2+1
.byte $10
.endrepeat
.repeat 2
   .repeat 2
   .byte $20
   .endrepeat
.endrepeat
.repeat 0
.byte $EE
.endrepeat
COUNT = 2
.repeat COUNT
.byte $30
.endrepeat
inx
ASM

if ($exit != 0) {
   die "repeat_good failed, exit $exit\n$cmd\n$err";
}

my $bytes = parse_ihex($hex);
my @want = (0x01, 0x10, 0x10, 0x10, 0x20, 0x20, 0x20, 0x20, 0x30, 0x30, 0xE8);
if (@$bytes != @want) {
   die "repeat_good byte count got " . scalar(@$bytes) . " expected " . scalar(@want) . "\n";
}
for my $i (0 .. $#want) {
   die sprintf("byte %d got %02X expected %02X\n", $i, $bytes->[$i], $want[$i]) if $bytes->[$i] != $want[$i];
}

my @bad = (
   [ endrepeat_without_repeat => ".endrepeat\n", '.endrepeat without matching .repeat' ],
   [ unterminated_repeat => ".repeat 2\n.byte 1\n", '.repeat without matching .endrepeat' ],
   [ repeat_negative => ".repeat -1\n.byte 1\n.endrepeat\n", '.repeat count must be non-negative' ],
   [ repeat_extra_arg => ".repeat 1, 2\n.byte 1\n.endrepeat\n", '.repeat expects exactly one expression' ],
   [ endrepeat_extra_arg => ".repeat 1\n.byte 1\n.endrepeat 1\n", '.endrepeat expects no arguments' ],
   [ repeat_unresolved => ".repeat missing\n.byte 1\n.endrepeat\n", '.repeat count must resolve before assembly passes' ],
   [ repeat_divzero => ".repeat 1/0\n.byte 1\n.endrepeat\n", 'divide by zero in expression' ],
   [ repeat_labeled => "loop: .repeat 1\n.byte 1\n.endrepeat\n", '.repeat cannot have a label' ],
   [ endrepeat_labeled => ".repeat 1\n.byte 1\ndone: .endrepeat\n", '.endrepeat cannot have a label' ],
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

print "assembler repeat directive passed\n";
exit 0;
