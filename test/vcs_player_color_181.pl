#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 15
# expectstdout: vcs_player_color_181 ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
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
sub read_file {
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return defined($d)?$d:'';
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub require_re { my($s,$re,$why)=@_; $s =~ $re or die "$why\n"; }
sub map_zp {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   my $v=hex($1); $v <= 0xff or die "$name is not in zero page\n"; return $v;
}
sub bss_size {
   my($map,$name)=@_;
   $map =~ /^\s+BSS\.__vcsc_object\$\Q$name\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m
      or die "map missing BSS $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $module=File::Spec->catfile($vcs,qw(renderers player_color player_color.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures player_color_181 smoke.c26));
my $bin=File::Spec->catfile($tmp,'player_color_181.bin');
my $mapfile=File::Spec->catfile($tmp,'player_color_181.map');
my $terminal_source=File::Spec->catfile($repo,qw(test fixtures player_color_181 terminal.c26));
my $terminal_bin=File::Spec->catfile($tmp,'player_color_181_terminal.bin');
my $terminal_mapfile=File::Spec->catfile($tmp,'player_color_181_terminal.map');
my $reference=File::Spec->catfile($repo,qw(test fixtures player_color_181 reference_score_above_stella_7.0.png));
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "player-color 181 build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 181 build wrote output\n$out$err";
-s $bin == 4096 or die "player-color 181 ROM is not 4096 bytes\n";
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$terminal_mapfile,$terminal_source,'-o',$terminal_bin);
$rc==0 && !$sig or die "player-color 181 terminal build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 181 terminal build wrote output\n$out$err";
-s $terminal_bin == 4096 or die "player-color 181 terminal ROM is not 4096 bytes\n";
my $terminal_map=read_file($terminal_mapfile);
sha256_hex(read_file($reference)) eq
   '769d2ec6a076edf2f27587e74922045b55f65dff31b4caf94bc3059ac7e66b99'
   or die "reviewed player-color 181 Stella reference PNG changed\n";
my $text=read_file($module);
$text =~ /^parameter\s+lines;/m or die "unified player-color renderer lacks required lines parameter\n";
$text =~ /#elif TEMPLATE_lines == 181(.*?)#elif TEMPLATE_lines == 170/s
   or die "could not isolate player-color 181 branch\n";
$text=$1;
my $map=read_file($mapfile);
require_re($text,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_lines/, 'visible-line contract is not parameterized');
require_re($text,qr/TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*13/, 'public-RAM contract changed');
require_re($text,qr/TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*11/, 'private-RAM contract changed');
require_re($text,qr/TEMPLATE_MODULE_RAM_BYTES\s*:=\s*24/, 'module-RAM contract changed');
require_re($text,qr/TEMPLATE_WORKSPACE_BYTES\s*:=\s*8/, 'workspace contract changed');
$text !~ /uint8_t\s+TEMPLATE_object_masks\s*\[/
   or die "player-color 181 unexpectedly retained the object-mask schedule\n";
require_re($text,qr/asm dec[.]z TEMPLATE_ball_y;/,
   'player-color 181 no longer uses direct Ball countdown');
for my $bad (qw(score font VSYNC VBLANK TIM64T INTIM TIMINT)) {
   $text !~ /^\s*asm\s+.*\b\Q$bad\E\b/im or die "component owns forbidden $bad resource\n";
}
for my $name (qw(game_playfield game_player0_colors game_player1_colors p0_graphics p1_graphics game_reposition_table game_player_position_table)) {
   require_re($map,qr/RODATA\.__vcsc_object\$\Q$name\E\s+load=\$[0-9A-Fa-f]{4}.*page=hard/, "$name is not hard-page-contained");
}
my %sizes=(game_object_x=>5,game_player0_y=>1,game_player1_y=>1,game_ball_y=>1,
   game_player0_graphics=>2,game_player1_graphics=>2,game_player0_height=>1,
   game_player1_height=>1,game_ball_height=>1,game_workspace=>8,
   game_playfield_position=>1);
my $sum=0;
for my $name (sort keys %sizes) {
   my $got=bss_size($map,$name); $got==$sizes{$name} or die "$name is $got bytes; expected $sizes{$name}\n"; $sum += $got;
}
$sum==24 or die "component BSS totals $sum bytes; expected 24\n";
$map !~ /\bgame_(?:score|score_color|missile0|missile1)\b/ or die "forbidden score/missile state linked\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_player_color_181.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_player_color_181');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "player-color 181 harness build failed\n$out$err";
$out eq '' && $err eq '' or die "player-color 181 harness build wrote output\n$out$err";
my @zp=map { sprintf('0x%02x',map_zp($map,$_)) }
   qw(game_object_x game_player0_y game_player1_y game_ball_y);
($rc,$sig,$out,$err)=capture($harness,'static',$bin,@zp);
$rc==0 && !$sig or die "player-color 181 raster failed\n$out$err";
$out eq "vcs_player_color_181 static ok: exact P0/P1 row colors, P0/P1/BL position and pixel endpoints, no missiles\n"
   or die "unexpected player-color 181 output: $out";
$err eq '' or die "player-color 181 harness stderr: $err";
my @terminal_zp=map { sprintf('0x%02x',map_zp($terminal_map,$_)) }
   qw(game_object_x game_player0_y game_player1_y game_ball_y);
($rc,$sig,$out,$err)=capture($harness,'terminal181',$terminal_bin,@terminal_zp);
$rc==0 && !$sig or die "player-color 181 terminal raster failed\n$out$err";
$out eq "vcs_player_color_181 terminal ok: complete P0/P1 colors and BL raster reach the terminal gameplay lines\n"
   or die "unexpected player-color 181 terminal output: $out";
$err eq '' or die "player-color 181 terminal harness stderr: $err";

my $phase_src=File::Spec->catfile($repo,qw(test vcs_playfield_phase.cpp));
my $phase_exe=File::Spec->catfile($tmp,'player_color_181_playfield');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-I',$mos,$phase_src,@mos_input,'-o',$phase_exe);
$rc==0 && !$sig or die "player-color 181 playfield harness build failed\n$out$err";
$out eq '' && $err eq '' or die "player-color 181 playfield harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($phase_exe,$bin,'11','11','44');
$rc==0 && !$sig or die "player-color 181 playfield raster failed\n$out$err";
$out eq "vcs_playfield_raster ok: 11 rows x 16 lines x 160 pixels\n"
   or die "unexpected player-color 181 playfield output: $out";
$err eq '' or die "player-color 181 playfield harness stderr: $err";
print "vcs_player_color_181 ok\n";
