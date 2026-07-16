#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

my $repo = shift @ARGV // die "usage: $0 REPO TMP\n";
my $tmp  = shift @ARGV // die "usage: $0 REPO TMP\n";

$repo = abs_path($repo) // die "could not resolve repo root\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $n65c   = File::Spec->catfile($repo, 'compiler', 'n65c');
my $n65asm = File::Spec->catfile($repo, 'assembler', 'n65asm');
my $n65cc  = File::Spec->catfile($repo, 'driver', 'n65cc');
my $test_inc = File::Spec->catdir($repo, 'test');

-x $n65c   or die "missing executable compiler: $n65c\n";
-x $n65asm or die "missing executable assembler: $n65asm\n";
-x $n65cc  or die "missing executable driver: $n65cc\n";

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}

sub slurp_file {
   my ($path) = @_;
   open(my $fh, '<', $path) or return '';
   local $/;
   my $data = <$fh>;
   close($fh);
   return defined($data) ? $data : '';
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
   return ($? >> 8, $? & 127, $stdout, $stderr, join(' ', @cmd));
}

sub parse_ihex {
   my ($path) = @_;
   my @bytes;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   while (my $line = <$fh>) {
      chomp $line;
      next if $line eq '';
      die "bad ihex line: $line\n" if $line !~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my $len = hex($1);
      my $type = hex($3);
      my $data = $4;
      next if $type == 1;
      die "unsupported ihex record type $type\n" if $type != 0;
      die "bad ihex data length\n" if length($data) != $len * 2;
      for my $i (0 .. $len - 1) {
         push @bytes, hex(substr($data, $i * 2, 2));
      }
   }
   close($fh);
   return \@bytes;
}

my $compile_src = File::Spec->catfile($tmp, 'compile_define.n');
my $compile_out = File::Spec->catfile($tmp, 'compile_define.s');
write_file($compile_src, <<'N');
include "machine_6502.n"

#ifdef FOO
#if FOO == 7
void main(void) {
   int x;
   x := FOO;
}
#else
this is broken
#endif
#else
this is broken too
#endif
N

my ($exit, $sig, $stdout, $stderr, $cmd) = run_capture($n65c, '-I', $test_inc, '-DFOO=7', $compile_src, '-o', $compile_out);
die "compiler -D failed exit=$exit sig=$sig\n$cmd\n$stdout$stderr" if $exit != 0 || $sig != 0;
my $asm_text = slurp_file($compile_out);
die "compiler -D output did not contain immediate 7\n$asm_text" if $asm_text !~ /lda\s+#\$07/;

my $dup_n = File::Spec->catfile($tmp, 'compile_dup.n');
write_file($dup_n, <<'N');
include "machine_6502.n"
alias FOO 2
void main(void) {}
N
($exit, $sig, $stdout, $stderr, $cmd) = run_capture($n65c, '-I', $test_inc, '-DFOO', $dup_n, '-o', File::Spec->catfile($tmp, 'compile_dup.s'));
die "compiler duplicate -D unexpectedly succeeded\n$cmd\n$stdout$stderr" if $exit == 0 && $sig == 0;
die "compiler duplicate -D had wrong diagnostic\n$stderr" if $stderr !~ /multiple definitions for alias 'FOO'/;

my $asm_src = File::Spec->catfile($tmp, 'asm_define.s');
my $asm_hex = File::Spec->catfile($tmp, 'asm_define.hex');
write_file($asm_src, <<'ASM');
.ifdef FOO
.byte FOO
.else
.error "missing FOO"
.endif
.ifndef BAR
BAR = 7
.endif
.byte BAR
ASM
($exit, $sig, $stdout, $stderr, $cmd) = run_capture($n65asm, '-DFOO=5', "--hex=$asm_hex", $asm_src);
die "assembler -D failed exit=$exit sig=$sig\n$cmd\n$stdout$stderr" if $exit != 0 || $sig != 0;
my $bytes = parse_ihex($asm_hex);
die "assembler -D byte count mismatch\n" if @$bytes != 2;
die "assembler -D bytes mismatch\n" if $bytes->[0] != 5 || $bytes->[1] != 7;

my $dup_s = File::Spec->catfile($tmp, 'asm_dup.s');
write_file($dup_s, "FOO = 2\n.byte FOO\n");
($exit, $sig, $stdout, $stderr, $cmd) = run_capture($n65asm, '-DFOO=5', '--hex=' . File::Spec->catfile($tmp, 'asm_dup.hex'), $dup_s);
die "assembler duplicate -D unexpectedly succeeded\n$cmd\n$stdout$stderr" if $exit == 0 && $sig == 0;
die "assembler duplicate -D had wrong diagnostic\n$stderr" if $stderr !~ /duplicate symbol 'FOO'/ || $stderr !~ /<command-line>:1: first defined here/;

my $driver_n = File::Spec->catfile($tmp, 'driver_define.n');
my $driver_s = File::Spec->catfile($tmp, 'driver_define.s');
my $driver_o = File::Spec->catfile($tmp, 'driver_define.o65');
write_file($driver_n, "include \"machine_6502.n\"\nvoid main(void) {}\n");
write_file($driver_s, ".byte 1\n");
write_file($driver_o, "not really an object, dry-run only\n");

($exit, $sig, $stdout, $stderr, $cmd) = run_capture($n65cc, '-###', '-c', '-DFOO=3', '-I', $test_inc, $driver_n);
die "driver dry-run .n failed\n$cmd\n$stdout$stderr" if $exit != 0 || $sig != 0;
die "driver did not pass -D to compiler for .n\n$stdout" if $stdout !~ /n65c .* -D FOO=3 /s;
die "driver did not pass -D to assembler for .n\n$stdout" if $stdout !~ /n65asm .* -D FOO=3 /s;

($exit, $sig, $stdout, $stderr, $cmd) = run_capture($n65cc, '-###', '-S', '-DFOO=4', '-I', $test_inc, $driver_n);
die "driver dry-run -S failed\n$cmd\n$stdout$stderr" if $exit != 0 || $sig != 0;
die "driver did not pass -D to compiler for -S\n$stdout" if $stdout !~ /n65c .* -D FOO=4 /s;
die "driver ran assembler for -S\n$stdout" if $stdout =~ /n65asm/;

($exit, $sig, $stdout, $stderr, $cmd) = run_capture($n65cc, '-###', '-c', '-DFOO', $driver_s);
die "driver dry-run .s failed\n$cmd\n$stdout$stderr" if $exit != 0 || $sig != 0;
die "driver did not pass -D to assembler for .s\n$stdout" if $stdout !~ /n65asm .* -D FOO /s;

($exit, $sig, $stdout, $stderr, $cmd) = run_capture($n65cc, '-###', '-DFOO', $driver_o);
die "driver accepted unused -D for object-only link\n$cmd\n$stdout$stderr" if $exit == 0 && $sig == 0;
die "driver unused -D diagnostic mismatch\n$stderr" if $stderr !~ /no compile or assemble stage will use it/;

print "define option support passed\n";
