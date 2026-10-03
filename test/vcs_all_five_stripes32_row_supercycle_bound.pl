#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_row_supercycle_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_row_supercycle_bound.pl');
my$out=`perl '$p' 2>&1`; die "row-supercycle bound failed ($?)\n$out" if $?;
$out =~ /24-pair\/8-stripe supercycle repeated 4x; row handoffs s2p1,s5p0,s7p2; 11 visible handoffs; compact lanes 0\/12\/24 cover 36 mask bytes/
 or die "row-supercycle output changed: $out";
print "vcs_all_five_stripes32_row_supercycle_bound ok\n";
