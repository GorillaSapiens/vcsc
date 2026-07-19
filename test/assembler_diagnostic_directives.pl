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
   my ($name, $body, @opts) = @_;
   my $src = File::Spec->catfile($tmp, "$name.s");
   my $out = File::Spec->catfile($tmp, "$name.out");
   my $err = File::Spec->catfile($tmp, "$name.err");

   write_file($src, $body);

   my @cmd = ($asm, @opts, $src);
   my $pid = fork();
   die "fork failed: $!\n" if !defined($pid);
   if ($pid == 0) {
      open(STDOUT, '>', $out) or die "open stdout failed: $!\n";
      open(STDERR, '>', $err) or die "open stderr failed: $!\n";
      exec @cmd;
      die "exec failed: $!\n";
   }

   waitpid($pid, 0);
   return ($? >> 8, slurp($out), slurp($err), join(' ', @cmd));
}

my $hex = File::Spec->catfile($tmp, 'echo_good.hex');
my ($exit, $out, $err, $cmd) = run_asm('echo_good', <<'ASM', "--hex=$hex");
.segmentdef "CODE", $8000, $0100
.segment "CODE"
.echo "hello"
.if 0
.echo "hidden"
.error "hidden error"
.else
.echo "shown"
.endif
MACRO SAY msg
.echo msg
ENDM
SAY "macro hello"
.repeat 2
.echo "repeat"
.endrepeat
.byte $AA
ASM

if ($exit != 0) {
   die "echo_good failed, exit $exit\n$cmd\n$err";
}
if ($out ne '') {
   die "echo_good wrote stdout unexpectedly:\n$out";
}
my @want_echo = ("hello", "shown", "macro hello", "repeat", "repeat");
my @got_echo = grep { length($_) } split(/\n/, $err);
if (@got_echo != @want_echo) {
   die "echo_good stderr line count got " . scalar(@got_echo) . " expected " . scalar(@want_echo) . "\nstderr:\n$err";
}
for my $i (0 .. $#want_echo) {
   die "echo_good line $i got '$got_echo[$i]' expected '$want_echo[$i]'\n" if $got_echo[$i] ne $want_echo[$i];
}

my $o65 = File::Spec->catfile($tmp, 'echo_o65.o65');
($exit, $out, $err, $cmd) = run_asm('echo_o65', <<'ASM', '-o', $o65);
.echo "o65 hello"
.byte $01
ASM
if ($exit != 0) {
   die "echo_o65 failed, exit $exit\n$cmd\n$err";
}
if ($err ne "o65 hello\n") {
   die "echo_o65 stderr mismatch:\n$err";
}

my @bad = (
   [ error_hex => ".error \"stop here\"\n", [ 'stop here' ], [ 'hidden' ], "--hex=" . File::Spec->catfile($tmp, 'error_hex.hex') ],
   [ error_macro => "MACRO FAIL msg\n.error msg\nENDM\nFAIL \"macro stop\"\n", [ 'macro stop' ], [], "--hex=" . File::Spec->catfile($tmp, 'error_macro.hex') ],
   [ error_o65 => ".error \"o65 stop\"\n.byte 1\n", [ 'o65 stop' ], [], '-o', File::Spec->catfile($tmp, 'error_o65.o65') ],
   [ echo_no_arg => ".echo\n", [ '.echo expects exactly one quoted string' ], [], "--hex=" . File::Spec->catfile($tmp, 'echo_no_arg.hex') ],
   [ error_expr_arg => ".error 1+2\n", [ '.error expects exactly one quoted string' ], [], "--hex=" . File::Spec->catfile($tmp, 'error_expr_arg.hex') ],
);

for my $case (@bad) {
   my ($name, $body, $needles, $forbidden, @opts) = @$case;
   my ($bad_exit, $bad_out, $bad_err, $bad_cmd) = run_asm($name, $body, @opts);
   if ($bad_exit == 0) {
      die "$name unexpectedly assembled\n$bad_cmd\n";
   }
   for my $needle (@$needles) {
      if (index($bad_err, $needle) < 0) {
         die "$name stderr missing '$needle'\n$bad_cmd\nstderr:\n$bad_err";
      }
   }
   for my $needle (@$forbidden) {
      if (index($bad_err, $needle) >= 0) {
         die "$name stderr unexpectedly contained '$needle'\n$bad_cmd\nstderr:\n$bad_err";
      }
   }
}

print "assembler diagnostic directives passed\n";
exit 0;
