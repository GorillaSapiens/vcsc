#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_record_source ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp { my($fh)=@_; local $/; my $s=<$fh>; return defined($s)?$s:''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp($o); my$se=slurp($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo); $tmp=abs_path($tmp);
my $solver=File::Spec->catfile($repo,qw(libraries vcs renderers kernel_schedule_search.pl));
my $ordinary=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe_pair_machine_search.pl));
my $record=File::Spec->catfile($repo,qw(libraries vcs renderers all_five stripe32_record_source_search.pl));
local $ENV{VCSC_STRIPE_PAIR_MODE}='ordinary'; local $ENV{VCSC_STRIPE_PAIR_COUNT}=3;
my($rc,$sig,$o,$e)=capture($^X,$solver,'--max-solutions','1',$ordinary);
$rc==0&&!$sig or die "ordinary schedule failed\n$o$e";
my @oe=($o =~ /^\s+event\s+.*$/mg); @oe==51 or die "ordinary events !=51\n";
($rc,$sig,my$r,my$re)=capture($^X,$solver,'--max-solutions','1',$record);
$rc==0&&!$sig or die "record schedule failed\n$r$re";
my @re=($r =~ /^\s+event\s+.*$/mg); @re==51 or die "record events !=51\n";
join("\n",@oe) eq join("\n",@re) or die "record source moved a TIA appointment\n";
$r =~ /runtime-indexed record machine/ or die "record machine header missing\n";
for my $f (0..7) { $r =~ /stripe_record(?:[+-]\d+)?,x/ or die "record indexed source syntax missing\n"; }
for my $n (0..5) { $r =~ /inactive_pf\+$n/ or die "missing PF destination $n\n"; }
$r =~ /next_color_slot\+0/ && $r =~ /next_color_slot\+1/ or die "missing color destinations\n";
my $inx=()=($r =~ /\+2\s+inx\b/g); $inx==8 or die "record advance is $inx INX, expected 8\n";
$r =~ /bne\.same stripe_epoch_loop/ or die "record machine lost in-tail stripe loop\n";
$r =~ /sta\.a GRP1/ or die "pair2 absolute GRP1 compensation missing\n";
$r !~ /player[01]_y/ or die "record machine touched public player Y\n";
$r !~ /\bIDLE\b/ or die "record machine introduced fictitious IDLE\n";
print "vcs_all_five_stripes32_record_source ok\n";
