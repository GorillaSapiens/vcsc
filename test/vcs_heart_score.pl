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
   [DRAW_HMOVE_COUNT=>6],[DRAW_SUCCESSOR_ON_RETURN_LINE=>1],
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
$source !~ /uint8_t\s+TEMPLATE_kernel\[45\]/ or die "heart renderer unexpectedly returned to RIOT RAM\n";
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
$source =~ /TEMPLATE_score == 1 \|\| TEMPLATE_score == 2.*?TEMPLATE_position_single_p0/s
   or die "P0 singleton fixed-footprint path changed\n";
$source =~ /TEMPLATE_score == 2 \|\| TEMPLATE_score == 3.*?TEMPLATE_position_single_p1/s
   or die "P1 singleton fixed-footprint path changed\n";
$source =~ /Single-copy NUSIZ places P0 two TIA pixels left.*?lda #\$a0;.*?sta HMP0;.*?lda #0;.*?sta HMP0;/s
   or die "P0 singleton fixed-footprint correction changed\n";
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
$mt !~ /BSS\.__vcsc_object\$health_kernel\b/
   or die "heart executable renderer still occupies BSS\n";
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

print "vcs_heart_score ok\n";
