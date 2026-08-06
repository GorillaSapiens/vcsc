#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_player_color_192_animation_test ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
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
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub map_value {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   return hex($1);
}
sub zp_arg {
   my($map,$name)=@_; my $v=map_value($map,$name);
   $v<=0xff or die "$name is not in zero page\n";
   return sprintf('0x%02x',$v);
}
sub symbol_arg { return sprintf('0x%04x',map_value(@_)); }

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $dir=File::Spec->catdir($repo,qw(examples 03_player_color_192 02_animated_sprites));
my $source=File::Spec->catfile($dir,'player_color_192_animated_sprites.c26');
my $bin=File::Spec->catfile($tmp,'player_color_192_animated_sprites.bin');
my $mapfile=File::Spec->catfile($tmp,'player_color_192_animated_sprites.map');
my $source_text=read_file($source);

for my $set (0..29) {
   my $first=1+$set*4;
   my $last=$first+3;
   my $label=sprintf('animation_set_%02d',$set);
   $source_text =~ /\/\/\s*\Q$label\E\b/
      or die "animated gallery missing animation set $set\n";
}
my $glyph_count=()=$source_text =~ /\bgame_SPRITE_GLYPH\s*\(/g;
$glyph_count==120 or die "animated gallery has $glyph_count frames; expected 120\n";
for my $page (0..3) {
   $source_text =~ /page\s+const\s+uint8_t\s+sprite_frames_\Q$page\E\[256\]/
      or die "animation frame hard page $page is missing\n";
}
$source_text =~ /alias\s+SPRITE_COUNT\s+30/
   or die "animation set count changed\n";
$source_text =~ /alias\s+FRAME_HOLD\s+8/ or die "animation frame hold changed\n";
$source_text =~ /alias\s+RIGHT_EDGE\s+159/ or die "animation right-edge endpoint changed\n";
$source_text =~ /alias\s+VCS_PLAYER_COLOR_192_MUTABLE_COLORS\s+1/
   or die "animated gallery no longer requests mutable renderer color tables\n";
$source_text =~ /transparent rows above each glyph/
   or die "animated gallery color-following logic is missing\n";
$source_text =~ /game_PLAYER0_X\s*:=\s*0/ && $source_text =~ /game_PLAYER1_X\s*:=\s*0/
   or die "animated sprites no longer start at the left edge\n";
$source_text =~ /if\s*\(game_PLAYER0_X\s*>=\s*RIGHT_EDGE\)/
   or die "right-edge wrap control missing\n";
$source_text =~ /if\s*\(SWCHB\s*&\s*0x02\)/ or die "Game Select edge control missing\n";
$source_text =~ /if\s*\(INPT4\s*&\s*0x80\)/ or die "left-fire pause control missing\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "animated gallery build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "animated gallery build wrote output\n$out$err";
-s $bin == 4096 or die "animated gallery ROM is not 4096 bytes\n";
my $map=read_file($mapfile);
my @frame_names=map { "sprite_frames_$_" } 0..3;
for my $name (@frame_names) {
   $map =~ /RODATA\.__vcsc_object\$\Q$name\E\s+load=\$[0-9A-Fa-f]{4}.*size=\$0100.*page=hard/
      or die "$name lost its 256-byte hard-page placement\n";
   (map_value($map,$name)&0xff)==0
      or die "$name no longer starts at low byte zero\n";
}
for my $name (qw(game_player0_colors game_player1_colors)) {
   my $base=map_value($map,$name);
   $base<=0xf8 or die "$name is not an eight-byte page-contained RAM table\n";
   $map =~ /BSS\.__vcsc_object\$\Q$name\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0008/
      or die "$name is not an eight-byte mutable BSS object\n";
}
for my $name (qw(player0_palette player1_palette)) {
   $map =~ /RODATA\.__vcsc_object\$\Q$name\E\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0008/
      or die "$name is not an eight-byte immutable palette\n";
}

# Pin the exact original one-bit occupancy of the 30 CC0 animation sets.
my $rom=read_file($bin);
my $asset_bytes='';
for my $name (@frame_names) {
   my $base=map_value($map,$name);
   $base>=0xf000 && $base<=0xff00 or die "$name is outside the cartridge ROM\n";
   $asset_bytes .= substr($rom,$base-0xf000,256);
}
sha256_hex(substr($asset_bytes,0,960)) eq
   '7ae3a0ae891e7a22b2f81bc28a89b389b95b313d0d0ee7438e5ae4fa8617620f'
   or die "animated CC0 sprite occupancy changed\n";
substr($asset_bytes,960,64) eq ("\0" x 64)
   or die "final sprite hard-page padding is not zero\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_player_color_192_animation.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_player_color_192_animation');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-Wall','-Wextra','-Werror','-I',$mos,
   $hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "animation harness build failed\n$out$err";
$out eq '' && $err eq '' or die "animation harness build wrote output\n$out$err";

my @zp_args=map { zp_arg($map,$_) }
   qw(sprite0 sprite1 animation_frame animation_clock pause_animation select_ready fire_ready game_object_x game_player0_graphics game_player1_graphics);
my @symbol_args=map { symbol_arg($map,$_) }
   (@frame_names,qw(game_player0_colors game_player1_colors player0_palette player1_palette));
my @args=(@zp_args,@symbol_args);
($rc,$sig,$out,$err)=capture($harness,$bin,@args);
$rc==0 && !$sig or die "animated gallery emulator proof failed\n$out$err";
$out eq "vcs_player_color_192_animation ok: all thirty original CC0 four-frame animations traverse left-to-right in fifteen pairs, preserve exact pixels, rotate row colors with vertical sprite motion, wrap at X=0, keep 262-line frames, and retain pair selection and pause controls\n"
   or die "unexpected animation harness output: $out";
$err eq '' or die "animation harness stderr: $err";

print "vcs_player_color_192_animation_test ok\n";
