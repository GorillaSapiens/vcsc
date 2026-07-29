#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: assembler expression grammar passed
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

sub parse_ihex_map {
   my ($path) = @_;
   my %map;
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
         $map{$addr + $i} = hex(substr($data_hex, $i * 2, 2));
      }
   }
   close($fh);
   return \%map;
}

my ($exit, undef, $err, $hex, $cmd) = run_asm('expression_good', <<'ASM');
.segmentdef "CODE", $8000, $0100
.segment "CODE"
VAL = 2 + 3 * 4
PAREN = {2 + 3} * 4
.byte VAL, PAREN
.byte 1 << 3 + 1
.byte {1 << 3} + 1
.byte 64 >> 2 + 1
.byte 17 % 5
.byte ~0 & $ff
.byte !0, !1
.byte 1 < 2, 2 <= 2, 3 > 2, 3 >= 4, 5 == 5, 5 != 6
.byte 1 | 2 ^ 3 & 1
.byte 1 || missing
.byte 0 && missing
.if VAL == 14 && PAREN == 20
.byte $99
.else
.byte $ee
.endif
.if 0 || {1 && !0}
.byte $88
.endif
.repeat {1 << 1} + 1
.byte $77
.endrepeat
.byte <later, >later
.word later
lda later + {1 << 0}
later:
.byte $ee
ASM

if ($exit != 0) {
   die "expression_good failed, exit $exit\n$cmd\n$err";
}

my $bytes = parse_ihex_bytes($hex);
my @want = (
   0x0E, 0x14, 0x10, 0x09, 0x08, 0x02, 0xFF, 0x01, 0x00,
   0x01, 0x01, 0x01, 0x00, 0x01, 0x01, 0x03, 0x01, 0x00,
   0x99, 0x88, 0x77, 0x77, 0x77,
   0x1E, 0x80, 0x1E, 0x80, 0xAD, 0x1F, 0x80, 0xEE,
);
if (@$bytes != @want) {
   die "expression_good byte count got " . scalar(@$bytes) . " expected " . scalar(@want) . "\n";
}
for my $i (0 .. $#want) {
   die sprintf("byte %d got %02X expected %02X\n", $i, $bytes->[$i], $want[$i]) if $bytes->[$i] != $want[$i];
}

my ($org_exit, undef, $org_err, $org_hex, $org_cmd) = run_asm('expression_org_align', <<'ASM');
.segmentdef "CODE", $8000, $0100
.segment "CODE"
.org $8000 + {1 << 3}
.byte $A1
.align 1 << 4
.byte $A2
ASM
if ($org_exit != 0) {
   die "expression_org_align failed, exit $org_exit\n$org_cmd\n$org_err";
}
my $map = parse_ihex_map($org_hex);
die "missing byte at 8008\n" unless exists $map->{0x8008} && $map->{0x8008} == 0xA1;
for my $addr (0x8009 .. 0x800F) {
   die sprintf("padding at %04X got %s expected 00\n", $addr, exists($map->{$addr}) ? sprintf('%02X', $map->{$addr}) : '<missing>')
      unless exists $map->{$addr} && $map->{$addr} == 0x00;
}
die "missing byte at 8010\n" unless exists $map->{0x8010} && $map->{0x8010} == 0xA2;

my @bad = (
   [ bang_directive => "!byte 1\n", 'parse error' ],
   [ if_forward => ".if FWD == 1\n.byte 1\n.endif\nFWD = 1\n", 'unresolved expression' ],
   [ repeat_forward => ".repeat COUNT + 1\n.byte 1\n.endrepeat\nCOUNT = 1\n", '.repeat count must resolve before assembly passes' ],
   [ org_forward => '.org BASE + 1
.byte 1
BASE = $8000
', 'unresolved expression' ],
   [ align_forward => ".align BOUNDARY << 1\n.byte 1\nBOUNDARY = 8\n", 'unresolved expression' ],
   [ bad_shift => ".byte 1 << -1\n", 'invalid shift count in expression' ],
   [ mod_zero => ".byte 1 % 0\n", 'divide by zero in expression' ],
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

print "assembler expression grammar passed\n";
exit 0;
