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
my $dir=File::Spec->catdir($repo,qw(examples 03_player_color_192 02_animated_sprites));
my $source=File::Spec->catfile($dir,'player_color_192_animated_sprites.c26');
my $license=File::Spec->catfile($dir,'LICENSE.txt');
my $bin=File::Spec->catfile($tmp,'player_color_192_animated_sprites.bin');
my $mapfile=File::Spec->catfile($tmp,'player_color_192_animated_sprites.map');
my $source_text=read_file($source);
my $license_text=read_file($license);

for my $set (0..29) {
   my $first=1+$set*4;
   my $last=$first+3;
   my $label=sprintf('source_set_%02d_sprites_%03d_%03d',$set,$first,$last);
   $source_text =~ /\/\/\s*\Q$label\E\b/
      or die "animated gallery missing source set $set ($first-$last)\n";
}
my $glyph_count=()=$source_text =~ /\bgame_SPRITE_GLYPH\s*\(/g;
$glyph_count==120 or die "animated gallery has $glyph_count frames; expected 120\n";
for my $page (0..2) {
   $source_text =~ /page\s+align\s*\(\s*256\s*\)\s+const\s+uint8_t\s+sprite_frames_\Q$page\E\[256\]/
      or die "animation frame aligned hard page $page is missing\n";
}
$source_text =~ /page\s+align\s*\(\s*256\s*\)\s+const\s+uint8_t\s+sprite_frames_3\[192\]/
   or die "animation final 192-byte aligned hard page is missing\n";
$source_text !~ /Pad the final hard page|sprite_frames_3\[256\]/
   or die "animation source reintroduced literal final-page padding\n";
$source_text =~ /alias\s+SPRITE_COUNT\s+30/
   or die "animation set count changed\n";
$source_text =~ /alias\s+FRAME_HOLD\s+8/ or die "animation frame hold changed\n";
$source_text =~ /alias\s+THREE_FRAME_SET\s+3/ or die "three-frame set identity changed\n";
$source_text =~ /alias\s+LEFT_EDGE\s+16/ or die "animation left-edge color-safe endpoint changed\n";
$source_text =~ /alias\s+RIGHT_EDGE\s+140/ or die "animation color-safe right endpoint changed\n";
$source_text =~ /animation_phase_next\[16\]/ &&
$source_text =~ /low bits advance modulo 4 while bits 2\.\.3/ &&
$source_text =~ /sprite1\s*==\s*THREE_FRAME_SET/ &&
$source_text =~ /animation_state\s*&\s*0x0c/
   or die "set 03 no longer has a packed modulo-3 frame counter\n";
$source_text =~ /uint8_t\s+animation_state\s*:=\s*0/ &&
$source_text =~ /animation_state\s*\+=\s*0x10/ &&
$source_text =~ /animation_state\s*>=\s*\(FRAME_HOLD\s*<<\s*4\)/ &&
$source_text =~ /animation_phase_next\[animation_state\s*&\s*0x0f\]/ &&
$source_text !~ /uint8_t\s+animation_(?:frame|clock)/
   or die "animation phase and frame-hold clock are no longer packed into one byte\n";
$source_text =~ /alias\s+CONTROL_SELECT_READY\s+0x01/ &&
$source_text =~ /alias\s+CONTROL_PAUSED\s+0x02/ &&
$source_text =~ /alias\s+CONTROL_FIRE_READY\s+0x04/ &&
$source_text =~ /uint8_t\s+control_flags\s*:=\s*CONTROL_SELECT_READY\s*\|\s*CONTROL_FIRE_READY/ &&
$source_text !~ /uint8_t\s+(?:select_ready|pause_animation|fire_ready)/
   or die "Select/fire edge state and pause state are no longer packed into one byte\n";
$source_text =~ /void\s+install_frames\s*\(void\)\s*\{(.*?)\n\}/s
   or die "cannot locate install_frames source body\n";
my $install_frames_body=$1;
$install_frames_body !~ /\basm\b/
   or die "install_frames regressed to handwritten assembly\n";
$install_frames_body =~ /game_player0_graphics\s*:=\s*sprite_row_colors_0/ &&
$install_frames_body =~ /game_player0_graphics\s*\+=\s*\(sprite0\s*&\s*0x0f\)\s*<<\s*4/ &&
$install_frames_body =~ /pico8_tia_palette\[game_player0_graphics\[color_row0\s*>>\s*1\]\s*&\s*0x0f\]/ &&
$install_frames_body =~ /game_player1_graphics\s*:=\s*sprite_frames_3/
   or die "install_frames no longer uses readable VCSC table/pointer selection\n";
$source_text =~ /alias\s+VCS_PLAYER_COLOR_MUTABLE_COLORS\s+1/
   or die "animated gallery no longer requests mutable renderer color tables\n";
$source_text =~ /most frequent nontransparent color wins/ &&
$source_text =~ /source-derived color per sprite row/ &&
$source_text =~ /sprite_row_colors_0\[256\]/ &&
$source_text =~ /sprite_row_colors_1\[224\]/
   or die "animated gallery source-derived row-color conversion is missing\n";
$source_text =~ /game_PLAYER0_X\s*:=\s*LEFT_EDGE/ && $source_text =~ /game_PLAYER1_X\s*:=\s*LEFT_EDGE/
   or die "animated sprites no longer start at the left edge\n";
$source_text =~ /if\s*\(game_PLAYER0_X\s*>=\s*RIGHT_EDGE\)/
   or die "right-edge wrap control missing\n";
$source_text =~ /if\s*\(SWCHB\s*&\s*0x02\)/ or die "Game Select edge control missing\n";
$source_text =~ /if\s*\(INPT4\s*&\s*0x80\)/ or die "left-fire pause control missing\n";
$license_text =~ /explicit exception to `examples\/LICENSE\.txt`/ &&
$license_text =~ /Quick/ && $license_text =~ /CC BY-NC-SA 4\.0/
   or die "animated example attribution/local license missing\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "animated gallery build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "animated gallery build wrote output\n$out$err";
-s $bin == 4096 or die "animated gallery ROM is not 4096 bytes\n";
my $map=read_file($mapfile);
my @frame_names=map { "sprite_frames_$_" } 0..3;
my @frame_sizes=(0x100,0x100,0x100,0x0c0);
for my $i (0..$#frame_names) {
   my $name=$frame_names[$i];
   my $size=sprintf('%04x',$frame_sizes[$i]);
   $map =~ /RODATA\.__vcsc_object\$\Q$name\E\s+load=\$[0-9A-Fa-f]{4}.*size=\$$size.*page=hard.*component-align=\$0100/i
      or die "$name lost its aligned hard-page placement\n";
   (map_value($map,$name)&0xff)==0
      or die "$name no longer starts at low byte zero\n";
}
for my $name (qw(game_player0_colors game_player1_colors)) {
   my $base=map_value($map,$name);
   $base<=0xf8 or die "$name is not an eight-byte page-contained RAM table\n";
   $map =~ /BSS\.__vcsc_object\$\Q$name\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0008/
      or die "$name is not an eight-byte mutable BSS object\n";
}
$map =~ /RODATA\.__vcsc_object\$pico8_tia_palette\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0010/
   or die "PICO-8-to-TIA palette is not a sixteen-byte immutable object\n";
my @color_names=qw(sprite_row_colors_0 sprite_row_colors_1);
my @color_sizes=(0x100,0x0e0);
for my $i (0..$#color_names) {
   my $name=$color_names[$i];
   my $size=sprintf('%04x',$color_sizes[$i]);
   $map =~ /RODATA\.__vcsc_object\$\Q$name\E\s+load=\$[0-9A-Fa-f]{4}\s+size=\$$size\s+page=hard.*component-align=\$0100/i
      or die "$name lost its aligned hard-page source-color placement\n";
   (map_value($map,$name)&0xff)==0
      or die "$name no longer starts at low byte zero\n";
}

# Pin the exact original one-bit occupancy extracted from source sprites 1..120.
# Sprite 16 remains blank in storage but the modulo-3 counter must never select it.
my $rom=read_file($bin);
my $asset_bytes='';
for my $i (0..$#frame_names) {
   my $name=$frame_names[$i];
   my $base=map_value($map,$name);
   $base>=0xf000 && $base<=0xff00 or die "$name is outside the cartridge ROM\n";
   $asset_bytes .= substr($rom,$base-0xf000,$frame_sizes[$i]);
}
length($asset_bytes)==960 or die "animated source-sprite object bytes changed from 960\n";
sha256_hex($asset_bytes) eq
   '7ff024d9b8c75da665d9c8c836650e95c4576f76827e06c07250be0a1d16cacb'
   or die "animated source-sprite occupancy changed\n";
for my $frame (0..119) {
   my $blank=substr($asset_bytes,$frame*8,8) eq ("\0" x 8);
   if ($frame==15) {
      $blank or die "source sprite 16 is no longer blank\n";
   }
   else {
      !$blank or die "unexpected blank source sprite " . ($frame+1) . "\n";
   }
}
my $row_color_bytes='';
for my $i (0..$#color_names) {
   my $base=map_value($map,$color_names[$i]);
   $base>=0xf000 && $base<=0xff00 or die "$color_names[$i] is outside cartridge ROM\n";
   $row_color_bytes .= substr($rom,$base-0xf000,$color_sizes[$i]);
}
length($row_color_bytes)==480 or die "packed source row-color table is not 480 bytes\n";
sha256_hex($row_color_bytes) eq
   '378b365834c7c211067a1f80194288a46215570d8a6a5e7715fc5f44f892d10a'
   or die "packed source-derived row colors changed\n";

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
   qw(sprite0 sprite1 animation_state control_flags game_object_x game_player0_graphics game_player1_graphics);
my @symbol_args=map { symbol_arg($map,$_) }
   (@frame_names,@color_names,qw(game_player0_colors game_player1_colors pico8_tia_palette));
my @args=(@zp_args,@symbol_args);
($rc,$sig,$out,$err)=capture($harness,$bin,@args);
$rc==0 && !$sig or die "animated gallery emulator proof failed\n$out$err";
$out eq "vcs_player_color_192_animation ok: 29 four-frame animations use modulo-4 playback while source set 03 independently uses modulo-3 playback, preserve exact source pixels without displaying blank sprite 16, use source-derived row colors that move with each original frame, wrap at X=16, keep 262-line frames, and retain pair selection and pause controls\n"
   or die "unexpected animation harness output: $out";
$err eq '' or die "animation harness stderr: $err";

# The animated gallery is the second public player_color_192 example and was
# affected by the same one-scanline row-boundary playfield tear. Verify its
# full/checker/blank/checker/full playfield independently of sprite animation.
my $phase_src=File::Spec->catfile($repo,qw(test vcs_playfield_phase.cpp));
my $phase=File::Spec->catfile($tmp,'vcs_player_color_192_gallery_playfield');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-I',$mos,$phase_src,@mos_input,'-o',$phase);
$rc==0 && !$sig or die "animated gallery playfield harness build failed\n$out$err";
$out eq '' && $err eq '' or die "animated gallery playfield harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($phase,$bin,12,12,40,'gallery-192');
$rc==0 && !$sig or die "animated gallery playfield timing failed\n$out$err";
$out eq "vcs_playfield_gallery_192 ok: 12 gallery rows x 16 lines with proven PF phases\n"
   or die "unexpected animated gallery playfield output: $out";
$err eq '' or die "animated gallery playfield stderr: $err";

print "vcs_player_color_192_animation_test ok\n";
