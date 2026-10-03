#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_transition_handoff ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
my $solver=File::Spec->catfile($repo,qw(libraries vcs renderers kernel_schedule_search.pl));
my $ordinary=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pair_machine_search.pl));
my $handoff=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe32_transition_handoff_search.pl));
sub run_solver {
   my ($path,$count)=@_;
   local $ENV{VCSC_STRIPE_PAIR_MODE}='ordinary';
   local $ENV{VCSC_STRIPE_PAIR_COUNT}=$count if defined $count;
   my($rc,$sig,$o,$e)=capture($^X,$solver,'--max-solutions','1',$path);
   die "$path failed\n$o$e" if $rc||$sig;
   return ($o,$e);
}
my($o,$oe)=run_solver($ordinary,5);
my($h,$he)=run_solver($handoff,undef);
my @oevents=($o =~ /^\s+event\s+.*$/mg);
my @hevents=($h =~ /^\s+event\s+.*$/mg);
@oevents==85 or die "ordinary five-pair event count changed: ".scalar(@oevents)."\n";
@hevents==85 or die "handoff event count changed: ".scalar(@hevents)."\n";
join("\n",@oevents) eq join("\n",@hevents)
   or die "transition handoff moved a TIA appointment\n";
for my $x (qw(next_p1_ptr_lo next_p1_ptr_hi next_p0_ptr_lo next_p0_ptr_hi)) {
   $h =~ /\Q$x\E/ or die "missing pointer source $x\n";
}
$h =~ /stx\.z p1_service_ptr\b/ or die "missing P1 low commit\n";
$h =~ /stx\.z p1_service_ptr\+1/ or die "missing P1 high commit\n";
$h =~ /stx\.z p0_service_ptr\b/ or die "missing P0 low commit\n";
$h =~ /stx\.a p0_service_ptr\+1/ or die "missing P0 high commit\n";
my $txs=()=$h =~ /\+2\s+txs\b/gi;
$txs>=3 or die "expected SP carrier/restoration TXS operations, got $txs\n";
$h =~ /handoff_ball_pf0/ && $h =~ /handoff_m1_pf0/ && $h =~ /handoff_m0_pf0/
   or die "missing composite handoff bytes\n";
$h =~ /handoff_row_shadow/ or die "missing packed-row shadow restoration\n";
# Pair 4 proves both ordinary indirect players and all indexed object masks are
# live again after the handoff.
$h =~ /p4_p1_feed.*?lda\.iy \(p1_service_ptr\),y/s or die "P1 did not resume indirect service\n";
$h =~ /p4_p0_feed.*?lda\.iy \(p0_service_ptr\),y/s or die "P0 did not resume indirect service\n";
for my $off (24..26) {
   $h =~ /p4_.*?object_masks\+$off,x/s or die "ordinary object-mask lane $off did not resume\n";
}
$h !~ /\b(?:pha|pla|php|plp)\b/i or die "transition handoff used the hardware stack\n";
$h !~ /\bIDLE\b/ or die "scheduler introduced fictitious IDLE cycles\n";
print "vcs_all_five_stripes32_transition_handoff ok\n";
