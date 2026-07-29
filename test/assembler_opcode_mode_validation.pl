#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: assembler opcode mode validation passed
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
   my ($name, $body, $extra_args) = @_;
   my $src = File::Spec->catfile($tmp, "$name.s26");
   my $hex = File::Spec->catfile($tmp, "$name.hex");
   my $out = File::Spec->catfile($tmp, "$name.out");
   my $err = File::Spec->catfile($tmp, "$name.err");

   write_file($src, ".segmentdef \"CODE\", \$8000, \$0100\n.segment \"CODE\"\n" . $body);

   my @cmd = ($asm, @{ $extra_args // [] }, "--hex=$hex", $src);
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

my ($good_exit, undef, $good_err, $good_hex, $good_cmd) = run_asm('raw_good', <<'ASM', []);
opA9 #$42
op8D $1234
opA5 $12
opB5 $12,X
opB9 $1234,Y
opA1 ($12,X)
opB1 ($12),Y
op6C ($1234)
opF0 target
opEA
op82 #$42
op0C $1234
op14 $20,X
target:
op0A
ASM

if ($good_exit != 0) {
   die "raw_good failed, exit $good_exit\n$good_cmd\n$good_err";
}
if (!-s $good_hex) {
   die "raw_good did not produce a hex file\n$good_cmd\n";
}

my ($illegal_good_exit, undef, $illegal_good_err, $illegal_good_hex, $illegal_good_cmd) = run_asm('illegal_good', <<'ASM', [ '--illegals' ]);
NOP #$42
NOP $12
NOP $12,X
NOP $1234
NOP $1234,X
KIL
JAM
HLT
ASM

if ($illegal_good_exit != 0) {
   die "illegal_good failed, exit $illegal_good_exit\n$illegal_good_cmd\n$illegal_good_err";
}
if (!-s $illegal_good_hex) {
   die "illegal_good did not produce a hex file\n$illegal_good_cmd\n";
}

my $cfg = File::Spec->catfile($tmp, 'foo.cfg');
write_file($cfg, "FOO indx \$A1\n");

my @bad = (
   [ raw_accumulator_for_immediate => 'opA9 A',
     [], "operand shape does not match opcode byte's immediate mode" ],
   [ raw_absolute_suffix_for_immediate => 'opA9.a $12',
     [], 'specifier selects absolute but opcode byte expects immediate' ],
   [ raw_zeropage_suffix_for_absolute => 'opAD.z $12',
     [], 'specifier selects zero page but opcode byte expects absolute' ],
   [ raw_plain_for_indexed_indirect => 'opA1 $12',
     [], "operand shape does not match opcode byte's indexed indirect mode" ],
   [ raw_default_placeholder_immediate_mismatch => 'op82 A',
     [], "operand shape does not match opcode byte's immediate mode" ],
   [ raw_default_placeholder_suffix_mismatch => 'op82.a $12',
     [], 'specifier selects absolute but opcode byte expects immediate' ],
   [ mnemonic_impossible_suffix => 'jmp.ix ($20,X)',
     [], 'illegal addressing mode for JMP.ix' ],
   [ suffix_argument_mismatch => 'foo.ix #$12',
     [ '--opcode-cfg', $cfg ], 'specifier is incompatible with the operand shape' ],
);

for my $case (@bad) {
   my ($name, $line, $extra_args, $needle) = @$case;
   my ($exit, undef, $err, undef, $cmd) = run_asm($name, "$line\n", $extra_args);
   if ($exit == 0) {
      die "$name unexpectedly assembled\n$cmd\n";
   }
   if (index($err, $needle) < 0) {
      die "$name stderr missing '$needle'\n$cmd\nstderr:\n$err";
   }
}

print "assembler opcode mode validation passed\n";
exit 0;
