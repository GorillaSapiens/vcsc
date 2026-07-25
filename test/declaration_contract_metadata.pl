#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "read $path: $!\n";
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
   return ($? >> 8, $? & 127, $stdout, $stderr);
}

sub require_ok {
   my ($name, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit == 0 && !$sig or die "$name failed\n@cmd\n$out$err";
   $err eq '' or die "$name stderr: $err";
   return $out;
}

sub require_match {
   my ($what, $text, $re) = @_;
   $text =~ $re or die "missing $what\n";
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp);

my $cc = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $src = File::Spec->catfile($repo, 'test', 'declaration_contract_compile_test.c26');
my $asm = File::Spec->catfile($tmp, 'contract.s26');
my $obj = File::Spec->catfile($tmp, 'contract.o26');
my $runtime = File::Spec->catdir($repo, 'libraries', 'runtime');

my $assembly = require_ok('compile', $cc, '-I', File::Spec->catdir($repo, 'test'), $src);
open(my $af, '>:raw', $asm) or die "write $asm: $!\n";
print {$af} $assembly;
close($af) or die "close $asm: $!\n";

require_match('required object record', $assembly,
   qr/\.export __contractmeta\$V1\$object\$require\$required_object\$/);
require_match('recommended object record', $assembly,
   qr/\.export __contractmeta\$V1\$object\$recommend\$recommended_object\$/);
require_match('merged strongest function record and source location', $assembly,
   qr/\.export __contractmeta\$V1\$function\$require\$merged_function\$.*\$L10\$C8\$invoke\$none\$type\$/);
require_match('true inline function record', $assembly,
   qr/\.export __contractmeta\$V1\$function\$require\$required_inline\$/);
require_match('canonical unsigned-byte object fingerprint', $assembly,
   qr/__contractmeta\$V1\$object\$require\$required_object\$.*scalarQ28szQ3D1Q3BkindQ3Dunsigned_intQ29/);
require_match('canonical void function signature', $assembly,
   qr/__contractmeta\$V1\$function\$require\$required_inline\$.*functionQ28paramsQ3D0Q3BreturnQ3D/);
require_match('true-inline call semantic record', $assembly,
   qr/\.export __usemeta\$V1\$call\$required_inline\$.*\$function\$main\$.*\$L20\$C21\$invoke\$none/);
require_match('second true-inline call semantic record', $assembly,
   qr/\.export __usemeta\$V1\$call\$recommended_inline\$.*\$function\$main\$.*\$L21\$C24\$invoke\$none/);
require_match('ordinary direct-call semantic record', $assembly,
   qr/\.export __usemeta\$V1\$call\$merged_function\$.*\$function\$main\$.*\$L22\$C21\$invoke\$none/);

require_ok('assemble', $as, '-I', $runtime, '-o', $obj, $asm);
my $bytes = slurp($obj);
for my $needle (
   '__contractmeta$V1$object$require$required_object$',
   '__contractmeta$V1$object$recommend$recommended_object$',
   '__contractmeta$V1$function$require$merged_function$',
   '__contractmeta$V1$function$require$required_inline$',
   '$invoke$none$type$',
   '__usemeta$V1$call$required_inline$',
   '__usemeta$V1$call$recommended_inline$',
   '__usemeta$V1$call$merged_function$',
   '$function$main$use$'
) {
   index($bytes, $needle) >= 0 or die "o26 did not retain metadata fragment '$needle'\n";
}

print "declaration contract and call-use metadata survive compiler and o26 assembly\n";
