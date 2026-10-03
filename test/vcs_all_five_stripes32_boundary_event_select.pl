#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_boundary_event_select ok
# expectexit: 0
use strict;
use warnings;
use File::Spec;
my($root,$tmp)=@ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my$solver=File::Spec->catfile($root,'libraries/vcs/renderers/kernel_schedule_search.pl');
my$problem=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_boundary_event_select_search.pl');
my$out=`perl '$solver' '$problem' 2>&1`;
die "boundary event schedule failed ($?)\n$out" if $?;
$out =~ /cpy\.z next_event_threshold/ or die "event threshold compare disappeared\n";
$out =~ /bcs\.same ordinary_boundary/ or die "ordinary event branch disappeared\n";
$out =~ /event GRP1\s+\@\s+380 \(5:02\)/ or die "boundary GRP1 phase changed\n$out";
$out =~ /event COLUPF\s+\@\s+387 \(5:09\)/ or die "COLUPF phase changed\n$out";
$out =~ /event COLUBK\s+\@\s+394 \(5:16\)/ or die "COLUBK phase changed\n$out";
$out =~ /event PF0L\s+\@\s+405 \(5:27\)/ or die "boundary PF0L phase changed\n$out";
$out =~ /event PF1L\s+\@\s+411 \(5:33\)/ or die "boundary PF1L phase changed\n$out";
$out =~ /event PF2L\s+\@\s+417 \(5:39\)/ or die "boundary PF2L phase changed\n$out";
$out =~ /event PF0R\s+\@\s+427 \(5:49\)/ or die "PF0R did not rejoin ordinary phase\n$out";
$out !~ /\bIDLE\b/ or die "boundary event schedule used fictitious idle cycles\n";
print "vcs_all_five_stripes32_boundary_event_select ok\n";
