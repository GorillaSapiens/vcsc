#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripe_generic_geometry_bound ok
# expectexit: 0
use strict; use warnings; use File::Spec;
my($root,$tmp)=@ARGV; die "usage: $0 ROOT TMP\n" unless defined $root;
my$p=File::Spec->catfile($root,'libraries/vcs/renderers/all_five/stripe_generic_geometry_bound.pl');
my$out=`perl '$p' 2>&1`; die "generic stripe geometry bound failed ($?)\n$out" if $?;

# The positive-stripe implementation is generic in BOTH stripes and lines. There
# must be no equivalent of "stripes > 0 implies lines == 192".
$out =~ /one generic implementation is generic in stripes and lines/
   or die "geometry authority is not generic in both axes: $out";

# The published equal-split families per maintained line mode.
$out =~ /lines=170 equal N=1,5,17/
   or die "170-line equal-split family changed: $out";
$out =~ /lines=181 equal N=none \(odd\)/
   or die "181-line odd mode is no longer stripeable by supplied heights: $out";
$out =~ /lines=192 equal N=1,2,3,4,6,8,12,16,24,32 \[exact:10\]/
   or die "192-line equal-split family changed: $out";
$out =~ /lines=228 equal N=1,2,3,6,19/
   or die "228-line equal-split family changed: $out";

# Every 192-line stripe count is exactly loopable, so no tail is needed there.
$out =~ /\(192,32\) gives h=6 P=3 super=24 x4 = 8 stripes\/supercycle and needs no tail/
   or die "(192,32) stress shape changed: $out";

# A score component or user component above/below the renderer must not need its
# own stripes implementation: the region only has to fit.
$out =~ /region only has to fit inside TEMPLATE_lines so odd 181 and partial regions are strippable/
   or die "region-fit rule changed: $out";

# Invalid geometry is rejected by name rather than rounded.
$out =~ /odd\/sub-minimum\/oversized\/mixed-period heights rejected by name/
   or die "geometry rejection rules changed: $out";

print "vcs_all_five_stripe_generic_geometry_bound ok\n";