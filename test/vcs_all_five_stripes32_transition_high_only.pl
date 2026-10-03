#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_transition_high_only ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined$root;
my$solver=File::Spec->catfile($root,'libraries/vcs/renderers/kernel_schedule_search.pl');
my$problem=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_transition_high_only_search.pl');
for my$who(qw(p0 p1)){
 local$ENV{VCSC_STRIPE_TRANSITION_PLAYER}=$who;
 my$out=`perl '$solver' '$problem' 2>&1`; die "$who high-only transition failed ($?)\n$out" if $?;
 $out =~ /event COLUPF\s+\@\s+387 \(5:09\)/ or die "$who COLUPF changed\n$out";
 $out =~ /event COLUBK\s+\@\s+394 \(5:16\)/ or die "$who COLUBK changed\n$out";
 $out =~ /event PF0R\s+\@\s+427 \(5:49\)/ or die "$who PF0R changed\n$out";
 $out =~ /stx\.z ${who}_service_ptr\+1/ or die "$who service high was not installed\n$out";
 $out !~ /handoff_(?:ball|m1|m0)_pf0/ or die "$who unexpectedly needs nonplayer composite\n$out";
 $out !~ /\bIDLE\b/ or die "$who used fictitious idle cycles\n$out";
}
print "vcs_all_five_stripes32_transition_high_only ok\n";
