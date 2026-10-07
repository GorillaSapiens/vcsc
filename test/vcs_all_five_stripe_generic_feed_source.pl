#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripe_generic_feed_source ok
# expectexit: 0
use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
my ($root,$tmp) = @ARGV;
die "usage: $0 ROOT TMP\n" unless defined $root;
my $dir=File::Spec->catdir($root,'libraries','vcs','renderers','all_five');
my $proof=File::Spec->catfile($dir,'stripe_generic_feed_source_bound.pl');
my $search=File::Spec->catfile($dir,'stripe_feed_pointer_source_search.pl');
-f $search
   or die "the record-pointer source search is missing\n";
local $ENV{VCSC_ALL_FIVE_DIR}=$dir;
local $ENV{VCSC_ALL_FIVE_REPO}=$root;
# Hand down THIS run's unique temporary directory.  The bound used to invent its own
# scratch files under the shared system temporary directory, so two people running the
# suite at once in different checkouts overwrote each other's map and cartridge
# mid-build.  Concurrent runs in separate directories are normal for this project.
local $ENV{VCSC_ALL_FIVE_TMP}=$tmp;
my $out=`perl '$proof' 2>&1`;
die "feed-source bound failed ($?)\n$out" if $?;
$out =~ /^stripe_generic_feed_source_bound ok:/m
   or die "feed-source bound did not report success\n$out";

# The bound must not leave scratch files in the shared system temporary directory
# under fixed names.  This is the collision, asserted rather than assumed: these are
# exactly the paths two concurrent runs would fight over.
# The bound must not leave scratch files in the shared system temporary directory.
# This is the collision, asserted rather than assumed.  Check the whole
# `feed_source_*` family rather than naming files: the driver derives sidecars from
# the output path, so one build leaves .bin/.map/.cfg/.lst/.sym and the .lst runs to
# hundreds of kilobytes.  Naming only .map and .bin would have missed the bigger ones.
opendir(my $dh,File::Spec->tmpdir()) or die "could not read the shared temporary directory: $!\n";
my @shared=grep { /^feed_source_/ } readdir($dh);
closedir($dh);
@shared==0
   or die "the feed-source bound wrote ".scalar(@shared)." file(s) into the shared "
        ."temporary directory: @shared\n";

# The layout must be stated as a general property, with the (192,32) case pinned
# to the maintained proof rather than restated.
$out =~ /pair q read at Y=region-1-q/
   or die "the general pair-index formula is no longer reported\n$out";
$out =~ /three pairs are needed for eight bytes and P<3 is exactly what the geometry authority rejects/
   or die "the pairs-per-stripe capacity argument changed\n$out";
$out =~ /\(192,32\) reproduces the maintained proof at 288 bytes with 32 spare slots/
   or die "the stripes=32 feed instance changed\n$out";
$out =~ /the 181 partial region/
   or die "an odd line mode is no longer covered by a partial region\n$out";

# Every record-based source must be rejected, each on its own window, so a future
# relaxation of one window cannot quietly remove the need for the tables.
$out =~ /rejected separately for color\(p0_a_visible\), even\(p0_p1_feed\), odd\(p0_p0_mid\)/
   or die "the record-pointer rejections changed\n$out";

# The feed now lands in ROM as a derivation of the public record, verified by its
# emitted bytes.  This is the capability the emit depends on, so if it regresses the
# bound has to fail rather than let the emit proceed on an assumption.
$out =~ /they fit ROM as a derivation of the public record, verified by building a transposed table from another const table's element reads and checking the emitted ROM bytes/
   or die "the derived-ROM capability is no longer measured\n$out";
# Containment for the fixed-cost reads is available, and must stay available: a
# straddling table would cost a cycle on the indices that cross.
$out =~ /three 96-byte page const tables at \$[0-9A-F]{4}-\$[0-9A-F]{4}, \$[0-9A-F]{4}-\$[0-9A-F]{4}, \$[0-9A-F]{4}-\$[0-9A-F]{4}/
   or die "page containment for the feed tables changed\n$out";
# RAM is the one placement bar left, and it is a wide one.  It must keep being
# reported as ruled out, since that is what retired the runtime-built feed.
$out =~ /the only remaining placement bar is RAM, where they do not come close \(288 bytes against 103 used and 25 free in the reference build, only 26 bytes of stripe scratch in 11 objects to free, and 128 bytes of cartridge RAM in total\)/
   or die "the RAM arithmetic changed\n$out";
# The earlier "uniform for the whole 2..32 range" claim is true of ROM cost and false
# of source cost.  The CAUSE is the data layout, and the bound must keep saying so:
# an earlier version blamed the lack of arithmetic in array sizes.  That limitation
# was real but was never the cause, and the grammar has since been widened to fold a
# constant expression extent; the bound still has to keep the two apart, because the
# reasoning that survives is the one that was never wrong.
$out =~ /the feeds are uniform in ROM cost \(288 bytes per build regardless of the stripe count\) but NOT in source/
   or die "the ROM-uniform-versus-source-uniform distinction is no longer reported\n$out";
$out =~ /the content depends on the DATA LAYOUT -- q=P\*s\+p picks the stripe/
   or die "the per-configuration cause is no longer attributed to the data layout\n$out";
$out =~ /would NOT be fixed by allowing arithmetic in array sizes \(the grammar now folds a constant expression there, and it never reduced the table count: a size expression cannot change WHICH byte goes in which slot, only how the extent is spelled, so that change bought readability alone\)/
   or die "the array-size limitation is no longer kept distinct from the layout cause\n$out";
$out =~ /so all 19 legal configurations need their own tables, 5625 source entries in total, which is a source-size cost and not a runtime one/
   or die "the per-configuration source cost changed\n$out";
$out =~ /so the feed origin is settled and the emit is unblocked/
   or die "the bound no longer reports the feed origin as settled\n$out";

# A failing toolchain must be reported as a failing toolchain.  The bound discarded
# the driver's exit code, so a broken or missing driver surfaced as "could not read
# the reference RAM footprint" -- which names a symptom instead of the cause, and
# pointed the investigation at the wrong thing entirely.  Point the bound at a tree
# whose driver always fails and require the exit code and the driver's own stderr.
my $fake=File::Spec->catdir($tmp,'broken_tree');
make_path(File::Spec->catdir($fake,'driver'));
my $fake_driver=File::Spec->catfile($fake,'driver','vcsc');
open(my $fh,'>',$fake_driver) or die "write fake driver: $!\n";
print {$fh} "#!/bin/sh\necho 'simulated driver failure' >&2\nexit 3\n";
close($fh);
chmod 0755,$fake_driver;
my $broken=`VCSC_ALL_FIVE_REPO='$fake' VCSC_ALL_FIVE_TMP='$tmp' perl '$proof' 2>&1`;
$broken =~ /build failed \(exit 3\)/
   or die "a failing driver no longer reports its exit code\n$broken";
$broken =~ /simulated driver failure/
   or die "a failing driver no longer surfaces its own diagnostic\n$broken";
$broken !~ /could not read the reference RAM footprint/
   or die "a failing driver is still misreported as a RAM-footprint problem\n$broken";

print "vcs_all_five_stripe_generic_feed_source ok\n";