#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: interactive sprite orientation matches faithful legacy example
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find;
use File::Spec;

sub read_file {
   my($path)=@_;
   open(my $fh,'<',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>; close($fh); return $text // '';
}
sub initializer {
   my($text,$name,$size)=@_;
   $size //= 8;
   $text =~ /\b\Q$name\E\s*\[$size\]\s*:=\s*\{(.*?)\};/s
      or die "missing $name initializer\n";
   return $1;
}
sub args {
   my($block,$macro)=@_;
   $block =~ /\b\Q$macro\E\s*\((.*?)\)/s
      or die "missing $macro invocation\n";
   my @v=split /,/, $1;
   for (@v) { s{//.*$}{}mg; s/\s+//g; }
   @v=grep { length } @v;
   @v==8 or die "$macro has ".scalar(@v)." rows, expected 8\n";
   return \@v;
}
sub frames {
   my($block,$macro)=@_;
   my @frames;
   while ($block =~ /\b\Q$macro\E\s*\((.*?)\)/sg) {
      my @v=split /,/, $1;
      for (@v) { s{//.*$}{}mg; s/\s+//g; }
      @v=grep { length } @v;
      @v==8 or die "$macro has ".scalar(@v)." rows, expected 8\n";
      push @frames,\@v;
   }
   @frames or die "missing $macro invocation\n";
   return \@frames;
}
sub same_frames {
   my($got,$want,$label)=@_;
   @$got==@$want or die "$label frame count changed\n";
   for my $i (0..$#$want) {
      same($got->[$i],$want->[$i],"$label frame $i");
   }
}

sub plain_values {
   my($block)=@_;
   my @v=split /,/, $block;
   for (@v) { s{//.*$}{}mg; s/\s+//g; }
   @v=grep { length } @v;
   @v==8 or die "plain color array has ".scalar(@v)." rows, expected 8\n";
   return \@v;
}
sub same {
   my($got,$want,$label)=@_;
   join("\n",@$got) eq join("\n",@$want)
      or die "$label does not match the faithful legacy visual orientation\n";
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
my $faithful_path=File::Spec->catfile($repo,qw(examples 02_faithful_legacy_playercolors 01_interactive faithful_legacy_playercolors_interactive.c26));
my $faithful=read_file($faithful_path);
my $p0_frames=frames(initializer($faithful,'p0_animation',32),'legacy_SPRITE_GLYPH');
my $p1_frames=frames(initializer($faithful,'p1_animation',32),'legacy_SPRITE_GLYPH');
@$p0_frames==4 && @$p1_frames==4 or die "faithful legacy animation must have four frames per player\n";
my @p0_reverse_frames=map { [reverse @$_] } @$p0_frames;
my @p1_reverse_frames=map { [reverse @$_] } @$p1_frames;
my $p0c=args(initializer($faithful,'p0c'),'legacy_SPRITE_ROWS');
my $p1c=args(initializer($faithful,'p1c'),'legacy_SPRITE_ROWS');
my @p0c_reverse=reverse @$p0c;
my @p1c_reverse=reverse @$p1c;
$faithful =~ /legacy_player0_graphics\s*\+=\s*\(\(legacy_PLAYER0_X\s*\^\s*legacy_player0_y\)\s*&\s*0x03\)\s*<<\s*3/
   or die "faithful legacy P0 animation selector changed\n";
$faithful =~ /legacy_player1_graphics\s*\+=\s*\(\(legacy_PLAYER1_X\s*\^\s*legacy_player1_y\)\s*&\s*0x03\)\s*<<\s*3/
   or die "faithful legacy P1 animation selector changed\n";

my @definitions=(
   [qw(examples 03_player_color_192 01_interactive player_color_192_interactive.c26)],
   [qw(examples 05_all_five_192 01_interactive all_five_192_interactive.c26)],
   [qw(examples common player_color_181_interactive_common.c26)],
   [qw(examples common all_five_181_interactive_common.c26)],
   [qw(examples 16_all_five_player_color_181 all_five_player_color_181_interactive_common.c26)],
   [qw(examples 11_all_five_170 01_score_above_and_below 01_interactive all_five_170_score_above_and_below_interactive.c26)],
);

for my $parts (@definitions) {
   my $path=File::Spec->catfile($repo,@$parts);
   my $text=read_file($path);
   if ($text =~ /\bp0_animation\s*\[32\]/) {
      same_frames(frames(initializer($text,'p0_animation',32),'game_SPRITE_GLYPH'),\@p0_reverse_frames,"$path P0");
      same_frames(frames(initializer($text,'p1_animation',32),'game_SPRITE_GLYPH'),\@p1_reverse_frames,"$path P1");
      $text =~ /game_player0_graphics\s*\+=\s*\(\(game_PLAYER0_X\s*\^\s*game_player0_y\)\s*&\s*0x03\)\s*<<\s*3/
         or die "$path P0 animation selector changed\n";
      $text =~ /game_player1_graphics\s*\+=\s*\(\(game_PLAYER1_X\s*\^\s*game_player1_y\)\s*&\s*0x03\)\s*<<\s*3/
         or die "$path P1 animation selector changed\n";
   } else {
      same(args(initializer($text,'p0_graphics'),'game_SPRITE_GLYPH'),$p0_reverse_frames[0],"$path P0");
      same(args(initializer($text,'p1_graphics'),'game_SPRITE_GLYPH'),$p1_reverse_frames[0],"$path P1");
   }
   next if $path =~ /all_five/;
   if ($path =~ /player_color_192_interactive/) {
      same(plain_values(initializer($text,'game_player0_colors')),$p0c,"$path P0 colors");
      same(plain_values(initializer($text,'game_player1_colors')),$p1c,"$path P1 colors");
   } else {
      same(args(initializer($text,'game_player0_colors'),'game_SPRITE_GLYPH'),\@p0c_reverse,"$path P0 colors");
      same(args(initializer($text,'game_player1_colors'),'game_SPRITE_GLYPH'),\@p1c_reverse,"$path P1 colors");
   }
}

my @animation_sources;
find(sub {
   return unless -f $_ && /\.c26\z/;
   my $path=$File::Find::name;
   my $text=read_file($path);
   push @animation_sources,$path if $text =~ /\bp0_animation\s*\[32\]/;
},File::Spec->catdir($repo,'examples'));
@animation_sources==15
   or die "expected 15 standard interactive animation source bodies, found ".scalar(@animation_sources)."\n";
for my $path (@animation_sources) {
   next if $path eq $faithful_path;
   my $text=read_file($path);
   same_frames(frames(initializer($text,'p0_animation',32),'game_SPRITE_GLYPH'),\@p0_reverse_frames,"$path P0");
   same_frames(frames(initializer($text,'p1_animation',32),'game_SPRITE_GLYPH'),\@p1_reverse_frames,"$path P1");
   $text =~ /game_player0_graphics\s*\+=\s*\(\(game_PLAYER0_X\s*\^\s*game_player0_y\)\s*&\s*0x03\)\s*<<\s*3/
      or die "$path P0 animation selector changed\n";
   $text =~ /game_player1_graphics\s*\+=\s*\(\(game_PLAYER1_X\s*\^\s*game_player1_y\)\s*&\s*0x03\)\s*<<\s*3/
      or die "$path P1 animation selector changed\n";
}

my @leaves;
find(sub {
   return unless -f $_ && /\.c26\z/ && $File::Find::name =~ m{/\d+_interactive/};
   push @leaves,$File::Find::name;
},File::Spec->catdir($repo,'examples'));
@leaves or die "found no interactive sources\n";
my $faithful_seen=grep { $_ eq $faithful_path } @leaves;
$faithful_seen==1
   or die "interactive source discovery did not find the faithful legacy baseline\n";
for my $path (@leaves) {
   next if $path eq $faithful_path;
   my $text=read_file($path);
   my $covered=$text =~ /\bp0_graphics\s*\[8\]/ ||
               $text =~ /\bp0_animation\s*\[32\]/ ||
               $text =~ /include\s+"\.\.\/\.\.\/\.\.\/common\/(?:player_color|all_five)_181_interactive_common\.c26|multisprite_interactive_common\.c26"/ ||
               $text =~ /include\s+"\.\.\/\.\.\/all_five_player_color_181_interactive_common\.c26"/;
   $covered or die "$path does not use a normalized interactive sprite definition\n";
}

print "interactive sprite orientation matches faithful legacy example\n";
