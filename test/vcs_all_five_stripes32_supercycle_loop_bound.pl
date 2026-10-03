#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_supercycle_loop_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my $p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_supercycle_loop_bound.pl');
my $out=`perl '$p' 2>&1`; die "supercycle loop proof failed ($?)\n$out" if $?;
$out =~ /Y=95\.\.72\/71\.\.48\/47\.\.24\/23\.\.0/ or die "Y ranges changed\n$out";
$out =~ /BPL tails are 16\/16\/16 cycles/ or die "loop timing changed\n$out";
$out =~ /final fallthrough is 15/ or die "terminal timing changed\n$out";
print "vcs_all_five_stripes32_supercycle_loop_bound ok\n";
