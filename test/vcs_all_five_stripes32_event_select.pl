#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_event_select ok
# expectexit: 0
use strict;
use warnings;
use File::Spec;
my ($root,$tmp)=@ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my $solver=File::Spec->catfile($root,'libraries/vcs/renderers/kernel_schedule_search.pl');
my $ordinary=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe_pair_machine_search.pl');
my $select=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_event_select_search.pl');
my $bound=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_event_threshold_bound.pl');
sub run { my($cmd)=@_; my$out=`$cmd 2>&1`; die "$cmd failed ($?)\n$out" if $?; return $out; }
my $o=run("VCSC_STRIPE_PAIR_MODE=ordinary VCSC_STRIPE_PAIR_COUNT=3 perl '$solver' --max-solutions 1 '$ordinary'");
my $s=run("perl '$solver' --max-solutions 1 '$select'");
my $b=run("perl '$bound'");
$b =~ /event_threshold_bound ok/ or die "threshold proof did not report success\n";
sub events { my($x)=@_; my@e; for(split/\n/,$x){push@e,"$1:$2" if /event\s+(\S+)\s+\@\s+(\d+)/} return \@e; }
my$oe=events($o);my$se=events($s);
@$oe==51 && @$se==51 or die "event count changed\n";
join('|',@$oe) eq join('|',@$se) or die "event selector moved a TIA appointment\n";
my$cpy=()=$s =~ /cpy\.z next_event_threshold/gi;
my$bcs=()=$s =~ /bcs\.same ordinary_stripe_continue/gi;
$cpy==1 && $bcs==1 or die "expected one CPY/BCS selector, got cpy=$cpy bcs=$bcs\n";
$s =~ /\+3\s+cpy\.z next_event_threshold.*?\+2\s+nop/s
   or die "event compare no longer occupies exact five-cycle A slot\n";
$s =~ /\+3\s+bcs\.same ordinary_stripe_continue/s
   or die "ordinary branch no longer occupies exact three-cycle P1 slot\n";
# The instructions between CPY and BCS may alter N/Z but must not alter C.
my($between)=$s =~ /cpy\.z next_event_threshold(.*?)bcs\.same ordinary_stripe_continue/s;
defined $between or die "could not isolate CPY..BCS corridor\n";
$between !~ /\b(?:adc|sbc|cmp|cpy|cpx|asl|lsr|rol|ror|clc|sec)\b/i
   or die "carry-clobbering instruction entered event-select corridor:$between\n";
print "vcs_all_five_stripes32_event_select ok\n";
