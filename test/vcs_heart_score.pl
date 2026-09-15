#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_heart_score ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp_fh($o); my$se=slurp_fh($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my$f,'<:raw',$p) or die "read $p: $!\n"; local$/; my$d=<$f>; close$f; return $d // ''; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

@ARGV==2 or die "usage: $0 REPO TMP\n";
my $repo=abs_path($ARGV[0]) or die "resolve repo\n";
my $tmp=abs_path($ARGV[1]) or die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $component=File::Spec->catfile($vcs,'heart_score_component.c26');
my $fixture=File::Spec->catfile($repo,qw(test fixtures heart_score golden.c26));
my $source=read_file($component);

for my $field (
   [VISIBLE_SCANLINES=>7],[DRAW_ENTRY_CYCLE=>3],[DRAW_RETURN_CYCLE=>0],
   [DRAW_COMPLETE_SCANLINES=>7],[DRAW_TERMINAL_WSYNC=>1],
   [DRAW_HMOVE_COUNT=>7],[DRAW_SUCCESSOR_ON_RETURN_LINE=>1],
   [MAX_HEARTS=>11],[HEART_WIDTH=>8],[HEART_PITCH=>12],[HALF_STATES=>2],
   [MAX_BOXES=>11],
) {
   my($name,$value)=@$field;
   $source =~ /\bTEMPLATE_\Q$name\E\s*:=\s*\Q$value\E\b/
      or die "component has no TEMPLATE_$name := $value contract\n";
}
for my $phase (qw(init vblank draw overscan)) {
   $source =~ /require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/
      or die "component is missing required TEMPLATE_$phase lifecycle declaration\n";
}
$source !~ /uint8_t\s+TEMPLATE_[A-Za-z0-9_]+\[45\]/ or die "heart renderer unexpectedly returned to RIOT RAM\n";
$source =~ /uint16_t\s+TEMPLATE_renderer_ptr/ or die "heart ROM-renderer pointer is missing\n";
$source =~ /recommend\s+uint8_t\s+TEMPLATE_half\s*:=\s*0/ or die "heart half-state control is missing\n";
$source =~ /recommend\s+uint8_t\s+TEMPLATE_boxes\s*:=\s*11/ or die "heart box-count control is missing\n";
$source =~ /recommend\s+uint8_t\s+TEMPLATE_box_color/ or die "heart box-color control is missing\n";
for my $score (0..11) {
   $source =~ /page\s+static\s+void\s+TEMPLATE_renderer_\Q$score\E\s*\(/
      or die "heart ROM renderer $score is missing or not page-contained\n";
}
for my $score (0..7,11) {
   $source =~ /page\s+static\s+void\s+TEMPLATE_half_renderer_\Q$score\E\s*\(/
      or die "heart half ROM renderer $score is missing or not page-contained\n";
}
for my $score (8..10) {
   $source =~ /static\s+void\s+TEMPLATE_half_renderer_\Q$score\E\s*\(/
      or die "unrolled heart half renderer $score is missing\n";
}
$source =~ /\.byte\s+\$[0-9a-fA-F]{2},\$2d/
   or die "centered Jentzsch setup-5 operand patch is missing\n";
$source =~ /TEMPLATE_score == 10.*?return;.*?lda #<TEMPLATE_renderer_11/s
   or die "heart score no longer maps values above 10 to the 11-heart renderer\n";
$source !~ /TEMPLATE_position_single_p[01]|TEMPLATE_prepare_positions/
   or die "heart positioning unexpectedly depends on VBLANK singleton state\n";
$source =~ /TEMPLATE_configure_tia.*?\.byte \$8d,\$10,\$00;.*?\.byte \$8d,\$11,\$00;.*?lda #\$50;.*?sta HMP0;.*?sta HMP1;.*?sta HMOVE;/s
   or die "draw-time P0/P1 fixed-footprint positioning changed\n";
$source =~ /TEMPLATE_vblank\s*\(void\)\s*\{\s*TEMPLATE_select_renderer\(\);\s*\}/s
   or die "heart VBLANK unexpectedly owns horizontal player positioning\n";
$source =~ /TEMPLATE_half_heart\[7\].*?0x10,0x30,0x70,0xf0,0xf0,0x60/s
   or die "left-half player glyph changed\n";
$source =~ /\.byte\s+\$87,\$1c/ && $source =~ /\.byte\s+\$8f,\$(?:1b|1c),\$00/
   or die "left-half SAX player writes changed\n";
$source =~ /TEMPLATE_pf_prefetch := 0xf0;/
   or die "half-heart SAX prefetch mask is missing\n";
$source =~ /TEMPLATE_box_left_pf1_table\[12\]/ &&
$source =~ /TEMPLATE_box_left_pf2_table\[12\]/ &&
$source =~ /TEMPLATE_box_right_pf1_table\[12\]/ &&
$source =~ /TEMPLATE_box_right_pf2_table\[12\]/
   or die "heart box playfield lookup tables are missing\n";
$source =~ /sta COLUPF/ && $source =~ /sta PF1/ && $source =~ /sta PF2/
   or die "heart draw no longer owns box playfield output\n";
$source !~ /TEMPLATE_half_ball|TEMPLATE_half_m0|TEMPLATE_position_half_overlay/
   or die "obsolete Ball/M0 half-heart overlay returned\n";
$source =~ /State 11 deliberately draws the ordinary 11-heart maximum/
   or die "11-heart half clamp contract is missing\n";

my $bin=File::Spec->catfile($tmp,'heart_score.bin');
my $map=File::Spec->catfile($tmp,'heart_score.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-DHEART_SCORE=11','-DHEART_HALF=1','-Map',$map,$fixture,'-o',$bin);
$rc==0&&!$sig or die "heart fixture build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "heart fixture build wrote output\n$out$err";
-s $bin == 4096 or die "heart fixture is not a 4K ROM\n";
my $mt=read_file($map);
my $ram=0;
while ($mt =~ /^\s+(?:BSS|DATA)\.__vcsc_object\$health_[^\s]+\s+.*?size=\$([0-9A-Fa-f]{4})/mg) { $ram += hex($1); }
$ram==16 or die "heart component RAM changed: $ram bytes, expected 16\n";
$mt !~ /RODATA\.__vcsc_object\$health_renderer_template\b/
   or die "obsolete RAM-renderer template remains in ROM\n";
for my $score (0..11) {
   $mt =~ /^\s+CODE\.__vcsc_function\$health_renderer_\Q$score\E\s+load=\$[0-9A-Fa-f]+\s+size=\$0037\s+page=hard$/m
      or die "heart ROM renderer $score is not an exact 55-byte hard-page function\n";
}
for my $score (0,1,5,11) {
   $mt =~ /^\s+CODE\.__vcsc_function\$health_half_renderer_\Q$score\E\s+load=\$[0-9A-Fa-f]+\s+size=\$0037\s+page=hard$/m
      or die "heart half ROM renderer $score footprint changed\n";
}
for my $score (2,3,4,6,7) {
   $mt =~ /^\s+CODE\.__vcsc_function\$health_half_renderer_\Q$score\E\s+load=\$[0-9A-Fa-f]+\s+size=\$0038\s+page=hard$/m
      or die "heart half ROM renderer $score footprint changed\n";
}
my %unrolled=(8=>'0150',9=>'0151',10=>'0151');
for my $score (8..10) {
   my $sz=$unrolled{$score};
   $mt =~ /^\s+CODE\.__vcsc_function\$health_half_renderer_\Q$score\E\s+load=\$[0-9A-Fa-f]+\s+size=\$\Q$sz\E\s+page=crossing$/m
      or die "unrolled heart half renderer $score footprint changed\n";
}

print "vcs_heart_score ok\n";
