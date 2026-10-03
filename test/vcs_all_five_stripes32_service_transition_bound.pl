#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_service_transition_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$proof=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_service_transition_bound.pl');
my$out=`perl '$proof' 2>&1`; die "service transition bound failed ($?)\n$out" if $?;
$out =~ /rainbow fixture P0=3m\/6b P1=16b\/18m/ or die "rainbow transition shape missing\n$out";
print "vcs_all_five_stripes32_service_transition_bound ok\n";
