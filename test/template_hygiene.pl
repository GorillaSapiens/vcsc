#!/usr/bin/env perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# expectexit: 0
# expectstdout: template global-name tests passed

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);

my ($cc1, $test_root) = @ARGV;
die "usage: $0 vcsc-cc1 test_root\n" if !defined $cc1 || !defined $test_root;

sub write_file {
   my ($path, $text) = @_;
   open my $fh, '>', $path or die "write $path: $!";
   print {$fh} $text;
   close $fh;
}

# Instantiation does not require TEMPLATE/TEMPLATE_ names. Ordinary parameter
# names substitute directly, and ordinary bank/mem names remain visible after
# the instantiated file. TEMPLATE_ remains the opt-in namespacing tool.
{
   my $tmp = tempdir('VCSC_template_plain_names_XXXX', TMPDIR => 1, CLEANUP => 1);
   my $component = File::Spec->catfile($tmp, 'component.c26');
   my $main = File::Spec->catfile($tmp, 'main.c26');
   my $asm = File::Spec->catfile($tmp, 'out.s26');
   write_file($component, <<'C26');
parameter banks;
#if banks == 1
bank bank0 { $image_size:0x1000 $file_index:0 $image_offset:0 $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000 $startup };
mem bank0 { $start:0xf000 $size:0x0ffa $ro $bank:bank0 };
#endif
C26
   write_file($main, <<'C26');
include "machine_6502.c26"
instantiate "component.c26" as one (banks:=1)
bank0 void main(void) {}
C26
   my @cmd = ($cc1, '-quiet', '-I', $test_root, '-I', $tmp, $main, '-o', $asm);
   system(@cmd) == 0 or die "ordinary names/parameters in instantiated source were rejected: @cmd\n";
}

{
   my $tmp = tempdir('VCSC_template_prefixed_names_XXXX', TMPDIR => 1, CLEANUP => 1);
   my $component = File::Spec->catfile($tmp, 'component.c26');
   my $main = File::Spec->catfile($tmp, 'main.c26');
   my $asm = File::Spec->catfile($tmp, 'out.s26');
   write_file($component, <<'C26');
uint8_t TEMPLATE_value;
inline void TEMPLATE_touch(void) { TEMPLATE_value := 1; }
C26
   write_file($main, <<'C26');
include "machine_6502.c26"
instantiate "component.c26" as first
instantiate "component.c26" as second
void main(void) { first_touch(); second_touch(); }
C26
   my @cmd = ($cc1, '-quiet', '-I', $test_root, '-I', $tmp, $main, '-o', $asm);
   system(@cmd) == 0 or die "TEMPLATE_ opt-in namespacing stopped working: @cmd\n";
}

print "template global-name tests passed\n";
