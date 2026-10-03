#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_event_layout_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined$root;
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_event_layout_bound.pl');
my$out=`perl '$p' 2>&1`; die "event-layout bound failed ($?)\n$out" if $?;
$out =~ /fixed-event=48; base\+stripe=78; live-control=2; RIOT=128; exact caches have fixed zero-page addresses/
 or die "event-layout output changed: $out";
print "vcs_all_five_stripes32_event_layout_bound ok\n";
