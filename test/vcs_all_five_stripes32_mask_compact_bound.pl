#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_mask_compact_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my $p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_mask_compact_bound.pl');
my $out=`perl '$p' 2>&1`; die "mask compact proof failed ($?)\n$out" if $?;
$out =~ /35 temp-free moves, 210 VBLANK cycles, 140 ROM bytes/ or die "compaction cost changed\n$out";
print "vcs_all_five_stripes32_mask_compact_bound ok\n";
