#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: vcs_video_standard_portability ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
sub read_file { my($p)=@_; open(my$f,'<:raw',$p) or die"read $p: $!\n";local$/;my$d=<$f>//'';close$f;return$d; }
@ARGV==1 or die"usage: $0 REPO\n";my$repo=abs_path($ARGV[0])//die"repo\n";my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my@portable=(
 'renderers/all_five/all_five.c26',
 'renderers/all_five/all_five.c26',
 'renderers/multisprite/multisprite.c26',
 'components/poison_debug_score/poison_debug_score.c26',
 qw(components/six_glyph_component.c26 components/six_glyph_left_component.c26 components/six_glyph_right_component.c26
    components/six_glyph_wide_component.c26 components/six_glyph_big_wide_component.c26
    components/two_plus_two_score_component.c26 components/three_plus_three_score_component.c26)
);
for my$rel(@portable){my$p=File::Spec->catfile($vcs,split('/', $rel));my$s=read_file($p);$s=~ /TEMPLATE_VISIBLE_SCANLINES/ or die"$rel lacks visible-line contract\n";my$c=$s;$c=~s{//[^\n]*}{}g;$c=~s{/\*.*?\*/}{}gs;$c!~ /\b(?:VSYNC|VBLANK|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT)\b/ or die"$rel touches frame-owned state\n";}
my$doc=read_file(File::Spec->catfile($vcs,'VIDEO_STANDARDS.md'));
for my$rel(@portable){$doc=~ /\Q$rel\E/ or die"portability doc omits $rel\n";}
print "vcs_video_standard_portability ok\n";
