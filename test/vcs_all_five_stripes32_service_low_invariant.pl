#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_service_low_invariant ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined$root;
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_service_low_invariant.pl');
my$out=`perl '$p' 2>&1`; die "service-low proof failed ($?)\n$out" if $?;
$out =~ /only high changes at transitions; page-aligned zero slab=351 bytes/
 or die "service-low output changed: $out";
print "vcs_all_five_stripes32_service_low_invariant ok\n";
