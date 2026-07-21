#!/usr/bin/env perl
use strict;
use warnings;
use File::Spec;

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>', $path) or die "cannot write $path: $!\n";
   print {$fh} $text;
   close($fh) or die "cannot close $path: $!\n";
}

sub read_file {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "cannot read $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return $text;
}

my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $cc1 = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
my $ar = File::Spec->catfile($repo, 'archiver', 'vcsc-ar');
my $test_inc = File::Spec->catdir($repo, 'test');
my $runtime = File::Spec->catdir($repo, 'libraries', 'runtime');
my $archive = File::Spec->catfile($runtime, 'libvcsc.l26');

my @all_cells = qw(arg0 arg1 ptr0 ptr1 ptr2 ptr3 tmp0 tmp1 tmp2 tmp3 tmp4 tmp5);
my %bytes = (
   arg0 => 1, arg1 => 1,
   ptr0 => 2, ptr1 => 2, ptr2 => 2, ptr3 => 2,
   tmp0 => 1, tmp1 => 1, tmp2 => 1, tmp3 => 1, tmp4 => 1, tmp5 => 1,
);

open(my $afh, '-|', $ar, 't', $archive) or die "cannot list $archive: $!\n";
my $members = do { local $/; <$afh> };
close($afh) or die "archive listing failed for $archive\n";
$members !~ /vcsc-zeropage\.o26/
   or die "monolithic zero-page member remains in runtime archive\n";
for my $cell (@all_cells) {
   $members =~ /^vcsc-zp-\Q$cell\E\.o26$/m
      or die "runtime archive lacks independent $cell workspace member\n";
}

my $inc = read_file(File::Spec->catfile($runtime, 'vcsc-runtime.inc'));
$inc !~ /^\s*\.importzp\b/m
   or die "vcsc-runtime.inc still imports the whole workspace unconditionally\n";

sub build_case {
   my ($name, $source) = @_;
   my $src = File::Spec->catfile($tmp, "$name.c26");
   my $out = File::Spec->catfile($tmp, "$name.bin");
   my $map = File::Spec->catfile($tmp, "$name.map");
   write_file($src, "include \"machine_6502.c26\"\n" . $source);
   system($driver, '-I', $test_inc, '-Map', $map, $src, '-o', $out) == 0
      or die "$name build failed\n";
   return read_file($map);
}

sub linked_cells {
   my ($map) = @_;
   my %seen;
   while ($map =~ /libvcsc\.l26\(vcsc-zp-([A-Za-z0-9_]+)\.o26\)/g) {
      $seen{$1} = 1;
   }
   return sort keys %seen;
}

sub require_cells {
   my ($name, $map, @want) = @_;
   my @got = linked_cells($map);
   my $got = join(',', @got);
   my $want = join(',', sort @want);
   $got eq $want
      or die "$name linked workspace cells {$got}, expected {$want}\n";
   my $size = 0;
   $size += $bytes{$_} for @got;
   return $size;
}

my @startup = qw(arg0 arg1 ptr0 ptr1 ptr2);

my $plain = build_case('workspace_plain', <<'SRC');
uint32_t a := 0x12345678;
uint32_t b := 0x01020304;
uint32_t result;
void main(void) { result := a + b; }
SRC
require_cells('plain', $plain, @startup) == 8
   or die "plain startup workspace is not eight bytes\n";

my $inline = build_case('workspace_inline', <<'SRC');
void main(void) {
   asm lda #$5a;
   asm sta tmp5;
}
SRC
require_cells('inline workspace reference', $inline, @startup, qw(tmp5)) == 9
   or die "inline workspace reference did not select exactly one extra byte\n";

my $div = build_case('workspace_div', <<'SRC');
uint32_t a := 0x12345678;
uint32_t b := 0x1234;
uint32_t result;
void main(void) { result := a / b; }
SRC
require_cells('division', $div, @startup, qw(ptr3 tmp0 tmp1)) == 12
   or die "division workspace is not twelve bytes\n";

my $asr = build_case('workspace_asr', <<'SRC');
int32_t a := -1234567;
uint8_t count := 5;
int32_t result;
void main(void) { result := a >> count; }
SRC
require_cells('arithmetic shift', $asr, @startup) == 8
   or die "fixed-width arithmetic-shift workspace is not eight bytes\n";

my $mul = build_case('workspace_mul', <<'SRC');
uint32_t a := 0x1234;
uint32_t b := 0x100;
uint32_t result;
void main(void) { result := a * b; }
SRC
require_cells('multiplication', $mul, @all_cells) == 16
   or die "multiplication workspace is not sixteen bytes\n";

my $empty_src = File::Spec->catfile($tmp, 'workspace_empty.c26');
my $empty_asm = File::Spec->catfile($tmp, 'workspace_empty.s');
write_file($empty_src, "include \"machine_6502.c26\"\nvoid main(void) {}\n");
system($cc1, '-quiet', '-I', $test_inc, $empty_src, '-o', $empty_asm) == 0
   or die "empty compiler probe failed\n";
my $generated = read_file($empty_asm);
$generated !~ /^\s*\.zpimport\s+_vcsc_(?:arg|ptr|tmp)/m
   or die "empty translation unit imports unused runtime workspace cells\n";

print "runtime workspace split ok: plain 8, direct 9, division 12, fixed shift 8, multiply 16 bytes\n";
