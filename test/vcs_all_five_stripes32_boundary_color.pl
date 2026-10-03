#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_boundary_color ok
# expectexit: 0
use strict;
use warnings;
use File::Spec;
my($root,$tmp)=@ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my$solver=File::Spec->catfile($root,'libraries/vcs/renderers/kernel_schedule_search.pl');
my$problem=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_boundary_color_search.pl');
my$out=`perl '$solver' '$problem' 2>&1`;
die "boundary-color schedule failed ($?)\n$out" if $?;
$out =~ /event GRP1\s+\@\s+377 \(4:75\)/ or die "boundary GRP1 phase changed\n$out";
$out =~ /event COLUPF\s+\@\s+384 \(5:06\)/ or die "COLUPF handoff phase changed\n$out";
$out =~ /event COLUBK\s+\@\s+391 \(5:13\)/ or die "COLUBK handoff phase changed\n$out";
$out =~ /event PF0L\s+\@\s+402 \(5:24\)/ or die "boundary PF0L phase changed\n$out";
$out =~ /event PF2L\s+\@\s+414 \(5:36\)/ or die "boundary PF2L phase changed\n$out";
$out =~ /event PF0R\s+\@\s+427 \(5:49\)/ or die "PF0R did not rejoin ordinary phase\n$out";
$out =~ /event PF2R\s+\@\s+439 \(5:61\)/ or die "PF2R phase changed\n$out";
$out !~ /\bIDLE\b/ or die "boundary schedule used fictitious idle cycles\n";
my$layout=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_boundary_feed_layout.pl');
my$l=`perl '$layout' 2>&1`;
die "boundary feed layout failed ($?)\n$l" if $?;
$l =~ /pairs0\/1 carry PF0\.\.PF5; pair2 carries C0\/C1/ or die "boundary feed packing changed\n$l";
print "vcs_all_five_stripes32_boundary_color ok\n";
