#!/usr/bin/perl
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
sub write_file {
   my($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n";
   print {$f} $d; close($f) or die "close $p: $!\n";
}
sub without_usage { my($s)=@_; $s =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//; return $s; }
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
my $cfg=File::Spec->catfile($vcs,qw(kernels standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $module=File::Spec->catfile($vcs,qw(kernels player_color_192 player_color_192.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures player_color_192 smoke.c26));
my $bin=File::Spec->catfile($tmp,'player_color_192.bin');
my $mapfile=File::Spec->catfile($tmp,'player_color_192.map');
my $terminal_source=File::Spec->catfile($repo,qw(test fixtures player_color_192 terminal.c26));
my $terminal_bin=File::Spec->catfile($tmp,'player_color_192_terminal.bin');
my $terminal_mapfile=File::Spec->catfile($tmp,'player_color_192_terminal.map');
my $reference=File::Spec->catfile($repo,qw(test fixtures player_color_192 reference_terminal_stella_7.0.png));
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "player-color 192 build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 192 build wrote output\n$out$err";
-s $bin == 4096 or die "player-color 192 ROM is not 4096 bytes\n";
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$terminal_mapfile,$terminal_source,'-o',$terminal_bin);
$rc==0 && !$sig or die "player-color 192 terminal build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "player-color 192 terminal build wrote output\n$out$err";
-s $terminal_bin == 4096 or die "player-color 192 terminal ROM is not 4096 bytes\n";
my $terminal_map=read_file($terminal_mapfile);
sha256_hex(read_file($reference)) eq
   '86b15f426011765d4b8f75b90e413a2f268608b17cef8ac04a4eee7c1878a323'
   or die "reviewed player-color 192 Stella reference PNG changed\n";
my $text=read_file($module);
my $fixture=read_file($source);
my $map=read_file($mapfile);
require_re($text,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*192/, 'visible-line contract changed');
require_re($text,qr/TEMPLATE_PLAYFIELD_BYTES\s*:=\s*48/, 'playfield-byte contract changed');
require_re($text,qr/TEMPLATE_PLAYFIELD_ROWS\s*:=\s*12/, 'playfield-row contract changed');
require_re($text,qr/TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*13/, 'public-RAM contract changed');
require_re($text,qr/TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*53/, 'private-RAM contract changed');
require_re($text,qr/TEMPLATE_MODULE_RAM_BYTES\s*:=\s*66/, 'module-RAM contract changed');
require_re($fixture,qr/game_draw\(\);\s*vcs_ntsc_begin_overscan\(\);/s,
   'fixture no longer enters overscan immediately after the 192-line draw');
require_re($text,qr/TEMPLATE_playfield\+44/, 'full-height final-row playfield path is missing');
require_re($text,qr/TEMPLATE_object_masks \+ 35.*COLUP1/s,
   'full-height final-row P1 color path is missing');
require_re($text,qr/TEMPLATE_object_masks \+ 43.*TEMPLATE_player0_latch/s,
   'full-height final-row P0 color path is missing');
for my $bad (qw(score font VSYNC VBLANK TIM1T TIM8T TIM64T T1024T INTIM TIMINT)) {
   $text !~ /^\s*asm\s+.*\b\Q$bad\E\b/im or die "component owns forbidden $bad resource\n";
}
my $code=$text;
$code =~ s{//[^\n]*}{}g;
$code =~ s{/\*.*?\*/}{}gs;
$code !~ /\b(?:lax|dcp|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|axs|xaa|ahx|shx|shy|tas|las)\b/i
   or die "official component contains an unofficial mnemonic\n";
$code !~ /\bop[0-9A-Fa-f]{2}\b/ or die "official component contains a raw opcode escape\n";
for my $name (qw(game_playfield game_player0_colors game_player1_colors p0_graphics p1_graphics game_reposition_table game_player_position_table)) {
   require_re($map,qr/RODATA\.__vcsc_object\$\Q$name\E\s+load=\$[0-9A-Fa-f]{4}.*page=hard/, "$name is not hard-page-contained");
}
my %sizes=(game_object_x=>5,game_player0_y=>1,game_player1_y=>1,game_ball_y=>1,
   game_player0_graphics=>2,game_player1_graphics=>2,game_player0_height=>1,
   game_player1_height=>1,game_ball_height=>1,game_workspace=>5,
   game_playfield_position=>1,game_object_masks=>44,game_player0_latch=>1);
my $sum=0;
for my $name (sort keys %sizes) {
   my $got=bss_size($map,$name); $got==$sizes{$name} or die "$name is $got bytes; expected $sizes{$name}\n"; $sum += $got;
}
$sum==66 or die "component BSS totals $sum bytes; expected 66\n";
$map !~ /\bgame_(?:score|score_color|missile0|missile1)\b/ or die "forbidden score/missile state linked\n";
$map !~ /(?:score|font)/i or die "score/font symbols linked\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_player_color_181.cpp));
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
$out eq "vcs_player_color_181 static ok: exact P0/P1 row colors, P0/P1/BL position and pixel endpoints, no missiles\n"
   or die "unexpected player-color 192 output: $out";
$err eq '' or die "player-color 192 harness stderr: $err";
my @terminal_zp=map { sprintf('0x%02x',map_zp($terminal_map,$_)) }
   qw(game_object_x game_player0_y game_player1_y game_ball_y);
($rc,$sig,$out,$err)=capture($harness,'terminal192',$terminal_bin,@terminal_zp);
$rc==0 && !$sig or die "player-color 192 terminal raster failed\n$out$err";
$out eq "vcs_player_color_192 terminal ok: twelfth-row P0/P1 colors and BL raster reach the final gameplay band\n"
   or die "unexpected player-color 192 terminal output: $out";
$err eq '' or die "player-color 192 terminal harness stderr: $err";

my $phase_src=File::Spec->catfile($repo,qw(test vcs_playfield_phase.cpp));
my $phase_exe=File::Spec->catfile($tmp,'player_color_192_playfield');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-I',$mos,$phase_src,@mos_input,'-o',$phase_exe);
$rc==0 && !$sig or die "player-color 192 playfield harness build failed\n$out$err";
$out eq '' && $err eq '' or die "player-color 192 playfield harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($phase_exe,$bin,'11','12');
$rc==0 && !$sig or die "player-color 192 playfield raster failed\n$out$err";
$out eq "vcs_playfield_raster ok: 11 rows x 16 lines x 160 pixels\n"
   or die "unexpected player-color 192 playfield output: $out";
$err eq '' or die "player-color 192 playfield harness stderr: $err";

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
