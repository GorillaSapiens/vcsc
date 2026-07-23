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

my $cc1 = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $ar = File::Spec->catfile($repo, 'archiver', 'vcsc-ar');
my $test_inc = File::Spec->catdir($repo, 'test');
my $runtime_dir = File::Spec->catdir($repo, 'libraries', 'runtime');
my $archive = File::Spec->catfile($runtime_dir, 'libvcsc.l26');

my @removed_sources = qw(stack.asm cmp.asm bitwise.asm);
for my $name (@removed_sources) {
   my $path = File::Spec->catfile($runtime_dir, 'asm', $name);
   !-e $path or die "removed generic runtime source remains: $path\n";
}

my @removed_members = qw(
   _cpyN _setN _zeroN _copyzxNle _copysxNle _swapN _comp2Nle
   _eqN _ltNsle _leNsle _ltNule _leNule
   _bit_andN _bit_orN _bit_xorN _bit_notN
   _lsl1le _lsr1le _asr1le _arg1Nle _lslNle _lsrNle _asrNle
   _mulNle _divNle _remNle
);
my @fixed_shift_members = qw(
   _shl8 _shl16 _shl24 _shl32
   _shr8 _shr16 _shr24 _shr32
   _sar8 _sar16 _sar24 _sar32
);
my @fixed_muldiv_members = qw(
   _mul8 _mul16 _mul24 _mul32
   _div8 _div16 _div24 _div32
);
my @object_members = qw(_copy_bytes _fill_bytes _zero_bytes);

open(my $afh, '-|', $ar, 't', $archive) or die "cannot list $archive: $!\n";
my $members = do { local $/; <$afh> };
close($afh) or die "archive listing failed for $archive\n";
for my $name (@removed_members) {
   $members !~ /^\Q$name\E\.o26$/m
      or die "removed generic scalar helper remains in archive: $name\n";
}
for my $name (@fixed_shift_members, @fixed_muldiv_members, @object_members) {
   $members =~ /^\Q$name\E\.o26$/m
      or die "required replacement helper missing from archive: $name\n";
}

my $compiler_text = '';
for my $path (sort glob(File::Spec->catfile($repo, 'compiler', '*.c')),
                  glob(File::Spec->catfile($repo, 'compiler', '*.h'))) {
   $compiler_text .= read_file($path);
}
for my $name (@removed_members) {
   $compiler_text !~ /\Q$name\E/
      or die "compiler still references removed generic scalar helper: $name\n";
}

my $scalar_src = File::Spec->catfile($tmp, 'fixed_scalar_runtime.c26');
my $scalar_asm = File::Spec->catfile($tmp, 'fixed_scalar_runtime.s26');
my $scalar_bin = File::Spec->catfile($tmp, 'fixed_scalar_runtime.bin');
my $scalar_map = File::Spec->catfile($tmp, 'fixed_scalar_runtime.map');
write_file($scalar_src, <<'SRC');
include "machine_6502.c26"
uint8_t count;
uint8_t a8, b8, r8;
uint16_t a16, b16, r16;
int24_t a24, b24, r24;
uint32_t a32, b32, r32;
void main(void) {
   r8 := (a8 & b8) ^ (uint8_t)(-a8);
   r16 := a16 | b16;
   r24 := a24 < b24;
   r32 := a32 <= b32;
   r32 := (uint32_t)a8;
   r8 := a8 << count;
   r16 := a16 >> count;
   r24 := a24 >> count;
   r32 := a32 << count;
}
SRC
system($cc1, '-quiet', '-I', $test_inc, $scalar_src, '-o', $scalar_asm) == 0
   or die "fixed scalar compiler probe failed\n";
my $generated = read_file($scalar_asm);
for my $name (@removed_members, @object_members) {
   $generated !~ /\Q$name\E/
      or die "scalar lowering references non-scalar or removed helper: $name\n";
}
for my $name (qw(_shl8 _shr16 _sar24 _shl32)) {
   $generated =~ /^\.import \Q$name\E$/m
      or die "scalar lowering did not select $name\n";
   $generated =~ /jsr \Q$name\E/
      or die "scalar lowering did not call $name\n";
}
$generated =~ /\band\s+__vcsc_scratch_/ &&
$generated =~ /\bora\s+__vcsc_scratch_/ &&
$generated =~ /\beor\s+__vcsc_scratch_/ &&
$generated =~ /cmp_(?:true|false|same_sign)_/
   or die "bitwise/comparison scalar operations were not lowered inline\n";

system($driver, '-I', $test_inc, '-Map', $scalar_map,
       $scalar_src, '-o', $scalar_bin) == 0
   or die "fixed scalar link probe failed\n";
my $map = read_file($scalar_map);
my %cells;
while ($map =~ /libvcsc\.l26\(vcsc-zp-([A-Za-z0-9_]+)\.o26\)/g) {
   $cells{$1} = 1;
}
my $got_cells = join(',', sort keys %cells);
my $want_cells = 'arg0,arg1,ptr0,ptr1,ptr2';
$got_cells eq $want_cells
   or die "fixed scalar program linked workspace {$got_cells}, expected {$want_cells}\n";

my $aggregate_src = File::Spec->catfile($tmp, 'aggregate_zero.c26');
my $aggregate_asm = File::Spec->catfile($tmp, 'aggregate_zero.s26');
write_file($aggregate_src, <<'SRC');
include "machine_6502.c26"
struct Blob { uint8_t bytes[6]; };
Blob value;
void main(void) { value := { 1 }; }
SRC
system($cc1, '-quiet', '-I', $test_inc, $aggregate_src, '-o', $aggregate_asm) == 0
   or die "aggregate object-helper probe failed\n";
my $aggregate = read_file($aggregate_asm);
$aggregate =~ /^\.import _zero_bytes$/m && $aggregate =~ /jsr _zero_bytes/
   or die "object wider than four bytes no longer selects aggregate zero helper\n";

print "fixed scalar runtime ok: inline scalar ops, fixed shifts/mul/div, 8-byte workspace\n";
