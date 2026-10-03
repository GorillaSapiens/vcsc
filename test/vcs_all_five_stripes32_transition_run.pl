#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_transition_run ok
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
my $repo=shift @ARGV // usage(); my$tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo);
my $solver=File::Spec->catfile($repo,qw(libraries vcs renderers kernel_schedule_search.pl));
my $ordinary=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pair_machine_search.pl));
my $cont=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe32_transition_run_search.pl));
my $handoff=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe32_transition_handoff_search.pl));
local $ENV{VCSC_STRIPE_PAIR_MODE}='ordinary'; local $ENV{VCSC_STRIPE_PAIR_COUNT}=3;
my($rc,$sig,$o,$e)=capture($^X,$solver,'--max-solutions','1',$ordinary);
$rc==0&&!$sig or die "ordinary schedule failed\n$o$e";
($rc,$sig,my$c,my$ce)=capture($^X,$solver,'--max-solutions','1',$cont);
$rc==0&&!$sig or die "continuation schedule failed\n$c$ce";
my @oe=($o =~ /^\s+event\s+.*$/mg); my @ce=($c =~ /^\s+event\s+.*$/mg);
@oe==51 && @ce==51 or die "event count changed\n";
join("\n",@oe) eq join("\n",@ce) or die "cached continuation moved TIA appointment\n";
my $p1=()=$c =~ /lda\.z run_p1\+[012]\b/g; my$p0=()=$c =~ /lda\.z run_p0\+[012]\b/g;
$p1==3 && $p0==3 or die "cached continuation exact bytes p1=$p1 p0=$p0\n";
$c !~ /st[ax]\.z p[01]_service_ptr/ or die "continuation modified a service pointer\n";
my $dey=()=$c =~ /\+2\s+dey\b/g; $dey==3 or die "continuation DEY count=$dey\n";
$c !~ /\b(?:pha|pla|php|plp)\b/i or die "continuation used hardware stack\n";
# The separately maintained final block must still prove the actual pointer
# installation and ordinary resume; together with this boundary-neutral stripe,
# the continuation can repeat up to the independently bounded run length four.
($rc,$sig,my$h,my$he)=capture($^X,$solver,'--max-solutions','1',$handoff);
$rc==0&&!$sig or die "final handoff schedule failed\n$h$he";
$h =~ /stx\.z p1_service_ptr\b/ && $h =~ /stx\.z p0_service_ptr\b/
   or die "final handoff lost pointer commits\n";
$h =~ /p4_p1_feed.*?lda\.iy \(p1_service_ptr\),y/s &&
$h =~ /p4_p0_feed.*?lda\.iy \(p0_service_ptr\),y/s
   or die "final handoff no longer resumes ordinary service\n";
print "vcs_all_five_stripes32_transition_run ok\n";
