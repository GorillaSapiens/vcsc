#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_transition_handoff_rowfeed ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$s=File::Spec->catfile($root,'libraries/vcs/renderers/kernel_schedule_search.pl');
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_transition_handoff_rowfeed_search.pl');
my$out=`perl '$s' '$p' 2>&1`; die "rowfeed handoff failed ($?)\n$out" if $?;
$out =~ /stx\.z p0_service_ptr\+1/ or die "zero-page pointer-high store disappeared\n$out";
$out =~ /ldx\.ay packed_row_shadow,y/ or die "ROM,Y row-shadow restore disappeared\n$out";
$out =~ /event PF0R\s+\@\s+579 \(7:49\)/ or die "handoff PF0R phase changed\n$out";
$out =~ /event GRP0\s+\@\s+610 \(8:04\)/ or die "ordinary resume phase changed\n$out";
print "vcs_all_five_stripes32_transition_handoff_rowfeed ok\n";
