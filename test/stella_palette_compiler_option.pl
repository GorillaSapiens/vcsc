#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: Stella palette compiler option passed
# expectstderrexact:

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

my $repo = shift @ARGV // die "usage: $0 REPO TMP\n";
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
$repo = abs_path($repo) // die "could not resolve repo root\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $cc = File::Spec->catfile($repo, qw(compiler vcsc-cc1));
my $driver = File::Spec->catfile($repo, qw(driver vcsc));
my $vcs_inc = File::Spec->catdir($repo, qw(libraries vcs));
my $canonical = File::Spec->catfile($repo, qw(test fixtures stella stella.pal));
-x $cc or die "missing compiler: $cc\n";
-x $driver or die "missing driver: $driver\n";
-r $canonical or die "missing canonical Stella palette: $canonical\n";

sub write_binary {
   my ($path, $data) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $data;
   close($fh) or die "could not close $path: $!\n";
}

sub write_text {
   my ($path, $data) = @_;
   open(my $fh, '>', $path) or die "could not write $path: $!\n";
   print {$fh} $data;
   close($fh) or die "could not close $path: $!\n";
}

sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not read $path: $!\n";
   local $/;
   my $data = <$fh> // '';
   close($fh);
   return $data;
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
   my ($what, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   die "$what failed exit=$exit sig=$sig\n$out$err" if $exit || $sig;
   return ($out, $err);
}

# Deliberately distinct colors in each slice prove that NTSC, PAL, and SECAM
# select their own portion of Stella's combined 792-byte file.
my $custom = chr(0xff) x 792;
substr($custom, 17 * 3, 3) = pack('C3', 1, 2, 3);                 # NTSC -> $22
substr($custom, 384 + 34 * 3, 3) = pack('C3', 4, 5, 6);           # PAL   -> $44
substr($custom, 768 + 3 * 3, 3) = pack('C3', 7, 8, 9);            # SECAM -> $06
my $custom_path = File::Spec->catfile($tmp, 'custom-stella.pal');
write_binary($custom_path, $custom);

my $source = File::Spec->catfile($tmp, 'palette_test.c26');
my $assembly = File::Spec->catfile($tmp, 'palette_test.s26');
write_text($source, <<'SRC');
include "vcs.c26"
const uint8_t selected[3] := {
   __builtin_ntsc_rgb(1, 2, 3),
   __builtin_pal_rgb(4, 5, 6),
   __builtin_secam_rgb(7, 8, 9)
};
void main(void) {}
SRC

require_ok('driver custom-palette compile', $driver, '-S', '--stella-palette',
           $custom_path, '-I', $vcs_inc, $source, '-o', $assembly);
my $asm = slurp($assembly);
$asm =~ /\.byte\s+\$22,\s*\$44,\s*\$06/i
   or die "custom Stella palette did not select independent NTSC/PAL/SECAM slices:\n$asm";

my ($dry, $dryerr) = require_ok('driver palette forwarding', $driver, '-###', '-S',
   '--stella-palette=' . $custom_path, '-I', $vcs_inc, $source, '-o', $assembly);
$dry =~ /vcsc-cc1 .* --stella-palette \Q$custom_path\E(?:\s|$)/s
   or die "driver did not forward --stella-palette to vcsc-cc1:\n$dry$dryerr";

my $asm_only = File::Spec->catfile($tmp, 'no-compiler.s26');
write_text($asm_only, ".byte 0\n");
my ($unused_exit, $unused_sig, $unused_out, $unused_err) = run_capture(
   $driver, '-###', '-c', '--stella-palette', $custom_path, $asm_only);
die "driver accepted --stella-palette without a C26 compile stage\n"
   if !$unused_exit && !$unused_sig;
$unused_err =~ /no C26 compile stage will use it/
   or die "unused --stella-palette diagnostic mismatch:\n$unused_out$unused_err";

# The checked-in Stella palette is generated from the compiled-in tables. It
# must therefore be a byte-for-byte code-generation no-op for all three full
# palette fixtures when explicitly selected.
for my $name (qw(ntsc pal secam)) {
   my $fixture = File::Spec->catfile($repo, 'test', "builtin_${name}_rgb_palette_codegen_test.c26");
   my $default_out = File::Spec->catfile($tmp, "$name-default.s26");
   my $file_out = File::Spec->catfile($tmp, "$name-file.s26");
   require_ok("$name default palette compile", $cc, '-I', $vcs_inc,
              $fixture, '-o', $default_out);
   require_ok("$name canonical file compile", $cc, '--stella-palette', $canonical,
              '-I', $vcs_inc, $fixture, '-o', $file_out);
   slurp($default_out) eq slurp($file_out)
      or die "$name canonical Stella palette changed generated assembly\n";
}

# Bad files must fail before source compilation with clear file diagnostics.
my $short = File::Spec->catfile($tmp, 'short.pal');
my $long = File::Spec->catfile($tmp, 'long.pal');
write_binary($short, chr(0) x 791);
write_binary($long, chr(0) x 793);
for my $case (
   [$short, qr/expected 792 bytes, got 791/],
   [$long, qr/longer than 792 bytes/],
   [File::Spec->catfile($tmp, 'missing.pal'), qr/could not read file/],
   ['', qr/empty filename/],
) {
   my ($path, $want) = @$case;
   my ($exit, $sig, $out, $err) = run_capture($cc, '--stella-palette', $path,
                                               '-I', $vcs_inc, $source, '-o', $assembly);
   die "bad Stella palette unexpectedly compiled: $path\n" if !$exit && !$sig;
   $err =~ $want or die "bad Stella palette diagnostic mismatch for $path:\n$err";
   $err =~ /Stella palette '\Q$path\E'/
      or die "bad Stella palette diagnostic omitted filename for '$path':\n$err";
}

print "Stella palette compiler option passed\n";
