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
   $source =~ /page\s+static\s+void\s+TEMPLATE_half_renderer_\Q$score\E\s*\(/
      or die "heart half ROM renderer $score is missing or not page-contained\n";
}
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
$source =~ /TEMPLATE_half_heart\[7\].*?0x08,0x0c,0x0e,0x0f,0x0f,0x06/s
   or die "half-heart player glyph changed\n";
$source =~ /TEMPLATE_half_ball\[7\].*?0x02,0x12,0x12,0x22,0x22,0x00/s
   or die "half-heart Ball control table changed\n";
$source =~ /TEMPLATE_half_m0_x\[12\].*?28,40,52,48,60,72,84,96,108,120,132,144/s
   or die "half-heart repeated-M0 hiding geometry changed\n";
$source =~ /TEMPLATE_half_ball_x\[12\].*?27,39,51,63,75,87,99,111,123,135,147,159/s
   or die "half-heart Ball geometry changed\n";
$source =~ /lda\.ay TEMPLATE_half_m0_x,y;.*?sta WSYNC;.*?ldx #2;.*?bit\.z CXM0P;.*?nop;.*?sec;/s
   or die "M0 positioner no longer resolves coordinates before WSYNC\n";
$source =~ /lda\.ay TEMPLATE_half_ball_x,y;.*?sta WSYNC;.*?ldx #4;.*?bit\.z CXM0P;.*?nop;.*?sec;/s
   or die "Ball positioner no longer resolves coordinates before WSYNC\n";
$source =~ /TEMPLATE_reposition\[16\].*?0x70,0x60,0x50,0x40,0x30,0x20,0x10,0x00.*?0xf0,0xe0,0xd0,0xc0,0xb0,0xa0,0x90,0x80/s
   or die "half-heart standard fine-motion table changed\n";

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
   my $half_size=$score==0 ? '002D' : '002E';
   $mt =~ /^\s+CODE\.__vcsc_function\$health_half_renderer_\Q$score\E\s+load=\$[0-9A-Fa-f]+\s+size=\$\Q$half_size\E\s+page=hard$/m
      or die "heart half ROM renderer $score has wrong size/page contract\n";
}

print "vcs_heart_score ok\n";
