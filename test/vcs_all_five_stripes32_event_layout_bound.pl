#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_event_layout_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined$root;
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_event_layout_bound.pl');
my$out=`perl '$p' 2>&1`; die "event-layout bound failed ($?)\n$out" if $?;
$out =~ /service-union=4 mixed-union=4; row-cache=4 inside mask scratch; hot-overlap=7 fixed=80; exact=16 pointer-high=4 composite=12 queued-threshold=3 event=35; live-threshold=1 saved-S=1 named=117; hardware-stack=6 physical=123\/128 slack=5/
 or die "event-layout output changed: $out";
print "vcs_all_five_stripes32_event_layout_bound ok\n";
