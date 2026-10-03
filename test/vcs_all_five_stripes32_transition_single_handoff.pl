#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_transition_single_handoff ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp { my($fh)=@_; local $/; my$s=<$fh>; return defined($s)?$s:''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp($o); my$se=slurp($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo);
my $solver=File::Spec->catfile($repo,qw(libraries vcs renderers kernel_schedule_search.pl));
my $ordinary=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pair_machine_search.pl));
my $single=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe32_transition_single_handoff_search.pl));
local $ENV{VCSC_STRIPE_PAIR_MODE}='ordinary'; local $ENV{VCSC_STRIPE_PAIR_COUNT}=5;
my($rc,$sig,$o,$e)=capture($^X,$solver,'--max-solutions','1',$ordinary);
$rc==0&&!$sig or die "ordinary schedule failed\n$o$e";
my @oe=($o =~ /^\s+event\s+.*$/mg); @oe==85 or die "ordinary events !=85\n";
for my $who (qw(p1 p0)) {
   local $ENV{VCSC_STRIPE_TRANSITION_PLAYER}=$who;
   ($rc,$sig,my$s,my$se)=capture($^X,$solver,'--max-solutions','1',$single);
   $rc==0&&!$sig or die "$who handoff failed\n$s$se";
   my @sevents=($s =~ /^\s+event\s+.*$/mg); @sevents==85 or die "$who event count !=85\n";
   join("\n",@sevents) eq join("\n",@oe) or die "$who handoff moved TIA appointment\n";
   my $special=()=$s =~ /lda\.z special_${who}\+[012]\b/g;
   $special==3 or die "$who special exact-cache count=$special, expected 3\n";
   my $handoff=()=$s =~ /lda\.z handoff_p0\b/g;
   $handoff==1 or die "$who handoff exact-cache count=$handoff, expected 1\n";
   my $ptr=$who eq 'p1' ? 'p1_service_ptr' : 'p0_service_ptr';
   $s =~ /stx\.z \Q$ptr\E\b/ or die "$who low pointer byte not committed\n";
   $s =~ /stx\.z \Q$ptr\E\+1\b/ or die "$who high pointer byte not committed\n";
   $s =~ /ldx\.z handoff_row_shadow.*?\+2\s+txs/s or die "$who row shadow not restored\n";
   $s =~ /p4_p1_feed.*?lda\.iy \(p1_service_ptr\),y/s or die "$who P1 did not resume indirect service\n";
   $s =~ /p4_p0_feed.*?lda\.iy \(p0_service_ptr\),y/s or die "$who P0 did not resume indirect service\n";
   $s !~ /\b(?:pha|pla|php|plp)\b/i or die "$who handoff used hardware stack\n";
   $s !~ /\bIDLE\b/ or die "$who scheduler introduced fictitious IDLE\n";
}
print "vcs_all_five_stripes32_transition_single_handoff ok\n";
