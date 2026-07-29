#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: assembler opcode override semantics passed
# expectstderrexact:


use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;

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
   my ($name, $body, $cfgs) = @_;
   my $src = File::Spec->catfile($tmp, "$name.s26");
   my $hex = File::Spec->catfile($tmp, "$name.hex");
   my $out = File::Spec->catfile($tmp, "$name.out");
   my $err = File::Spec->catfile($tmp, "$name.err");

   write_file($src, ".segmentdef \"CODE\", \$8000, \$0100\n.segment \"CODE\"\n" . $body);

   my @cmd = ($asm);
   for my $cfg (@$cfgs) {
      push @cmd, '--opcode-cfg', $cfg;
   }
   push @cmd, "--hex=$hex", $src;

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
      die "bad ihex line: $line\n"
         if $line !~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
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

sub require_bytes {
   my ($name, $got, @want) = @_;
   die "$name byte count got " . scalar(@$got) . " expected " . scalar(@want) . "\n"
      if @$got != @want;
   for my $i (0 .. $#want) {
      die sprintf("%s byte %d got %02X expected %02X\n", $name, $i, $got->[$i], $want[$i])
         if $got->[$i] != $want[$i];
   }
}

my $same_cfg = File::Spec->catfile($tmp, 'same_file.cfg');
write_file($same_cfg, "XXX imm \$80\nXXX imm \$82\n");
my ($same_exit, undef, $same_err, $same_hex, $same_cmd) = run_asm(
   'same_file_last_wins',
   "XXX #\$56\nop80 #\$56\nop82 #\$56\n",
   [ $same_cfg ],
);
die "same-file override failed, exit $same_exit\n$same_cmd\n$same_err"
   if $same_exit != 0;
die "same-file override was not silent\n$same_cmd\nstderr:\n$same_err"
   if $same_err ne '';
require_bytes('same-file override', parse_ihex_bytes($same_hex),
   0x82, 0x56,
   0x80, 0x56,
   0x82, 0x56,
);

my $cfg80 = File::Spec->catfile($tmp, 'first_80.cfg');
my $cfg82 = File::Spec->catfile($tmp, 'second_82.cfg');
write_file($cfg80, "XXX imm \$80\n");
write_file($cfg82, "XXX imm \$82\n");

my ($forward_exit, undef, $forward_err, $forward_hex, $forward_cmd) = run_asm(
   'later_file_wins', "XXX #\$56\n", [ $cfg80, $cfg82 ]
);
die "forward config override failed, exit $forward_exit\n$forward_cmd\n$forward_err"
   if $forward_exit != 0;
die "forward config override was not silent\n$forward_cmd\nstderr:\n$forward_err"
   if $forward_err ne '';
require_bytes('forward config order', parse_ihex_bytes($forward_hex), 0x82, 0x56);

my ($reverse_exit, undef, $reverse_err, $reverse_hex, $reverse_cmd) = run_asm(
   'reversed_file_order', "XXX #\$56\n", [ $cfg82, $cfg80 ]
);
die "reverse config override failed, exit $reverse_exit\n$reverse_cmd\n$reverse_err"
   if $reverse_exit != 0;
die "reverse config override was not silent\n$reverse_cmd\nstderr:\n$reverse_err"
   if $reverse_err ne '';
require_bytes('reverse config order', parse_ihex_bytes($reverse_hex), 0x80, 0x56);

my $bad_cfg = File::Spec->catfile($tmp, 'wrong_mode.cfg');
write_file($bad_cfg, "XXX imm \$12\n");
my ($bad_exit, undef, $bad_err, undef, $bad_cmd) = run_asm(
   'wrong_mode_rejected', "XXX #\$56\n", [ $bad_cfg ]
);
die "wrong-mode opcode byte unexpectedly loaded\n$bad_cmd\n"
   if $bad_exit == 0;
my $needle = 'opcode byte $12 is already mapped with a different addressing mode';
die "wrong-mode stderr missing '$needle'\n$bad_cmd\nstderr:\n$bad_err"
   if index($bad_err, $needle) < 0;

print "assembler opcode override semantics passed\n";
exit 0;
