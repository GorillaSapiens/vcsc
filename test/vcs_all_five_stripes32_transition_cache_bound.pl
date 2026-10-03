#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_transition_cache_bound ok
# expectexit: 0
use strict;
use warnings;
use File::Spec;
my ($root,$tmp)=@ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my $proof=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_transition_cache_bound.pl');
my $out=`perl '$proof' 2>&1`;
die "transition-cache bound failed ($?)\n$out" if $?;
$out =~ /one<=2 special stripes, union<=4, run<=4, runs<=4, special pixels<=12 bytes, extended exact-player<=16, complete handoff payload<=40, bounded RIOT=118; exact fragmented handoff schedule proved separately/
   or die "transition-cache output changed: $out";
print "vcs_all_five_stripes32_transition_cache_bound ok\n";
