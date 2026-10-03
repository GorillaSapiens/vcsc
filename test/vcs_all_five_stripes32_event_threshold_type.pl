#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_event_threshold_type ok
# expectexit: 0
use strict;
use warnings;
use File::Spec;
my($root,$tmp)=@ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_event_threshold_type_bound.pl');
my$out=`perl '$p' 2>&1`;
die "threshold/type bound failed ($?)\n$out" if $?;
$out =~ /threshold mod 3 encodes p0\/p1\/dual/ or die "threshold/type output changed: $out";
print "vcs_all_five_stripes32_event_threshold_type ok\n";
