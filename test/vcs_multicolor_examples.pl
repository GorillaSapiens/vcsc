#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 30
# expectstdout: vcs_multicolor_examples ok: four interactive renderer examples pass build, frame, controls, filtered score-control, score-color, endpoint, and reset checks
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
sub capture { my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in); my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0); return ($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub map_zp { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n"; my $v=hex($1); $v<=0xff or die "$name is not zero-page\n"; return sprintf('0x%02x',$v); }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $legacy_cfg=File::Spec->catfile($vcs,qw(renderers faithful_legacy_playercolors faithful_legacy_playercolors.cfg));
my $color_component=read_file(File::Spec->catfile($vcs,'six_glyph_color_component.c26'));
$color_component =~ /recommend uint8_t TEMPLATE_color := 0x0e;/
   && $color_component =~ /asm sta RESP0;\s*asm sta RESP1;\s*asm lda TEMPLATE_color;\s*asm sta COLUP0;\s*asm sta COLUP1;/s
   && $color_component =~ /asm sta NUSIZ1;.*?(?:asm nop;\s*){4}asm sta HMCLR;/s
   or die "mutable-color score component lost its color or positioning contract\n";
my @cases=(
 {
   dir=>'02_faithful_legacy_playercolors/01_interactive',
   stem=>'faithful_legacy_playercolors_interactive', profile=>'legacy', prefix=>'legacy',
   score=>'legacy_score', color=>'legacy_score_color', extra=>['-Wa,--illegals','-T',$legacy_cfg],
 },
 {
   dir=>'03_player_color_192/01_interactive',
   stem=>'player_color_192_interactive', profile=>'192', prefix=>'game',
   score=>undef, color=>undef, extra=>[],
 },
 {
   dir=>'04_player_color_181/01_score_above/01_interactive',
   stem=>'player_color_181_score_above_interactive', profile=>'above', prefix=>'game',
   score=>'score_score', color=>'score_color', extra=>[],
 },
 {
   dir=>'04_player_color_181/02_score_below/01_interactive',
   stem=>'player_color_181_score_below_interactive', profile=>'below', prefix=>'game',
   score=>'score_score', color=>'score_color', extra=>[],
 },
);

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_multicolor_example_matrix.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_multicolor_example_matrix');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "interactive harness build failed\n$out$err";
$out eq '' && $err eq '' or die "interactive harness wrote output\n$out$err";

for my $case (@cases) {
   my $dir=$case->{dir}; my $stem=$case->{stem}; my $profile=$case->{profile};
   my $src=File::Spec->catfile($repo,'examples',$dir,"$stem.c26");
   my $text=read_file($src);
   $text =~ /^include "color_ntsc\.c26"$/m or die "$dir lacks named NTSC colors\n";
   $text =~ /^include "playfield\.c26"$/m or die "$dir lacks visual playfield rows\n";
   $text =~ /0b[.X]{8}(?![.X])/ or die "$dir lacks visual sprite glyphs\n";
   $text =~ /asm jmp \(\$fffc\);/ or die "$dir RESET does not jump through the reset vector\n";
   $text =~ /update_object_selection\(\)/ && $text =~ /move_selected_object\(\)/
      or die "$dir lacks interactive object selection and motion\n";
   $text =~ /SWCHA/ && $text =~ /SWCHB/ or die "$dir lacks joystick or console-switch input\n";
   $text =~ /SELECTED_PLAYER0/ && $text =~ /SELECTED_PLAYER1/ && $text =~ /SELECTED_BALL/
      or die "$dir does not cycle P0, P1, and Ball\n";
   $text !~ /SELECTED_MISSILE|SELECTED_M0|SELECTED_M1/
      or die "$dir exposes missiles absent from the public player-color profile\n";
   if ($profile eq 'legacy') {
      $text =~ /faithful_legacy_playercolors/ or die "$dir does not use the faithful legacy renderer\n";
      $text =~ /alias VCSC_FAITHFUL_LEGACY_HUMAN_SCORE_ORDER 1/
         or die "$dir does not opt into human left-to-right packed-BCD score order\n";
      $text =~ /legacy_score\[0\]\s*:=\s*0x56;.*?legacy_score\[1\]\s*:=\s*0x34;.*?legacy_score\[2\]\s*:=\s*0x12;/s
         or die "$dir does not initialize visible score 123456 in little-endian packed BCD\n";
   } elsif ($profile eq '192') {
      $text =~ /player_color_192/ or die "$dir does not use player_color_192\n";
      $text !~ /six_glyph_component|selected_score_digit|score_draw/
         or die "$dir unexpectedly contains score controls\n";
   } else {
      $text =~ /player_color_181/ && $text =~ /six_glyph_color_component/
         or die "$dir lacks 181-line renderer plus score composition\n";
      my $score=index($text,'score_draw();'); my $game=index($text,'game_draw();');
      $score>=0 && $game>=0 or die "$dir lacks component draws\n";
      ($profile eq 'above' ? $score<$game : $game<$score) or die "$dir draw order is wrong\n";
      $text =~ /vcs_ntsc_component_handoff\(\)/ or die "$dir lacks component handoff\n";
   }
   if (defined $case->{score}) {
      $text =~ /uint8_t selected_score_digit := 0;/
         or die "$dir does not start with the ones digit selected\n";
      $text =~ /uint8_t right_joystick_countdown := 19;/
         && $text =~ /uint8_t right_joystick_previous := 0x0f;/
         && $text =~ /asm dec right_joystick_countdown;/
         && $text =~ /asm eor right_joystick_previous;/
         && $text =~ /asm lda #19;\s*asm sta right_joystick_countdown;/s
         or die "$dir lacks twentieth-frame two-sample right-joystick filtering\n";
      $text =~ /asm adc #\$10;.*?asm sta \Q$case->{color}\E;/s
         or die "$dir does not advance score color when the selected digit changes\n";
      $text =~ /score_digit_low/ && $text =~ /score_digit_middle/ && $text =~ /score_digit_high/
         or die "$dir lacks decimal 10^n score weights\n";
   }

   my $bin=File::Spec->catfile($tmp,"$stem.bin"); my $mapfile=File::Spec->catfile($tmp,"$stem.map");
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,@{$case->{extra}},$src,'-o',$bin);
   $rc==0 && !$sig or die "$dir build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$dir build wrote output\n$out$err";
   length(read_file($bin))==4096 or die "$dir ROM is not 4096 bytes\n";
   my $map=read_file($mapfile); my $prefix=$case->{prefix};
   my @args=(
      $bin,$profile,
      map_zp($map,"${prefix}_object_x"),
      map_zp($map,"${prefix}_player0_y"),
      map_zp($map,"${prefix}_player1_y"),
      map_zp($map,"${prefix}_ball_y"),
      map_zp($map,'selected_object'),
      map_zp($map,'select_switch_ready'),
   );
   if (defined $case->{score}) {
      push @args,map_zp($map,$case->{score}),map_zp($map,'selected_score_digit'),map_zp($map,'right_joystick_countdown'),map_zp($map,'right_joystick_previous'),map_zp($map,$case->{color});
   } else {
      push @args,qw(none none none none none);
   }
   ($rc,$sig,$out,$err)=capture($harness,@args);
   $rc==0 && !$sig or die "$dir runtime failed\n$out$err";
   $out =~ /^vcs_multicolor_example_matrix \Q$profile\E ok: interactive controls and reset across \d+ frames\n$/
      or die "$dir unexpected runtime output: $out";
   $err eq '' or die "$dir runtime stderr: $err";
}
print "vcs_multicolor_examples ok: four interactive renderer examples pass build, frame, controls, filtered score-control, score-color, endpoint, and reset checks\n";
