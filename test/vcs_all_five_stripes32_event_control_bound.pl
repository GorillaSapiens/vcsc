#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_event_control_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_event_control_bound.pl');
my$out=`perl '$p' 2>&1`; die "event-control bound failed ($?)\n$out" if $?;
$out =~ /current threshold=1 \+ queued thresholds=3; event type is threshold-encoded and p0\/p1 cache incidence is control-flow state, so descriptor metadata RAM=0/
 or die "event-control output changed: $out";
print "vcs_all_five_stripes32_event_control_bound ok\n";
