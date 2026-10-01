#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_record_common_index_bound ok
# expectexit: 0

use strict;
use warnings;
use File::Spec;
my ($root,$tmp)=@ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my $proof=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_record_common_index_bound.pl');
my $out=`perl '$proof' 2>&1`;
die "record/common-index bound failed ($?)\n$out" if $?;
$out =~ /both are consumed by PF/ or die "missing direct-record source bound\n";
print "vcs_all_five_stripes32_record_common_index_bound ok\n";
