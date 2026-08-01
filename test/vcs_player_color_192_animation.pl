#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 30
# expectstdout: vcs_player_color_192_animation_test ok
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
my $license=File::Spec->catfile($dir,'ASSET_LICENSE.md');
my $bin=File::Spec->catfile($tmp,'player_color_192_animated_sprites.bin');
my $mapfile=File::Spec->catfile($tmp,'player_color_192_animated_sprites.map');
my $text=read_file($source);
my $license_text=read_file($license);

for my $name (qw(running_man dog cat t_rex worm orange_hopper blue_hopper helicube)) {
   $text =~ /\/\/\s*\Q$name\E\b/ or die "animated gallery missing $name\n";
}
my $glyph_count=()=$text =~ /\bgame_SPRITE_GLYPH\s*\(/g;
$glyph_count==32 or die "animated gallery has $glyph_count frames; expected 32\n";
$text =~ /page\s+const\s+uint8_t\s+sprite_frames\[256\]/
   or die "animation frames are no longer one aligned 256-byte table\n";
$text =~ /alias\s+FRAME_HOLD\s+8/ or die "animation frame hold changed\n";
$text =~ /alias\s+PAIR_LOOPS\s+4/ or die "animation pair-loop count changed\n";
$text =~ /if\s*\(SWCHB\s*&\s*0x02\)/ or die "Game Select edge control missing\n";
$text =~ /if\s*\(INPT4\s*&\s*0x80\)/ or die "left-fire pause control missing\n";
$license_text =~ /Quick/ && $license_text =~ /CC BY-NC-SA 4\.0/
   or die "animated artwork attribution/license missing\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "animated gallery build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "animated gallery build wrote output\n$out$err";
-s $bin == 4096 or die "animated gallery ROM is not 4096 bytes\n";
my $map=read_file($mapfile);
$map =~ /RODATA\.__vcsc_object\$sprite_frames\s+load=\$[0-9A-Fa-f]{4}.*size=\$0100.*page=hard/
   or die "sprite_frames lost its 256-byte hard-page placement\n";

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
   qw(sprite0 sprite1 animation_frame animation_clock animation_loop pause_animation select_ready fire_ready game_player0_graphics game_player1_graphics);
my @symbol_args=map { symbol_arg($map,$_) }
   qw(sprite_frames game_player0_colors game_player1_colors);
my @args=(@zp_args,@symbol_args);
($rc,$sig,$out,$err)=capture($harness,$bin,@args);
$rc==0 && !$sig or die "animated gallery emulator proof failed\n$out$err";
$out eq "vcs_player_color_192_animation ok: eight four-frame galleries across four loops per pair, exact player pixels and row-color-table use, 262-line frames, pair selection, and pause controls\n"
   or die "unexpected animation harness output: $out";
$err eq '' or die "animation harness stderr: $err";

print "vcs_player_color_192_animation_test ok\n";
