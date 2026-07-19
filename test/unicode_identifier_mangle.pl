#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use File::Spec;
use File::Temp qw(tempdir);
use Encode qw(encode);

binmode STDOUT, ':encoding(UTF-8)';

my $repo = shift @ARGV // File::Spec->rel2abs(File::Spec->catdir(File::Spec->curdir, '..'));
my $tmp_root = shift @ARGV // File::Spec->tmpdir();
my $tmp = tempdir('unicode_ident_XXXXXX', DIR => $tmp_root, CLEANUP => 1);

my $n65c = File::Spec->catfile($repo, 'compiler', 'n65c');
my $n65cc = File::Spec->catfile($repo, 'driver', 'n65cc');
my $n65sim = File::Spec->catfile($repo, 'simulator', 'n65sim');
my $test_inc = File::Spec->catdir($repo, 'test');

sub slurp_bytes {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not read $path: $!\n";
   local $/;
   my $data = <$fh>;
   close($fh);
   return $data;
}

sub write_utf8 {
   my ($path, $text) = @_;
   open(my $fh, '>:encoding(UTF-8)', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}

sub write_bytes {
   my ($path, $bytes) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $bytes;
   close($fh);
}

sub run_capture {
   my (@cmd) = @_;
   my $out = File::Spec->catfile($tmp, 'cmd.out');
   my $err = File::Spec->catfile($tmp, 'cmd.err');
   my $quoted = join(' ', map { my $s = $_; $s =~ s/'/'"'"'/g; "'$s'" } @cmd);
   my $rc = system("$quoted >'$out' 2>'$err'");
   return ($rc >> 8, slurp_bytes($out), slurp_bytes($err));
}

sub require_file_contains {
   my ($file, $needle) = @_;
   my $data = slurp_bytes($file);
   die "$file did not contain expected text: $needle\n" if index($data, $needle) < 0;
}

sub require_data_contains {
   my ($data, $needle) = @_;
   die "missing expected text: $needle\n" if index($data, $needle) < 0;
}

sub require_data_not_contains {
   my ($data, $needle) = @_;
   die "found forbidden text: $needle\n" if index($data, $needle) >= 0;
}

for my $tool ($n65c, $n65cc, $n65sim) {
   die "required tool not executable: $tool\n" if !-x $tool;
}

my $e2e_src = File::Spec->catfile($tmp, 'unicode_e2e.n');
write_utf8($e2e_src, <<'EOF');
include "machine_6502.n"

ref uint8_t gfailcode@[none/0x02f0];

void pass(void) {
   asm lda #$ff;
   asm ldx #0;
   asm ldy #0;
   asm jsr $ffff;
}

void fail(uint8_t code) {
   gfailcode := code;
   asm lda #$ff;
   asm ldx $02f0;
   asm ldy #0;
   asm jsr $ffff;
}

int8_t café := 3;

int16_t λ_count(int16_t x) {
   return x + café;
}

int16_t 🦍(int16_t x) {
   return λ_count(x) + café;
}

void main(void) {
   int16_t result := 🦍(4);
   if (result != 10) {
      fail(1);
   }
   goto τέλος;
   fail(2);
τέλος:
   pass();
}
EOF

my $e2e_asm = File::Spec->catfile($tmp, 'unicode_e2e.s');
my ($rc, $out, $err) = run_capture($n65c, '-quiet', '-I', $test_inc, $e2e_src, '-o', $e2e_asm);
die "n65c failed for unicode e2e source:\n$err$out\n" if $rc != 0;
my $asm = slurp_bytes($e2e_asm);
require_data_contains($asm, '.export caf?u00E9?');
require_data_contains($asm, '.proc ?u03BB?_count');
require_data_contains($asm, '.proc ?u0001F98D?');
require_data_contains($asm, '@user_?u03C4??u03AD??u03BB??u03BF??u03C2?:');
require_data_contains($asm, 'jmp @user_?u03C4??u03AD??u03BB??u03BF??u03C2?');
require_data_not_contains($asm, "caf\xc3\xa9");
require_data_not_contains($asm, "\xce\xbb_count");
require_data_not_contains($asm, "\xf0\x9f\xa6\x8d");

my $hex = File::Spec->catfile($tmp, 'unicode_e2e.hex');
($rc, $out, $err) = run_capture($n65cc, '-I', $test_inc, $e2e_src, '-o', $hex);
die "n65cc failed for unicode e2e source:\n$err$out\n" if $rc != 0;
($rc, $out, $err) = run_capture($n65sim, $hex);
die "simulator failed for unicode e2e source:\n$err$out\n" if $rc != 0;

my $unknown_src = File::Spec->catfile($tmp, 'unicode_unknown_identifier.n');
write_utf8($unknown_src, <<'EOF');
include "machine_6502.n"
void main(void) {
   🥹 := 1;
}
EOF
($rc, $out, $err) = run_capture($n65c, '-quiet', '-I', $test_inc, $unknown_src, '-o', File::Spec->catfile($tmp, 'unicode_unknown_identifier.s'));
die "unicode unknown identifier unexpectedly compiled\n" if $rc == 0;
require_data_contains($err . $out, ":3.4]");
require_data_contains($err . $out, encode('UTF-8', "unknown identifier '🥹'"));
require_data_not_contains($err . $out, "?u0001F979?");

my $bad_col_src = File::Spec->catfile($tmp, 'unicode_bad_column.n');
write_bytes($bad_col_src, "include \"machine_6502.n\"\nint16_t a\xf0\x9f\xa5\xb9\xc3 := 0;\n");
($rc, $out, $err) = run_capture($n65c, '-quiet', '-I', $test_inc, $bad_col_src, '-o', File::Spec->catfile($tmp, 'unicode_bad_column.s'));
die "malformed UTF-8 column case unexpectedly compiled\n" if $rc == 0;
require_data_contains($err . $out, 'invalid UTF-8 in identifier');
require_data_contains($err . $out, ':2.11 ');

for my $case (
   ["incomplete trailing UTF-8", "include \"machine_6502.n\"\nint16_t bad\xc3 := 0;\n"],
   ["stray continuation byte", "include \"machine_6502.n\"\nint16_t bad\x80 := 0;\n"],
   ["stray starting continuation byte", "include \"machine_6502.n\"\nint16_t \x80bad := 0;\n"],
) {
   my ($name, $bytes) = @$case;
   my $bad_src = File::Spec->catfile($tmp, "bad_$name.n");
   $bad_src =~ s/[^A-Za-z0-9_.\/-]/_/g;
   write_bytes($bad_src, $bytes);
   my $bad_asm = File::Spec->catfile($tmp, "bad_$name.s");
   $bad_asm =~ s/[^A-Za-z0-9_.\/-]/_/g;
   ($rc, $out, $err) = run_capture($n65c, '-quiet', '-I', $test_inc, $bad_src, '-o', $bad_asm);
   die "malformed UTF-8 case '$name' unexpectedly compiled\n" if $rc == 0;
   require_data_contains($err . $out, 'invalid UTF-8 in identifier');
}

print "unicode identifier mangle tests passed\n";
