#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripes32_feed_layout ok
# expectexit: 0

use strict;
use warnings;
use File::Spec;
my ($root,$tmp)=@ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my $proof=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe32_feed_layout.pl');
my $out=`perl '$proof' 2>&1`;
die "feed-layout proof failed ($?)\n$out" if $?;
$out =~ /3x96=288 bytes/ or die "missing 288-byte feed-layout proof\n";
$out =~ /feed2 has 32 spare pair2 slots/ or die "missing spare-slot proof\n";
print "vcs_all_five_stripes32_feed_layout ok\n";
