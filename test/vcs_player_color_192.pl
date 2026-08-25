#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_player_color_192 ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
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
sub write_file {
   my($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n";
   print {$f} $d; close($f) or die "close $p: $!\n";
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub require_re { my($s,$re,$why)=@_; $s =~ $re or die "$why\n"; }
sub map_zp {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   my $v=hex($1); $v <= 0xff or die "$name is not in zero page\n"; return $v;
}
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   return sprintf('0x%04x',hex($1));
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
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $module=File::Spec->catfile($vcs,qw(renderers player_color player_color.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures player_color_192 smoke.c26));
my $bin=File::Spec->catfile($tmp,'player_color_192.bin');
my $mapfile=File::Spec->catfile($tmp,'player_color_192.map');
my $terminal_source=File::Spec->catfile($repo,qw(test fixtures player_color_192 terminal.c26));
my $terminal_bin=File::Spec->catfile($tmp,'player_color_192_terminal.bin');
my $terminal_mapfile=File::Spec->catfile($tmp,'player_color_192_terminal.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "player-color 192 build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 192 build wrote output\n$out$err";
-s $bin == 4096 or die "player-color 192 ROM is not 4096 bytes\n";
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$terminal_mapfile,$terminal_source,'-o',$terminal_bin);
$rc==0 && !$sig or die "player-color 192 terminal build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 192 terminal build wrote output\n$out$err";
-s $terminal_bin == 4096 or die "player-color 192 terminal ROM is not 4096 bytes\n";
my $terminal_map=read_file($terminal_mapfile);
my $text=read_file($module);
$text =~ /^parameter\s+lines;/m or die "unified player-color renderer lacks required lines parameter\n";
$text =~ /#if TEMPLATE_lines == 192 \|\| TEMPLATE_lines == 228(.*?)#elif TEMPLATE_lines == 181/s
   or die "could not isolate player-color 192 branch\n";
$text=$1;
my $fixture=read_file($source);
my $map=read_file($mapfile);
require_re($text,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_lines/, 'visible-line contract is not parameterized');
require_re($text,qr/TEMPLATE_PLAYFIELD_BYTES\s*:=\s*48/, 'playfield-byte contract changed');
require_re($text,qr/TEMPLATE_PLAYFIELD_ROWS\s*:=\s*12/, 'playfield-row contract changed');
require_re($text,qr/TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*13/, 'public-RAM contract changed');
require_re($text,qr/TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*10/, 'private-RAM contract changed');
require_re($text,qr/TEMPLATE_MODULE_RAM_BYTES\s*:=\s*23/, 'module-RAM contract changed');
require_re($fixture,qr/game_draw\(\);\s*vcs_ntsc_begin_overscan\(\);/s,
   'fixture no longer enters overscan immediately after the 192-line draw');
require_re($text,qr/cpx #44.*?(?:beq(?:\.same|\.cross) \@terminalrenderer|bne(?:\.same|\.cross) \@terminalrenderer_not_equal;\s*asm jmp \@terminalrenderer)/s,
   'full-height path no longer reaches the twelfth-row terminal line');
require_re($text,qr/\@terminalrenderer:.*?sty PF2;.*?sta\.a PF1;.*?sta WSYNC;/s,
   'terminal path no longer completes line 231 before the overscan handoff');
require_re($text,qr/ldy\.ax TEMPLATE_playfield\+2,x;.*?sty PF2;.*?sta PF1;/s,
   'right-half playfield bytes are no longer written in display order');
$text !~ /TEMPLATE_object_masks/ or die "direct-countdown renderer still declares object-mask storage\n";
require_re($text,qr/dec\.z TEMPLATE_ball_y/,
   'Ball direct countdown no longer advances in the visible schedule');
require_re($text,qr/cmp\.z TEMPLATE_ball_y/,
   'Ball direct countdown no longer compares against Ball height');
require_re($text,qr/Position Ball, P1, and P0 entirely during VBLANK/,
   'objects are no longer positioned entirely during VBLANK');
for my $bad (qw(score font VSYNC VBLANK TIM1T TIM8T TIM64T T1024T INTIM TIMINT)) {
   $text !~ /^\s*asm\s+.*\b\Q$bad\E\b/im or die "component owns forbidden $bad resource\n";
}
my $code=$text;
$code =~ s{//[^\n]*}{}g;
$code =~ s{/\*.*?\*/}{}gs;
$code !~ /\b(?:lax|dcp|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|axs|xaa|ahx|shx|shy|tas|las)\b/i
   or die "official component contains an unofficial mnemonic\n";
$code !~ /\bop[0-9A-Fa-f]{2}\b/ or die "official component contains a raw opcode escape\n";
for my $name (qw(game_playfield game_player0_colors game_player1_colors p0_graphics p1_graphics game_reposition_table)) {
   require_re($map,qr/RODATA\.__vcsc_object\$\Q$name\E\s+load=\$[0-9A-Fa-f]{4}.*page=hard/, "$name is not hard-page-contained");
}
my %sizes=(game_object_x=>5,game_player0_y=>1,game_player1_y=>1,game_ball_y=>1,
   game_player0_graphics=>2,game_player1_graphics=>2,game_player0_height=>1,
   game_player1_height=>1,game_ball_height=>1,game_workspace=>7,
   game_playfield_position=>1);
my $sum=0;
for my $name (sort keys %sizes) {
   my $got=bss_size($map,$name); $got==$sizes{$name} or die "$name is $got bytes; expected $sizes{$name}\n"; $sum += $got;
}
$sum==23 or die "component BSS totals $sum bytes; expected 23\n";
$map !~ /\bgame_(?:score|score_color|missile0|missile1|object_masks)\b/ or die "forbidden score/missile/mask state linked\n";
require_re($map,qr/BSS\.__vcsc_object\$\Qgame_workspace\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0007\s+page=preferred\s+phase=\$0E/,
   'direct-countdown workspace is not phase-overlay eligible');
$map !~ /(?:score|font)/i or die "score/font symbols linked\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_player_color_192.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_player_color_192');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "player-color 192 harness build failed\n$out$err";
$out eq '' && $err eq '' or die "player-color 192 harness build wrote output\n$out$err";
my @zp=map { sprintf('0x%02x',map_zp($map,$_)) }
   qw(game_object_x game_player0_y game_player1_y game_ball_y);
($rc,$sig,$out,$err)=capture($harness,'static',$bin,@zp);
$rc==0 && !$sig or die "player-color 192 raster failed\n$out$err";
$out eq "vcs_player_color_192 static ok: exact 192-line frame, VBLANK positioning, P0/P1 rows, Ball, and no missiles\n"
   or die "unexpected player-color 192 output: $out";
$err eq '' or die "player-color 192 harness stderr: $err";
my @terminal_zp=map { sprintf('0x%02x',map_zp($terminal_map,$_)) }
   qw(game_object_x game_player0_y game_player1_y game_ball_y);
($rc,$sig,$out,$err)=capture($harness,'terminal',$terminal_bin,@terminal_zp);
$rc==0 && !$sig or die "player-color 192 terminal raster failed\n$out$err";
$out eq "vcs_player_color_192 terminal ok: P0/P1/Ball reach the uniform twelfth-row raster\n"
   or die "unexpected player-color 192 terminal output: $out";
$err eq '' or die "player-color 192 terminal harness stderr: $err";

# Pin the Ball positions that exposed the old 48-byte mask's first-row defect.
# The direct countdown follows the public coordinate rule instead: height 3 is
# four two-line pairs, clipped only by the 192-line visible window.
for my $edge (['ball-top',0,'top edge'],['ball-row-edge',8,'first row boundary']) {
   my($mode,$ball_y,$label)=@$edge;
   my $edge_text=$fixture;
   $edge_text =~ s/game_ball_y := 45;/game_ball_y := $ball_y;/
      or die "could not set $label Ball Y in edge fixture\n";
   my $edge_src=File::Spec->catfile($tmp,"player_color_192_$mode.c26");
   my $edge_bin=File::Spec->catfile($tmp,"player_color_192_$mode.bin");
   my $edge_mapfile=File::Spec->catfile($tmp,"player_color_192_$mode.map");
   write_file($edge_src,$edge_text);
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$edge_mapfile,$edge_src,'-o',$edge_bin);
   $rc==0 && !$sig or die "$label build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$label build wrote output\n$out$err";
   my $edge_map=read_file($edge_mapfile);
   my @edge_zp=map { sprintf('0x%02x',map_zp($edge_map,$_)) }
      qw(game_object_x game_player0_y game_player1_y game_ball_y);
   ($rc,$sig,$out,$err)=capture($harness,$mode,$edge_bin,@edge_zp);
   $rc==0 && !$sig or die "$label raster failed\n$out$err";
   my $want=$mode eq 'ball-top'
      ? "vcs_player_color_192 ball-top ok: Ball clips cleanly at the visible top edge\n"
      : "vcs_player_color_192 ball-row-edge ok: Ball keeps four pairs across the first row boundary\n";
   $out eq $want or die "unexpected $label output: $out";
   $err eq '' or die "$label harness stderr: $err";
}

my $phase_src=File::Spec->catfile($repo,qw(test vcs_playfield_phase.cpp));
my $phase_exe=File::Spec->catfile($tmp,'player_color_192_playfield');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-I',$mos,$phase_src,@mos_input,'-o',$phase_exe);
$rc==0 && !$sig or die "player-color 192 playfield harness build failed\n$out$err";
$out eq '' && $err eq '' or die "player-color 192 playfield harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($phase_exe,$bin,12,12,40);
$rc==0 && !$sig or die "player-color 192 playfield timing failed\n$out$err";
$out eq "vcs_playfield_raster ok: 12 rows x 16 lines x 160 pixels\n"
   or die "unexpected player-color 192 playfield timing output: $out";
$err eq '' or die "player-color 192 playfield timing stderr: $err";

# The symmetric smoke playfield above is useful for broad object coverage but
# can hide a row-boundary PF timing error.  Compile the public asymmetric
# interactive example too and require every one of its 192 scanlines to emit
# the empirically Stella-safe PF byte/order/phase schedule.  This specifically
# rejects the 15/22/51/54 row-ending schedule that visibly tore the playfield.
my $interactive_src=File::Spec->catfile($repo,qw(examples 03_player_color_192 01_interactive player_color_192_interactive.c26));
my $interactive_bin=File::Spec->catfile($tmp,'player_color_192_interactive.bin');
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$interactive_src,'-o',$interactive_bin);
$rc==0 && !$sig or die "player-color 192 interactive playfield fixture build failed\n$out$err";
without_usage($out) eq '' && $err eq ''
   or die "player-color 192 interactive playfield fixture build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($phase_exe,$interactive_bin,12,12,40,'diagonal-192');
$rc==0 && !$sig or die "player-color 192 asymmetric playfield timing failed\n$out$err";
$out eq "vcs_playfield_diagonal_192 ok: 12 asymmetric rows x 16 lines with proven PF phases\n"
   or die "unexpected player-color 192 asymmetric playfield output: $out";
$err eq '' or die "player-color 192 asymmetric playfield stderr: $err";

my $display_src=File::Spec->catfile($repo,qw(test vcs_multicolor_display_raster.cpp));
my $display_exe=File::Spec->catfile($tmp,'player_color_192_display');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$display_src,@mos_input,'-o',$display_exe);
$rc==0 && !$sig or die "player-color 192 display harness build failed\n$out$err";
$out eq '' && $err eq '' or die "player-color 192 display harness build wrote output\n$out$err";
my @display_symbols=map { map_symbol($map,$_) }
   qw(game_playfield p0_graphics p1_graphics game_player0_colors game_player1_colors);
($rc,$sig,$out,$err)=capture($display_exe,$bin,'full-direct',@display_symbols);
$rc==0 && !$sig or die "player-color 192 display raster failed\n$out$err";
$out eq "vcs_multicolor_display_raster full-direct ok: exact PF rows, glyph bytes/colors, Ball, and score ownership\n"
   or die "unexpected player-color 192 display output: $out";
$err eq '' or die "player-color 192 display harness stderr: $err";

for my $phase (qw(init vblank draw overscan)) {
   my $bad=$fixture;
   my $removed=($bad =~ s/^\s*game_\Q$phase\E\(\);\s*$//m);
   $removed==1 or die "could not remove game_$phase from negative fixture\n";
   my $badsrc=File::Spec->catfile($tmp,"player_color_192_missing_$phase.c26");
   my $badbin=File::Spec->catfile($tmp,"player_color_192_missing_$phase.bin");
   write_file($badsrc,$bad);
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,$badsrc,'-o',$badbin);
   $rc!=0 && !$sig or die "missing $phase lifecycle unexpectedly linked\n$out$err";
   ($out.$err) =~ /required function 'game_\Q$phase\E' not used/
      or die "missing $phase produced wrong diagnostic\n$out$err";
}

print "vcs_player_color_192 ok\n";
