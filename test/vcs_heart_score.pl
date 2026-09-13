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
   [MAX_HEARTS=>11],[HEART_WIDTH=>8],[HEART_PITCH=>12],
) {
   my($name,$value)=@$field;
   $source =~ /\bTEMPLATE_\Q$name\E\s*:=\s*\Q$value\E\b/
      or die "component has no TEMPLATE_$name := $value contract\n";
}
for my $phase (qw(init vblank draw overscan)) {
   $source =~ /require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/
      or die "component is missing required TEMPLATE_$phase lifecycle declaration\n";
}
$source =~ /uint8_t\s+TEMPLATE_kernel\[45\]/ or die "heart RAM kernel is not 45 bytes\n";
$source =~ /if\s*\(TEMPLATE_score\s*>\s*11\)\s*\{\s*TEMPLATE_count\s*:=\s*11;/s
   or die "heart score no longer clamps above 11\n";
$source =~ /TEMPLATE_p0_masks\[12\].*?0x00,0x20,0x20,0x30,0x30,0x38,0x38,0x3c,0x3c,0x3e,0x3e,0x3f/s
   or die "P0 prefix masks changed\n";
$source =~ /TEMPLATE_p1_masks\[12\].*?0x00,0x00,0x10,0x10,0x18,0x18,0x1c,0x1c,0x1e,0x1e,0x1f,0x1f/s
   or die "P1 prefix masks changed\n";
$source =~ /Single-copy NUSIZ places P0 two TIA pixels left.*?lda #\$a0;.*?sta HMP0;.*?lda #0;.*?sta HMP0;/s
   or die "P0 singleton fixed-footprint correction changed\n";

my $bin=File::Spec->catfile($tmp,'heart_score.bin');
my $map=File::Spec->catfile($tmp,'heart_score.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-DHEART_SCORE=11','-Map',$map,$fixture,'-o',$bin);
$rc==0&&!$sig or die "heart fixture build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "heart fixture build wrote output\n$out$err";
-s $bin == 4096 or die "heart fixture is not a 4K ROM\n";
my $mt=read_file($map);
my $ram=0;
while ($mt =~ /^\s+(?:BSS|DATA)\.__vcsc_object\$health_[^\s]+\s+.*?size=\$([0-9A-Fa-f]{4})/mg) { $ram += hex($1); }
$ram==58 or die "heart component RAM changed: $ram bytes, expected 58\n";

print "vcs_heart_score ok\n";
