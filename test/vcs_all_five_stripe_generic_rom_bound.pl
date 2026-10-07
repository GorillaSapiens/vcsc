#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripe_generic_rom_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe_generic_rom_bound.pl');
my$out=`perl '$p' 2>&1`; die "generic stripe ROM bound failed ($?)\n$out" if $?;

# The feed is sized by renderer pairs, NOT by stripe count. This is the
# non-obvious half: a smaller stripe count carries less data but the same feed.
$out =~ /feed = 3\*\(lines\/2\) bytes, independent of the stripe count \(288 at 192 lines, 342 at 228\)/
   or die "feed sizing rule changed: $out";

# The two endpoints that show the non-intuitive direction of the scaling.
$out =~ /N=2  h=96  logical=16   feed=288  spare=272/
   or die "small-N feed accounting changed: $out";
$out =~ /N=32 h=6   logical=256  feed=288  spare=32/
   or die "32-stripe feed accounting changed: $out";

# The budget that matters is the prototype the generic machine replaces, not the
# free space in the build it replaces. An earlier version of this bound concluded
# the feed left only 98 bytes and blocked the emit; that measured the wrong thing.
$out =~ /the stripes=2 prototype costs 2417 bytes \(measured 3704 at stripes=2 versus 1287 at stripes=0\), so the 288-byte feed fits inside what it replaces and leaves 2129 bytes for the generic body at the tightest stripe count/
   or die "prototype-relative ROM budget no longer recorded: $out";
$out =~ /an earlier conclusion that the feed left only 98 bytes was wrong because it measured against the free space of the build being replaced/
   or die "the corrected feed-budget reasoning is no longer recorded: $out";

print "vcs_all_five_stripe_generic_rom_bound ok\n";