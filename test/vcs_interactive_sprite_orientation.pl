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
   my($text,$name)=@_;
   $text =~ /\b\Q$name\E\s*\[8\]\s*:=\s*\{(.*?)\};/s
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
my $p0=args(initializer($faithful,'p0g'),'legacy_SPRITE_GLYPH');
my $p1=args(initializer($faithful,'p1g'),'legacy_SPRITE_GLYPH');
my $p0c=args(initializer($faithful,'p0c'),'legacy_SPRITE_ROWS');
my $p1c=args(initializer($faithful,'p1c'),'legacy_SPRITE_ROWS');
my @p0_reverse=reverse @$p0;
my @p1_reverse=reverse @$p1;
my @p0c_reverse=reverse @$p0c;
my @p1c_reverse=reverse @$p1c;

my @definitions=(
   [qw(examples 03_player_color_192 01_interactive player_color_192_interactive.c26)],
   [qw(examples 05_all_five_192 01_interactive all_five_192_interactive.c26)],
   [qw(examples common player_color_181_interactive_common.c26)],
   [qw(examples common all_five_181_interactive_common.c26)],
);

for my $parts (@definitions) {
   my $path=File::Spec->catfile($repo,@$parts);
   my $text=read_file($path);
   same(args(initializer($text,'p0_graphics'),'game_SPRITE_GLYPH'),\@p0_reverse,"$path P0");
   same(args(initializer($text,'p1_graphics'),'game_SPRITE_GLYPH'),\@p1_reverse,"$path P1");
   next if $path =~ /all_five/;
   if ($path =~ /player_color_192_interactive/) {
      same(plain_values(initializer($text,'game_player0_colors')),$p0c,"$path P0 colors");
      same(plain_values(initializer($text,'game_player1_colors')),$p1c,"$path P1 colors");
   } else {
      same(args(initializer($text,'game_player0_colors'),'game_SPRITE_GLYPH'),\@p0c_reverse,"$path P0 colors");
      same(args(initializer($text,'game_player1_colors'),'game_SPRITE_GLYPH'),\@p1c_reverse,"$path P1 colors");
   }
}

my @leaves;
find(sub {
   return unless -f $_ && /\.c26\z/ && $File::Find::name =~ m{/01_interactive/};
   push @leaves,$File::Find::name;
},File::Spec->catdir($repo,'examples'));
@leaves==45 or die "found ".scalar(@leaves)." interactive sources, expected 45\n";
for my $path (@leaves) {
   next if $path eq $faithful_path;
   my $text=read_file($path);
   my $covered=$text =~ /\bp0_graphics\s*\[8\]/ ||
               $text =~ /include\s+"\.\.\/\.\.\/\.\.\/common\/(?:player_color|all_five)_181_interactive_common\.c26"/;
   $covered or die "$path does not use a normalized interactive sprite definition\n";
}

print "interactive sprite orientation matches faithful legacy example\n";
