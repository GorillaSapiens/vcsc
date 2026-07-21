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
   local $/; my $text = <$fh>;
   close($fh);
   return $text;
}

my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $ar = File::Spec->catfile($repo, 'archiver', 'vcsc-ar');
my $runtime = File::Spec->catdir($repo, 'libraries', 'runtime');
my $archive = File::Spec->catfile($runtime, 'libvcsc.l26');
my $test_inc = File::Spec->catdir($repo, 'test');

open(my $afh, '-|', $ar, 't', $archive) or die "cannot list $archive: $!\n";
my $members = do { local $/; <$afh> };
close($afh) or die "archive listing failed\n";
for my $name (qw(_mul8 _mul16 _mul24 _mul32 _div8 _div16 _div24 _div32)) {
   $members =~ /^\Q$name\E\.o26$/m or die "missing fixed helper $name\n";
}
for my $name (qw(_mulNle _divNle _remNle)) {
   $members !~ /^\Q$name\E\.o26$/m or die "obsolete generic helper remains: $name\n";
}

for my $width (8, 16, 24, 32) {
   my $type = "uint${width}_t";
   my $src = File::Spec->catfile($tmp, "fixed_muldiv_$width.c26");
   my $bin = File::Spec->catfile($tmp, "fixed_muldiv_$width.bin");
   my $map = File::Spec->catfile($tmp, "fixed_muldiv_$width.map");
   write_file($src, qq{include "machine_6502.c26"\n$type a := 200;\n$type b := 13;\n$type product;\n$type quotient;\n$type remainder;\nvoid main(void) { product := a * b; quotient := a / b; remainder := a % b; }\n});
   system($driver, '-I', $test_inc, '-Map', $map, $src, '-o', $bin) == 0
      or die "fixed $width-bit build failed\n";
   my $text = read_file($map);
   $text =~ /libvcsc\.l26\(_mul\Q$width\E\.o26\)/ or die "map lacks _mul$width\n";
   $text =~ /libvcsc\.l26\(_div\Q$width\E\.o26\)/ or die "map lacks _div$width\n";
   $text !~ /libvcsc\.l26\(_(?:mulNle|divNle|remNle)\.o26\)/ or die "map selected generic helper\n";
   $text !~ /libvcsc\.l26\(vcsc-zp-(?:ptr3|tmp[0-5])\.o26\)/ or die "fixed helper selected removed RAM\n";
   $text !~ /libvcsc\.l26\(_div\Q$width\E\.o26\).*?BSS\s+run=/s
      or die "_div$width still owns private BSS workspace\n";
}

print "fixed multiply/divide helpers use expression scratch and no extra RIOT RAM\n";
