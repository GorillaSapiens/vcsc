#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripe_supercycle_event_compose_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$dir=File::Spec->catdir($root,'libraries','vcs','renderers','all_five');
my$p=File::Spec->catfile($dir,'stripe_supercycle_event_compose_bound.pl');
local$ENV{VCSC_ALL_FIVE_DIR}=$dir;
my$out=`perl '$p' 2>&1`; die "supercycle event composition ledger failed ($?)\n$out" if $?;

# The 16-cycle pair-2 tail envelope and the ordinary composition must both hold.
$out =~ /pair-2 tail envelope=16/
   or die "pair-2 tail envelope changed: $out";
$out =~ /ordinary non-final=16 and supercycle-final=16 \(loop tail cycle-neutral, terminal fall-through 15 absorbed by WSYNC\)/
   or die "ordinary supercycle composition is no longer cycle-neutral: $out";

# The event path is resolved by hoisting the install into p0_mid, and the bound
# must state both the old cost and the new split so the saving stays auditable.
$out =~ /event pair-2 obligations went from 21 cycles in one envelope to 16 in the tail plus 13 in p0_mid's own 18-cycle span/
   or die "event pair-2 composition changed: $out";
$out =~ /all 51 TIA appointments on their ordinary cycles and no idle time/
   or die "composed schedule moved a TIA appointment or used idle time: $out";

# The resolution must not buy cycles with RAM, and the known-incomplete high-only
# skeleton must stay visible.
$out =~ /no obligation dropped and no extra cycle budget or third control byte, so RIOT stays 123\/128/
   or die "composition regressed into extra RAM: $out";
$out =~ /high-only skeleton still carries 0 PF copies so it may not be emitted as-is/
   or die "high-only skeleton incompleteness is no longer reported: $out";

# One composition result must serve the whole generic range.
$out =~ /independent of TEMPLATE_stripes and TEMPLATE_lines so one result serves the generic 2\.\.32 range/
   or die "composition is no longer generic in stripes and lines: $out";

print "vcs_all_five_stripe_supercycle_event_compose_bound ok\n";