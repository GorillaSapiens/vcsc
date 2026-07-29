#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: assembler mode suffix operand matrix passed
# expectstderrexact:


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
   my $src = File::Spec->catfile($tmp, "$name.s26");
   my $hex = File::Spec->catfile($tmp, "$name.hex");
   my $out = File::Spec->catfile($tmp, "$name.out");
   my $err = File::Spec->catfile($tmp, "$name.err");

   write_file($src, ".segmentdef \"CODE\", \$8000, \$0200\n.segment \"CODE\"\n" . $body);

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

sub parse_ihex_bytes {
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

my ($good_exit, undef, $good_err, $good_hex, $good_cmd) = run_asm('suffix_matrix_good', <<'ASM');
base = $20
absbase = $1234
lda.z  {base + 1}
lda.zx {base + 1},X
ldx.zy {base + 1},Y
lda.a  {absbase + 1} + 1
lda.ax {absbase + 1},X
lda.ay {absbase + 1},Y
jmp.i  (absbase + 1)
lda.ix (base,X)
lda.iy (base),Y
opA5.z  {base + 1}
opB5.zx {base + 1},X
opB6.zy {base + 1},Y
opAD.a  {absbase + 1} + 1
opBD.ax {absbase + 1},X
opB9.ay {absbase + 1},Y
op6C.i  (absbase + 1)
opA1.ix (base,X)
opB1.iy (base),Y
ASM

if ($good_exit != 0) {
   die "suffix_matrix_good failed, exit $good_exit\n$good_cmd\n$good_err";
}

my $bytes = parse_ihex_bytes($good_hex);
my @want = (
   0xA5, 0x21,
   0xB5, 0x21,
   0xB6, 0x21,
   0xAD, 0x36, 0x12,
   0xBD, 0x35, 0x12,
   0xB9, 0x35, 0x12,
   0x6C, 0x35, 0x12,
   0xA1, 0x20,
   0xB1, 0x20,
   0xA5, 0x21,
   0xB5, 0x21,
   0xB6, 0x21,
   0xAD, 0x36, 0x12,
   0xBD, 0x35, 0x12,
   0xB9, 0x35, 0x12,
   0x6C, 0x35, 0x12,
   0xA1, 0x20,
   0xB1, 0x20,
);

if (@$bytes != @want) {
   die "suffix_matrix_good byte count got " . scalar(@$bytes) . " expected " . scalar(@want) . "\n";
}
for my $i (0 .. $#want) {
   die sprintf("byte %d got %02X expected %02X\n", $i, $bytes->[$i], $want[$i]) if $bytes->[$i] != $want[$i];
}

my @bad = (
   [ z_with_indexed_operand       => 'lda.z base,X',         'specifier is incompatible with the operand shape' ],
   [ zx_without_indexed_operand   => 'lda.zx base',          'specifier is incompatible with the operand shape' ],
   [ zy_with_x_operand            => 'ldx.zy base,X',        'specifier is incompatible with the operand shape' ],
   [ a_with_indexed_operand       => 'lda.a absbase,X',      'specifier is incompatible with the operand shape' ],
   [ ax_without_indexed_operand   => 'lda.ax absbase',       'specifier is incompatible with the operand shape' ],
   [ ay_with_x_operand            => 'lda.ay absbase,X',     'specifier is incompatible with the operand shape' ],
   [ i_without_indirect_operand   => 'jmp.i absbase',        'specifier is incompatible with the operand shape' ],
   [ ix_with_iy_operand           => 'lda.ix (base),Y',      'specifier is incompatible with the operand shape' ],
   [ iy_with_ix_operand           => 'lda.iy (base,X)',      'specifier is incompatible with the operand shape' ],
   [ impossible_mnemonic_mode     => 'jmp.ix (base,X)',      'illegal addressing mode for JMP.ix' ],
   [ raw_byte_mode_mismatch       => 'opA9.a {absbase}',     'specifier selects absolute but opcode byte expects immediate' ],
);

for my $case (@bad) {
   my ($name, $line, $needle) = @$case;
   my ($exit, undef, $err, undef, $cmd) = run_asm($name, "base = \$20\nabsbase = \$1234\n$line\n");
   if ($exit == 0) {
      die "$name unexpectedly assembled\n$cmd\n";
   }
   if (index($err, $needle) < 0) {
      die "$name stderr missing '$needle'\n$cmd\nstderr:\n$err";
   }
}

my @parse_bad = (
   [ expr_suffix_immediate_shape => 'lda.a #$12' ],
   [ expr_suffix_accumulator_shape => 'lda.a A' ],
   [ expr_suffix_ix_shape => 'lda.a (base,X)' ],
);

for my $case (@parse_bad) {
   my ($name, $line) = @$case;
   my ($exit, undef, $err, undef, $cmd) = run_asm($name, "base = \$20\n$line\n");
   if ($exit == 0) {
      die "$name unexpectedly assembled\n$cmd\n";
   }
   if (index($err, 'parse error') < 0) {
      die "$name stderr missing parse error\n$cmd\nstderr:\n$err";
   }
}

print "assembler mode suffix operand matrix passed\n";
exit 0;
