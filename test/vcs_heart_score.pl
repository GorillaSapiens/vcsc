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
my $line_fixture=File::Spec->catfile($repo,qw(test fixtures heart_score lines.c26));
my $source=read_file($component);

$source =~ /parameter\s+line_markers\s*:=\s*0\s*;/ or die "line-marker template parameter is missing\n";
$source =~ /alias\s+TEMPLATE_VISIBLE_SCANLINES_VALUE\s+10/ or die "enabled line-marker height is not 10 scanlines\n";
$source =~ /alias\s+TEMPLATE_VISIBLE_SCANLINES_VALUE\s+7/ or die "disabled heart height is not 7 scanlines\n";
$source =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/ or die "visible-line contract does not follow template profile\n";
$source =~ /TEMPLATE_DRAW_COMPLETE_SCANLINES\s*:=\s*TEMPLATE_VISIBLE_SCANLINES_VALUE/ or die "complete-line contract does not follow template profile\n";
for my $field (
   [DRAW_ENTRY_CYCLE=>3],[DRAW_RETURN_CYCLE=>0],
   [DRAW_TERMINAL_WSYNC=>1],
   [DRAW_HMOVE_COUNT=>7],[DRAW_SUCCESSOR_ON_RETURN_LINE=>1],
   [MAX_HEARTS=>11],[HEART_WIDTH=>8],[HEART_PITCH=>12],[HALF_STATES=>2],
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
for my $score (0..11) {
   $source =~ /page\s+static\s+void\s+TEMPLATE_renderer_\Q$score\E\s*\(/
      or die "heart ROM renderer $score is missing or not page-contained\n";
}
for my $score (0..9,11) {
   $source =~ /page\s+static\s+void\s+TEMPLATE_half_renderer_\Q$score\E\s*\(/
      or die "heart half ROM renderer $score is missing or not page-contained\n";
}
$source =~ /static\s+void\s+TEMPLATE_half_renderer_10\s*\(/
   or die "unrolled 10.5-heart renderer is missing\n";
$source =~ /\.byte\s+\$[0-9a-fA-F]{2},\$2d/
   or die "centered Jentzsch setup-5 operand patch is missing\n";
$source =~ /TEMPLATE_score == 10.*?return;.*?lda #<TEMPLATE_renderer_11/s
   or die "heart score no longer maps values above 10 to the 11-heart renderer\n";
$source !~ /TEMPLATE_position_single_p[01]|TEMPLATE_prepare_positions/
   or die "heart positioning unexpectedly depends on VBLANK singleton state\n";
$source =~ /TEMPLATE_configure_tia.*?\.byte \$8d,\$10,\$00;.*?\.byte \$8d,\$11,\$00;.*?lda #\$50;.*?sta HMP0;.*?sta HMP1;.*?sta HMOVE;/s
   or die "draw-time P0/P1 fixed-footprint positioning changed\n";
$source =~ /TEMPLATE_vblank\s*\(void\)\s*\{\s*TEMPLATE_select_renderer\(\);.*?TEMPLATE_prepare_lines\(\);.*?\}/s
   or die "heart VBLANK line preparation contract changed\n";
$source =~ /TEMPLATE_half_heart\[7\].*?0x10,0x30,0x70,0xf0,0xf0,0x60/s
   or die "left-half player glyph changed\n";
$source =~ /\.byte\s+\$87,\$1c/ && $source =~ /\.byte\s+\$8f,\$(?:1b|1c),\$00/
   or die "left-half SAX player writes changed\n";
$source =~ /ldx #\$f0;.*?bne\.same \@TEMPLATE_dispatch_x_ready.*?ldx #0;.*?\@TEMPLATE_dispatch_x_ready/s
   or die "half/full dispatcher X-mask balance changed\n";
$source !~ /TEMPLATE_half_ball|TEMPLATE_half_m0|TEMPLATE_position_half_overlay/
   or die "obsolete Ball/M0 half-heart overlay returned\n";
$source =~ /State 11 deliberately draws the ordinary 11-heart maximum/
   or die "11-heart half clamp contract is missing\n";

$source =~ /#if TEMPLATE_line_markers.*?recommend\s+uint8_t\s+TEMPLATE_lines\s*:=\s*0.*?recommend\s+uint8_t\s+TEMPLATE_line_color\s*:=\s*0/s
   or die "enabled marker runtime state is missing or not compile-time guarded\n";
$source =~ /TEMPLATE_draw_line\(\);.*?TEMPLATE_configure_tia\(\);.*?TEMPLATE_dispatch\(\);.*?asm sta WSYNC;.*?TEMPLATE_draw_line\(\);/s
   or die "enabled marker draw does not bracket the historical heart renderer\n";

my $bin=File::Spec->catfile($tmp,'heart_score.bin');
my $map=File::Spec->catfile($tmp,'heart_score.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-DHEART_SCORE=11','-DHEART_HALF=1','-Map',$map,$fixture,'-o',$bin);
$rc==0&&!$sig or die "heart fixture build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "heart fixture build wrote output\n$out$err";
-s $bin == 4096 or die "heart fixture is not a 4K ROM\n";
my $mt=read_file($map);
my $ram=0;
while ($mt =~ /^\s+(?:BSS|DATA)\.__vcsc_object\$health_[^\s]+\s+.*?size=\$([0-9A-Fa-f]{4})/mg) { $ram += hex($1); }
$ram==8 or die "heart component RAM changed: $ram bytes, expected 8\n";
$mt !~ /RODATA\.__vcsc_object\$health_renderer_template\b/
   or die "obsolete RAM-renderer template remains in ROM\n";
for my $score (0..11) {
   $mt =~ /^\s+CODE\.__vcsc_function\$health_renderer_\Q$score\E\s+load=\$[0-9A-Fa-f]+\s+size=\$002D\s+page=hard$/m
      or die "heart ROM renderer $score is not an exact 45-byte hard-page function\n";
}
$mt =~ /^\s+CODE\.__vcsc_function\$health_half_renderer_0\s+load=\$[0-9A-Fa-f]+\s+size=\$002D\s+page=hard$/m
   or die "0.5-heart renderer footprint changed\n";
for my $score (1..9,11) {
   $mt =~ /^\s+CODE\.__vcsc_function\$health_half_renderer_\Q$score\E\s+load=\$[0-9A-Fa-f]+\s+size=\$0037\s+page=hard$/m
      or die "heart half ROM renderer $score footprint changed\n";
}
$mt =~ /^\s+CODE\.__vcsc_function\$health_half_renderer_10\s+load=\$[0-9A-Fa-f]+\s+size=\$0145\s+page=crossing$/m
   or die "unrolled 10.5-heart renderer footprint changed\n";

my $line_bin=File::Spec->catfile($tmp,'heart_score_lines.bin');
my $line_map=File::Spec->catfile($tmp,'heart_score_lines.map');
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-DHEART_LINES=11','-Map',$line_map,$line_fixture,'-o',$line_bin);
$rc==0&&!$sig or die "line-marker heart fixture build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "line-marker heart fixture build wrote output\n$out$err";
-s $line_bin == 4096 or die "line-marker heart fixture is not a 4K ROM\n";
my $lmt=read_file($line_map);
my $line_ram=0;
while ($lmt =~ /^\s+(?:BSS|DATA)\.__vcsc_object\$health_[^\s]+\s+.*?size=\$([0-9A-Fa-f]{4})/mg) { $line_ram += hex($1); }
$line_ram==12 or die "line-marker heart component RAM changed: $line_ram bytes, expected 12\n";
$lmt =~ /(?:BSS|DATA)\.__vcsc_object\$health_lines\b/m or die "enabled marker line-count state is missing\n";
$lmt =~ /(?:BSS|DATA)\.__vcsc_object\$health_line_color\b/m or die "enabled marker color state is missing\n";

print "vcs_heart_score ok\n";
