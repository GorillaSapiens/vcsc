#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_sixline_machine ok
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
$tmp=abs_path($tmp) // die "resolve temporary directory\n";
my $solver=File::Spec->catfile($repo,qw(libraries vcs renderers kernel_schedule_search.pl));
my $ordinary=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pair_machine_search.pl));
my $rolling=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe32_sixline_machine_search.pl));

local $ENV{VCSC_STRIPE_PAIR_MODE}='ordinary';
local $ENV{VCSC_STRIPE_PAIR_COUNT}=3;
my($rc,$sig,$o,$e)=capture($^X,$solver,'--max-solutions','1',$ordinary);
$rc==0&&!$sig or die "ordinary three-pair machine failed\n$o$e";
my @oe=($o =~ /^\s+event\s+.*$/mg);
@oe==51 or die "ordinary three-pair event count changed: ".scalar(@oe)."\n";

($rc,$sig,my $r,my $re)=capture($^X,$solver,'--max-solutions','1',$rolling);
$rc==0&&!$sig or die "stripes32 six-line machine failed\n$r$re";
$r =~ /^solution 1 for all_five stripes32 six-scanline rolling machine$/m
   or die "stripes32 rolling header missing\n$r";
$r =~ /line_cycles=76 horizon=456 phase_origin=2/
   or die "stripes32 rolling horizon changed\n$r";
my @revents=($r =~ /^\s+event\s+.*$/mg);
@revents==51 or die "stripes32 rolling event count changed: ".scalar(@revents)."\n";
join("\n",@revents) eq join("\n",@oe)
   or die "stripes32 rolling work moved a TIA appointment\n";
for my $n (0..5) {
   $r =~ /next_stripe_pf\+$n/ or die "stripes32 rolling machine lost PF byte $n\n";
   $r =~ /inactive_pf\+$n/ or die "stripes32 rolling machine lost inactive PF byte $n\n";
}
for my $n (0..1) {
   $r =~ /next_stripe_color\+$n/ or die "stripes32 rolling machine lost color source $n\n";
   $r =~ /next_color_slot\+$n/ or die "stripes32 rolling machine lost color destination $n\n";
}
$r =~ /ldy #2/ && $r =~ /ldy #1/ && $r =~ /ldy #0/
   or die "stripes32 rolling machine lost local player indices 2,1,0\n";
$r =~ /lda\.iy \(p1_service_ptr\),y/ && $r =~ /lda\.iy \(p0_service_ptr\),y/
   or die "stripes32 rolling machine lost pointer-fed players\n";
$r =~ /\btsx\b/ or die "stripes32 rolling machine no longer restores packed-row X from SP\n";
$r !~ /player[01]_y/ or die "stripes32 rolling machine mutates/reads public player Y in visible time\n";
$r !~ /cpy\.z .*height/ or die "stripes32 rolling machine reintroduced per-pair player height tests\n";
my $prep5=()=($r =~ /dec\.z rolling_prepare_/g);
my $prep3=()=($r =~ /sta\.z rolling_prepare_p1/g);
$prep5==4 && $prep3==1
   or die "stripes32 rolling preparation slots changed: prep5=$prep5 prep3=$prep3\n";
$r !~ /\bIDLE\b/ or die "stripes32 rolling machine contains fictitious idle time\n";
$re =~ /^searched=19 pruned_deadline=0 pruned_horizon=0 solutions=1\n\z/
   or die "unexpected stripes32 solver statistics: $re";
print "vcs_all_five_stripes32_sixline_machine ok\n";
