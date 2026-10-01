#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_common_index ok
# expectexit: 0

use strict;
use warnings;
use File::Spec;
my ($root,$tmp)=@ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my $solver=File::Spec->catfile($root,'libraries/vcs/renderers/kernel_schedule_search.pl');
my $ordinary=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe_pair_machine_search.pl');
my $stream=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_common_index_search.pl');
my $bound=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_common_index_bound.pl');
sub run {
   my ($cmd)=@_;
   my $out=`$cmd 2>&1`;
   die "$cmd failed ($?)\n$out" if $?;
   return $out;
}
my $o=run("VCSC_STRIPE_PAIR_MODE=ordinary VCSC_STRIPE_PAIR_COUNT=3 perl '$solver' '$ordinary'");
my $s=run("perl '$solver' '$stream'");
my $b=run("perl '$bound'");
$b =~ /common_index_bound ok/ or die "missing common-index bound success\n";
sub events {
   my ($x)=@_;
   my @e;
   for my $l (split /\n/,$x) {
      push @e,"$1:$2" if $l =~ /event\s+(\S+)\s+\@\s+(\d+)/;
   }
   return \@e;
}
my $oe=events($o); my $se=events($s);
@$oe==51 or die "ordinary event count !=51\n";
@$se==51 or die "stream event count !=51\n";
join('|',@$oe) eq join('|',@$se) or die "persistent-index TIA events differ from ordinary cadence\n";
$s !~ /\bldy\b/i or die "persistent-index schedule reloads/clobbers Y\n";
$s !~ /player[01]_y/i or die "persistent-index schedule touches public player Y\n";
my $dey=()=$s =~ /\+2\s+dey\b/gi;
$dey==3 or die "expected exactly three DEY, got $dey\n";
my $p1=()=$s =~ /lda\.iy \(p1_service_ptr\),y/gi;
my $p0=()=$s =~ /lda\.iy \(p0_service_ptr\),y/gi;
$p1==3 && $p0==3 or die "service-pointer loads changed p1=$p1 p0=$p0\n";
for my $i (0..5) {
   $s =~ /inactive_pf\+$i/ or die "missing PF destination $i\n";
}
for my $i (0..1) {
   $s =~ /next_color_slot\+$i/ or die "missing color destination $i\n";
}
my $f0=()=$s =~ /(?:ldx|lda)\.ay stripe_feed0,y/gi;
my $f1=()=$s =~ /(?:ldx|lda)\.ay stripe_feed1,y/gi;
my $f2=()=$s =~ /(?:ldx|lda)\.ay stripe_feed2,y/gi;
$f0==3 && $f1==3 && $f2==2
   or die "runtime Y-feed loads changed feed0=$f0 feed1=$f1 feed2=$f2\n";
$s !~ /next_stripe_(?:pf|color)/ or die "abstract unindexed stripe source survived\n";
my $tsx=()=$s =~ /\+2\s+tsx\b/gi;
$tsx==6 or die "expected packed-row TSX twice per pair, got $tsx\n";
for my $off (24..26) {
   $s =~ /object_masks\+$off,x/
      or die "missing packed object-mask lane $off\n";
}
$s !~ /current_(?:ball|m[01])_mask/
   or die "obsolete scalar current-mask source survived\n";
my $prep=0;
$prep += 5 * (()=$s =~ /dec\.z rolling_prepare_a/gi);
$prep += 3 * (()=$s =~ /sta\.z rolling_prepare_p1/gi);
$prep += 3 * (()=$s =~ /sta\.z rolling_prepare_p0_[0-2]/gi);
$prep==17 or die "expected 17 cycles of real per-stripe prep, got $prep\n";
$s !~ /\bIDLE\b/ or die "scheduler introduced fictitious IDLE cycles\n";
print "vcs_all_five_stripes32_common_index ok\n";
