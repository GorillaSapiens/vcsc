#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_transition_run_bound ok
# expectexit: 0
use strict;
use warnings;
use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my $p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_transition_run_bound.pl');
my $out=`perl '$p' 2>&1`; die "run bound failed ($?)\n$out" if $?;
$out =~ /packed event arena<=48 bytes .* total RIOT<=126, leaving 2 live control bytes/
   or die "run bound output changed: $out";
print "vcs_all_five_stripes32_transition_run_bound ok\n";
