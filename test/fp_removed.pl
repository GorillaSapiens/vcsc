#!/usr/bin/perl

use strict;
use warnings;
use File::Spec;
use Cwd qw(abs_path);

my $repo = abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(), '..'));
my $tmp = $ARGV[1] // die "temporary directory argument is required\n";

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return $text;
}

my $runtime = File::Spec->catdir($repo, 'libraries', 'runtime');
my $fp2ptr = File::Spec->catfile($runtime, 'asm', 'fp2ptr.asm');
-e $fp2ptr and die "obsolete fp2ptr helper source remains: $fp2ptr\n";

for my $path (
   File::Spec->catfile($runtime, 'vcsc-runtime.inc'),
   File::Spec->catfile($runtime, 'vcsc-rt0.s26'),
   glob(File::Spec->catfile($runtime, 'vcsc-zp-*.s26')),
) {
   my $text = slurp($path);
   $text =~ /_vcsc_fp|\.def\s+fp\b|\bfp2ptr\b/
      and die "obsolete frame-pointer ABI remains in $path\n";
}

my $linker = slurp(File::Spec->catfile($repo, 'linker', 'vcsc_ld.c'));
$linker =~ /bytes\s*=\s*\(uint32_t\)depth\s*\*\s*2u/
   or die "linker no longer reserves two hardware-stack bytes per call depth\n";
$linker =~ /if\s*\(init_count\s*>\s*0\)\s*bytes\s*\+=\s*2u/s
   or die "linker does not reserve the stock startup's init cursor\n";
$linker !~ /bytes\s*=\s*\(uint32_t\)depth\s*\*\s*4u/
   or die "linker still includes the old frame-pointer preservation allowance\n";

my $source = File::Spec->catfile($tmp, 'fp_name.c26');
my $asm = File::Spec->catfile($tmp, 'fp_name.s26');
open(my $src, '>', $source) or die "could not create $source: $!\n";
print {$src} <<'SRC';
include "machine_6502.c26"

uint8_t fp;

uint8_t plus_one(uint8_t value) {
   return value + 1;
}

void main(void) {
   fp := plus_one(6);
}
SRC
close($src) or die "could not close $source: $!\n";

my @cmd = (File::Spec->catfile($repo, 'compiler', 'vcsc-cc1'),
           '-quiet', '-I', File::Spec->catdir($repo, 'test'),
           $source, '-o', $asm);
system(@cmd) == 0 or die "could not compile frame-pointer-removal probe\n";
my $generated = slurp($asm);
$generated =~ /\bfp:/ or die "ordinary source identifier 'fp' is still unavailable\n";
$generated =~ /jsr\s+plus_one\b/ or die "probe did not contain its direct call\n";
$generated =~ /__vcsc_scratch_\d+,y/
   or die "generated code does not directly address static scratch\n";
$generated =~ /_vcsc_fp|\(fp\),y|\bfp\+1\b/
   and die "generated code still uses a runtime frame pointer\n";
$generated =~ /^\s*(?:pha|pla)\s*$/mi
   and die "ordinary direct call still pushes frame-pointer state\n";

my $archive = File::Spec->catfile($runtime, 'libvcsc.l26');
my $ar = File::Spec->catfile($repo, 'archiver', 'vcsc-ar');
open(my $members, '-|', $ar, 't', $archive)
   or die "could not list $archive: $!\n";
my $listing = do { local $/; <$members> };
close($members) or die "could not list $archive\n";
$listing =~ /fp2ptr/i and die "runtime archive still contains an fp2ptr member\n";

print "runtime frame pointer removed; static scratch is directly addressed\n";
