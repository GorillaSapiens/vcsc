#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_transition_boundary_high ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$solver=File::Spec->catfile($root,'libraries/vcs/renderers/kernel_schedule_search.pl');
my$problem=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_transition_boundary_high_search.pl');
for my$who(qw(p0 p1)) {
   local$ENV{VCSC_STRIPE_BOUNDARY_PLAYER}=$who;
   my$out=`perl '$solver' '$problem' 2>&1`; die "$who boundary-high transition failed ($?)\n$out" if $?;
   $out =~ /event GRP1\s+\@\s+380 \(5:02\)/ or die "$who GRP1 phase changed\n$out";
   $out =~ /event COLUPF\s+\@\s+387 \(5:09\)/ or die "$who COLUPF phase changed\n$out";
   $out =~ /event COLUBK\s+\@\s+394 \(5:16\)/ or die "$who COLUBK phase changed\n$out";
   $out =~ /event PF0R\s+\@\s+427 \(5:49\)/ or die "$who PF0R phase changed\n$out";
   $out =~ /ldx\.z next_${who}_hi.*?stx\.z ${who}_service_ptr\+1/s or die "$who high-byte carrier missing\n$out";
   $out =~ /lda\.z boundary_exact_p0/ or die "$who exact current P0 repayment missing\n$out";
   $out !~ /\bIDLE\b/ or die "$who used fictitious idle cycles\n$out";
}
print "vcs_all_five_stripes32_transition_boundary_high ok\n";
