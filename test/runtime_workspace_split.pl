#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# expectexit: 0
# expectstdout: runtime workspace reduced: stock startup uses 4 bytes; mul/div/rem pull ptr2 only when needed

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
my $generic_cfg = File::Spec->catfile($test_inc, 'generic_6502.cfg');
my $runtime = File::Spec->catdir($repo, 'libraries', 'runtime');
my $archive = File::Spec->catfile($runtime, 'libvcsc.l26');
my @workspace = qw(arg0 arg1 ptr0 ptr1 ptr2);
my @startup_workspace = qw(ptr0 ptr1);
my @wide_math_workspace = qw(ptr0 ptr1 ptr2);
my @removed = qw(ptr3 tmp0 tmp1 tmp2 tmp3 tmp4 tmp5);

open(my $afh, '-|', $ar, 't', $archive) or die "cannot list $archive: $!\n";
my $members = do { local $/; <$afh> };
close($afh) or die "archive listing failed for $archive\n";
for my $cell (@workspace) {
   $members =~ /^vcsc-zp-\Q$cell\E\.o26$/m
      or die "runtime archive lacks required $cell workspace member\n";
}
for my $cell (@removed) {
   $members !~ /^vcsc-zp-\Q$cell\E\.o26$/m
      or die "obsolete runtime workspace member remains: $cell\n";
   !-e File::Spec->catfile($runtime, "vcsc-zp-$cell.s26")
      or die "obsolete runtime workspace source remains: $cell\n";
}

my $inc = read_file(File::Spec->catfile($runtime, 'vcsc-runtime.inc'));
$inc !~ /^\s*\.importzp\b/m
   or die "vcsc-runtime.inc imports workspace unconditionally\n";
$inc !~ /\b(?:ptr3|tmp[0-5])\b/
   or die "vcsc-runtime.inc still aliases removed workspace\n";

sub build_case {
   my ($name, $source) = @_;
   my $src = File::Spec->catfile($tmp, "$name.c26");
   my $out = File::Spec->catfile($tmp, "$name.bin");
   my $map = File::Spec->catfile($tmp, "$name.map");
   write_file($src, "include \"machine_6502.c26\"\n" . $source);
   system($driver, '-I', $test_inc, '-T', $generic_cfg, '-Map', $map, $src, '-o', $out) == 0
      or die "$name build failed\n";
   return read_file($map);
}

sub require_workspace {
   my ($name, $map, @want_cells) = @_;
   my %seen;
   while ($map =~ /libvcsc\.l26\(vcsc-zp-([A-Za-z0-9_]+)\.o26\)/g) {
      $seen{$1} = 1;
   }
   my $got = join(',', sort keys %seen);
   my $want = join(',', sort @want_cells);
   $got eq $want or die "$name linked workspace {$got}, expected {$want}\n";
}


my $plain_map = build_case('workspace_plain', <<'SRC');
uint32_t a := 0x12345678;
uint32_t b := 0x01020304;
uint32_t result;
void main(void) { result := a + b; }
SRC
require_workspace('plain', $plain_map, @startup_workspace);

my $mul_map = build_case('workspace_mul', <<'SRC');
uint32_t a := 0x1234;
uint32_t b := 0x100;
uint32_t result;
void main(void) { result := a * b; }
SRC
require_workspace('multiplication', $mul_map, @wide_math_workspace);

my $div_map = build_case('workspace_div', <<'SRC');
uint32_t a := 0x12345678;
uint32_t b := 0x1234;
uint32_t result;
void main(void) { result := a / b; }
SRC
require_workspace('division', $div_map, @wide_math_workspace);

my $rem_map = build_case('workspace_rem', <<'SRC');
uint32_t a := 0x12345678;
uint32_t b := 0x1234;
uint32_t result;
void main(void) { result := a % b; }
SRC
require_workspace('remainder', $rem_map, @wide_math_workspace);

my $empty_src = File::Spec->catfile($tmp, 'workspace_empty.c26');
my $empty_asm = File::Spec->catfile($tmp, 'workspace_empty.s26');
write_file($empty_src, "include \"machine_6502.c26\"\nvoid main(void) {}\n");
system($cc1, '-quiet', '-I', $test_inc, $empty_src, '-o', $empty_asm) == 0
   or die "empty compiler probe failed\n";
my $generated = read_file($empty_asm);
$generated !~ /^\s*\.zpimport\s+_vcsc_(?:arg|ptr|tmp)/m
   or die "empty translation unit imports runtime workspace\n";

print "runtime workspace reduced: stock startup uses 4 bytes; mul/div/rem pull ptr2 only when needed\n";
