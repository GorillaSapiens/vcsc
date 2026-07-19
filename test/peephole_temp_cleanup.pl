#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;
use Cwd qw(abs_path);

my $test_root = dirname(abs_path($0));
my $tmp = abs_path($ARGV[0] // die "temporary directory argument is required\n")
   // die "could not resolve temporary directory\n";
my $unit = File::Spec->catfile($test_root, 'peephole_unit.pl');
my $prefix = 'VCSC_peephole_unit_';

local $ENV{TMPDIR} = $tmp;
my @before = glob(File::Spec->catfile($tmp, $prefix . '*'));
@before and die "pre-existing peephole scratch directory in test temp root: @before\n";

open my $child, '-|', $^X, $unit or die "could not run $unit: $!\n";
my $output = do { local $/; <$child> };
close $child or die "peephole unit child failed\n";
$output =~ /peephole unit tests passed/
   or die "peephole unit child did not report success\n";

my @after = glob(File::Spec->catfile($tmp, $prefix . '*'));
@after and die "peephole scratch directory leaked: @after\n";

print "peephole temp cleanup passed\n";
