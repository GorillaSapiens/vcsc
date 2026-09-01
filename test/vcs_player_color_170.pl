#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: vcs_player_color_170 ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return $d // ''; }
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }
sub require_re { my($s,$re,$why)=@_; $s =~ $re or die "$why\n"; }
sub bss_size {
   my($map,$name)=@_;
   $map =~ /^\s+BSS\.__vcsc_object\$\Q$name\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m
      or die "map is missing BSS object $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $component=File::Spec->catfile($vcs,qw(renderers player_color player_color.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures player_color_170 smoke.c26));
my $dual_source=File::Spec->catfile($repo,qw(test fixtures player_color_170 dual_score.c26));
my $public_source=File::Spec->catfile($repo,qw(examples 13_player_color_170 01_score_above_and_below 01_interactive player_color_170_score_above_and_below_interactive.c26));
my $bin=File::Spec->catfile($tmp,'player_color_170.bin');
my $mapfile=File::Spec->catfile($tmp,'player_color_170.map');
my $dual_bin=File::Spec->catfile($tmp,'player_color_170_dual_score.bin');
my $dual_map=File::Spec->catfile($tmp,'player_color_170_dual_score.map');
my $public_bin=File::Spec->catfile($tmp,'player_color_170_public.bin');

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "player-color 170 build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 170 build wrote output\n$out$err";
-s $bin == 4096 or die "player-color 170 cartridge is not exactly 4096 bytes\n";
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$dual_map,$dual_source,'-o',$dual_bin);
$rc==0 && !$sig or die "player-color 170 dual-score build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 170 dual-score build wrote output\n$out$err";
-s $dual_bin == 4096 or die "player-color 170 dual-score cartridge is not exactly 4096 bytes\n";
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$public_source,'-o',$public_bin);
$rc==0 && !$sig or die "public player-color 170 dual-score build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "public player-color 170 dual-score build wrote output\n$out$err";
-s $public_bin == 4096 or die "public player-color 170 dual-score cartridge is not exactly 4096 bytes\n";

my $module=read_file($component);
my $fixture=read_file($source);
my $dual=read_file($dual_source);
my $public=read_file($public_source);
my $map=read_file($mapfile);
require_re($module,qr/^parameter\s+lines;/m,'unified player-color renderer lacks required lines parameter');
require_re($module,qr/#elif TEMPLATE_lines == 170/,'unified player-color renderer lacks a 170-line profile');
require_re($fixture,qr/instantiate\s+"renderers\/player_color\/player_color\.c26"\s+as\s+game\s*\(lines:=170\)/,
   '170 fixture does not instantiate unified player-color renderer with lines:=170');
require_re($dual,qr/top_score_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*game_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*bottom_score_draw\(\);/s,
   '170 dual-score fixture no longer composes score + game + score');
require_re($public,qr/instantiate\s+"renderers\/player_color\/player_color\.c26"\s+as\s+game\s*\(lines:=170\)/,
   'public 170 example does not instantiate unified player-color renderer with lines:=170');
require_re($public,qr/top_score_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*game_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*bottom_score_draw\(\);/s,
   'public 170 example no longer composes score + game + score');
$map =~ /^\s+RODATA\.__vcsc_object\$game_playfield\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0028\s+page=hard\b/m
   or die "170 playfield is not a page-contained 40-byte ROM object\n";
my %sizes=(game_object_x=>5,game_player0_y=>1,game_player1_y=>1,game_ball_y=>1,
   game_player0_graphics=>2,game_player1_graphics=>2,game_player0_height=>1,
   game_player1_height=>1,game_ball_height=>1,game_workspace=>8,game_playfield_position=>1);
my $sum=0; $sum += bss_size($map,$_) for keys %sizes;
$sum==24 or die "170 player-color component BSS totals $sum bytes; expected 24\n";
my $branch;
$module =~ /#elif TEMPLATE_lines == 170(.*?)#else/s or die "could not isolate 170 player-color branch\n";
$branch=$1;
require_re($branch,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_lines/,'170 visible-line contract is not parameterized');
require_re($branch,qr/TEMPLATE_PLAYFIELD_BYTES\s*:=\s*40/,'170 playfield-byte contract changed');
require_re($branch,qr/TEMPLATE_PLAYFIELD_ROWS\s*:=\s*10/,'170 playfield-row contract changed');
require_re($branch,qr/TEMPLATE_MODULE_RAM_BYTES\s*:=\s*24/,'170 module-RAM contract changed');
require_re($branch,qr/asm cpx #36;\s*(?:asm beq(?:\.same|\.cross) \@terminalrenderer;|asm bne(?:\.same|\.cross) \@terminalrenderer_not_equal;\s*asm jmp \@terminalrenderer;)/s,'170 terminal row is not the tenth playfield row');
my $code=$branch; $code =~ s{//[^\n]*}{}g; $code =~ s{/\*.*?\*/}{}gs;
$code !~ /\b(?:lax|dcp|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|axs|xaa|ahx|shx|shy|tas|las)\b/i
   or die "official 170 player-color branch contains an unofficial mnemonic\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
for my $case (
   ['timing-smoke','vcs_frame_timing.cpp',$bin,[50,'--no-audio','--raw-lines',264],qr/^vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n$/],
   ['phase-smoke','vcs_playfield_phase.cpp',$bin,[10,10,44],qr/^vcs_playfield_raster ok: 10 rows x 16 lines x 160 pixels\n$/],
   ['timing-dual','vcs_frame_timing.cpp',$dual_bin,[50,'--no-audio','--raw-lines',264],qr/^vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n$/],
   ['phase-dual','vcs_playfield_phase.cpp',$dual_bin,[10,10,55],qr/^vcs_playfield_raster ok: 10 rows x 16 lines x 160 pixels\n$/],
   ['objects','vcs_standard_objects.cpp',$bin,['--players-hblank'],qr/^vcs_player_extreme_right ok: checkerboard P0\/P1 commits remain in HBLANK\n$/],
) {
   my($name,$srcname,$rom,$args,$expect)=@$case;
   my $exe=File::Spec->catfile($tmp,"player_color_170_$name");
   my $src=File::Spec->catfile($repo,'test',$srcname);
   ($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
   $rc==0 && !$sig or die "$name harness build failed\n$out$err";
   $out eq '' && $err eq '' or die "$name harness build wrote output\n$out$err";
   ($rc,$sig,$out,$err)=capture($exe,$rom,@$args);
   $rc==0 && !$sig or die "$name harness failed\n$out$err";
   $out =~ $expect or die "unexpected $name output: $out";
   $err eq '' or die "$name harness stderr: $err";
}
print "vcs_player_color_170 ok\n";
