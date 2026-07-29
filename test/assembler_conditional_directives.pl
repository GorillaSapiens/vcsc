#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: assembler conditional directives passed
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
   my ($name, $body, @extra) = @_;
   my $src = File::Spec->catfile($tmp, "$name.s26");
   my $hex = File::Spec->catfile($tmp, "$name.hex");
   my $out = File::Spec->catfile($tmp, "$name.out");
   my $err = File::Spec->catfile($tmp, "$name.err");

   write_file($src, $body);

   my @cmd = ($asm, "--hex=$hex", @extra, $src);
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

my ($exit, undef, $err, $hex, $cmd) = run_asm('conditional_good', <<'ASM');
.segmentdef "CODE", $8000, $0100
.segment "CODE"
flag = 1
zero = 0

.if flag
.byte $11
.else
.byte $EE
.endif

.if zero
.byte $EE
.elif flag
.byte $22
.else
.byte $EE
.endif

.ifdef flag
.byte $33
.else
.byte $EE
.endif

.ifndef missing
.byte $44
.else
.byte $EE
.endif

.ifdef missing
.byte $EE
.elifdef flag
.byte $55
.else
.byte $EE
.endif

.ifdef missing
.byte $EE
.elifndef also_missing
.byte $66
.else
.byte $EE
.endif

.if flag
   .if zero
   .byte $EE
   .else
   .byte $77
   .endif
.endif
ASM

if ($exit != 0) {
   die "conditional_good failed, exit $exit\n$cmd\n$err";
}

my $bytes = parse_ihex($hex);
my @want = (0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77);
if (@$bytes != @want) {
   die "conditional_good byte count got " . scalar(@$bytes) . " expected " . scalar(@want) . "\n";
}
for my $i (0 .. $#want) {
   die sprintf("byte %d got %02X expected %02X\n", $i, $bytes->[$i], $want[$i]) if $bytes->[$i] != $want[$i];
}

my @bad = (
   [ endif_without_if => ".endif\n", '.endif without matching .if/.ifdef/.ifndef' ],
   [ else_without_if => ".else\n", '.else without matching .if/.ifdef/.ifndef' ],
   [ elif_without_if => ".elif 1\n", '.elif without matching .if/.ifdef/.ifndef' ],
   [ duplicate_else => ".if 1\n.else\n.else\n.endif\n", 'duplicate .else' ],
   [ elif_after_else => ".if 0\n.else\n.elif 1\n.endif\n", '.elif after .else' ],
   [ unterminated_if => ".if 1\n.byte 1\n", 'unterminated conditional block' ],
   [ ifdef_expression => ".ifdef 1+2\n.endif\n", '.ifdef expects exactly one symbol name' ],
   [ if_unresolved => ".if missing\n.byte 1\n.endif\n", 'unresolved expression' ],
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

print "assembler conditional directives passed\n";
exit 0;
