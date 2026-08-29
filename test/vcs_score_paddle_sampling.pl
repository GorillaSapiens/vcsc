#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_score_paddle_sampling ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Compare qw(compare);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c);close$i;my$so=slurp_fh($o);my$se=slurp_fh($e);waitpid($p,0);return($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_;open(my$f,'<:raw',$p)or die"read $p: $!\n";local$/;my$d=<$f>;close$f;return$d//''; }
sub write_file { my($p,$d)=@_;open(my$f,'>:raw',$p)or die"write $p: $!\n";print{$f}$d;close$f or die"close $p: $!\n"; }
sub build {
   my($driver,$vcs,$src,$bin)=@_;
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',File::Spec->catfile($vcs,'vcs.cfg'),$src,'-o',$bin);
   $rc==0&&!$sig or die "build failed for $src\n$out$err";
   -s$bin==4096 or die "$src did not produce a 4K ROM\n";
}

my$repo=shift@ARGV//usage();my$tmp=shift@ARGV//usage();usage()if@ARGV;
$repo=abs_path($repo)//die"resolve repo\n";$tmp=abs_path($tmp)//die"resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));

my$score=read_file(File::Spec->catfile($vcs,'three_plus_three_score_component.c26'));
my$six=read_file(File::Spec->catfile($vcs,'six_glyph_component.c26'));
my$two=read_file(File::Spec->catfile($vcs,'two_paddles.c26'));
my$four=read_file(File::Spec->catfile($vcs,'four_paddles.c26'));

$score =~ /parameter paddle_samples := 0/ &&
$score =~ /TEMPLATE_paddle_sample0\(\)/ && $score =~ /TEMPLATE_paddle_sample1\(\)/ &&
$score =~ /TEMPLATE_paddle_advance_pair\(\)/ && $score =~ /TEMPLATE_paddle_latch23_fixed\(\)/ &&
$score =~ /#if TEMPLATE_paddle_samples == 0.*?asm sta HMBL;.*?#endif/s &&
$score =~ /asm sta RESP0;.*?#if TEMPLATE_paddle_samples >= 2.*?asm lda #0;\s*asm sta HMBL;.*?TEMPLATE_paddle_sample1\(\)/s &&
$score =~ /#if TEMPLATE_paddle_samples == 4.*?TEMPLATE_paddle_latch23_fixed\(\);.*?asm sta RESP1;/s
   or die "three-plus-three paddle-slot contract missing\n";
$six =~ /parameter paddle_samples := 0/ &&
(()=$six =~ /TEMPLATE_paddle_sample0\(\);/g)>=2 &&
(()=$six =~ /TEMPLATE_paddle_sample1\(\);/g)>=2
   or die "six-glyph paddle-slot contract missing\n";
$two =~ /TEMPLATE_score_sample0/ && $two =~ /TEMPLATE_score_sample1/ &&
$two =~ /TEMPLATE_score_advance_pair/ && $two =~ /TEMPLATE_score_account_a/ &&
$two =~ /TEMPLATE_active0 := 0x80/ && $two =~ /TEMPLATE_active1 := 0x80/
   or die "two-paddle score probe contract missing\n";
$four =~ /TEMPLATE_score_sample0/ && $four =~ /TEMPLATE_score_sample1/ &&
$four =~ /TEMPLATE_score_latch23_fixed/ && $four =~ /TEMPLATE_score_commit_latched23/ &&
$four =~ /Fixed 24-cycle score probe/ && $four =~ /TEMPLATE_score_account_a/
   or die "four-paddle score probe contract missing\n";

# Disabled sampling must remain a zero-cost compile-time option. Explicit zero
# and the default must produce byte-identical ROMs for both score renderers.
for my $case (
   ['three_plus_three_score_component.c26','score','score_left_score := 123; score_right_score := 456; score_left_color := 0x2e; score_right_color := 0x4e;'],
   ['six_glyph_component.c26','score','score_score := 123456;'],
) {
   my($component,$name,$setup)=@$case;
   my $base=join("\n",
      'include "vcs_4k.c26"',
      'include "fonts/default_decimal.c26"',
      qq{instantiate "$component" as $name%s},
      qq{void main(void) { ${name}_init(); $setup ${name}_vblank(); ${name}_draw(); ${name}_overscan(); while (1) { } }},
      '');
   my $default_src=File::Spec->catfile($tmp,"$name-default-".($component =~ /six/ ? 'six' : 'three').'.c26');
   my $zero_src=File::Spec->catfile($tmp,"$name-zero-".($component =~ /six/ ? 'six' : 'three').'.c26');
   my $default_bin=$default_src; $default_bin =~ s/\.c26$/.bin/;
   my $zero_bin=$zero_src; $zero_bin =~ s/\.c26$/.bin/;
   write_file($default_src,sprintf($base,''));
   write_file($zero_src,sprintf($base,' (paddle_samples:=0)'));
   build($driver,$vcs,$default_src,$default_bin);
   build($driver,$vcs,$zero_src,$zero_bin);
   compare($default_bin,$zero_bin)==0
      or die "$component default and paddle_samples:=0 ROMs differ\n";
}

# Prove the public two-paddle hooks instantiate through the three-plus-three
# renderer. The renderer itself reserves X=0 for these slots.
my$two_src=File::Spec->catfile($tmp,'score-two-paddles.c26');
my$two_bin=File::Spec->catfile($tmp,'score-two-paddles.bin');
write_file($two_src,<<'C26');
include "vcs_4k.c26"
include "fonts/default_decimal.c26"
instantiate "two_paddles.c26" as paddles
inline void score_paddle_sample0(void) { paddles_score_sample0(); }
inline void score_paddle_sample1(void) { paddles_score_sample1(); }
inline void score_paddle_advance_pair(void) { paddles_score_advance_pair(); }
instantiate "three_plus_three_score_component.c26" as score (paddle_samples:=2)
void main(void) {
   paddles_init(); score_init(); paddles_vblank(); paddles_account_gap(1);
   score_vblank(); score_draw(); paddles_overscan(); paddles_dump(); score_overscan();
   while (1) { }
}
C26
build($driver,$vcs,$two_src,$two_bin);

# Four-channel score mode must use the fixed-phase 2/3 latch and make the later
# commit available to the application in a known blank/slack line.
my$four_src=File::Spec->catfile($tmp,'score-four-paddles.c26');
my$four_bin=File::Spec->catfile($tmp,'score-four-paddles.bin');
write_file($four_src,<<'C26');
include "vcs_4k.c26"
include "fonts/default_decimal.c26"
instantiate "four_paddles.c26" as paddles
inline void score_paddle_sample0(void) { paddles_score_sample0(); }
inline void score_paddle_sample1(void) { paddles_score_sample1(); }
inline void score_paddle_latch23_fixed(void) { paddles_score_latch23_fixed(); }
inline void score_paddle_advance_pair(void) { paddles_score_advance_pair(); }
instantiate "three_plus_three_score_component.c26" as score (paddle_samples:=4)
void main(void) {
   paddles_init(); score_init(); paddles_vblank(); paddles_account_gap(1);
   score_vblank(); score_draw(); paddles_score_commit_latched23();
   paddles_overscan(); paddles_dump(); score_overscan(); while (1) { }
}
C26
build($driver,$vcs,$four_src,$four_bin);

# The centered six-glyph renderer has two setup-line slots. Applications that
# use the public paddle probe reserve X=0 in their tiny compile-time wrappers.
my$six_src=File::Spec->catfile($tmp,'six-two-paddles.c26');
my$six_bin=File::Spec->catfile($tmp,'six-two-paddles.bin');
write_file($six_src,<<'C26');
include "vcs_4k.c26"
include "fonts/default_decimal.c26"
instantiate "two_paddles.c26" as paddles
inline void text_paddle_sample0(void) { asm ldx #0; paddles_score_sample0(); }
inline void text_paddle_sample1(void) { asm ldx #0; paddles_score_sample1(); }
instantiate "six_glyph_component.c26" as text (paddle_samples:=2)
void main(void) {
   paddles_init(); text_init(); paddles_vblank(); paddles_account_gap(1);
   text_vblank(); text_draw(); paddles_overscan(); paddles_dump(); text_overscan();
   while (1) { }
}
C26
build($driver,$vcs,$six_src,$six_bin);

print "vcs_score_paddle_sampling ok\n";
