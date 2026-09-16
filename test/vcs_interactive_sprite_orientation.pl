#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: interactive sprite orientation matches faithful legacy example
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use Compress::Zlib qw(uncompress);
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

sub read_binary {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $data=<$fh>; close($fh); return $data // '';
}
sub paeth {
   my($a,$b,$c)=@_;
   my $p=$a+$b-$c;
   my($pa,$pb,$pc)=(abs($p-$a),abs($p-$b),abs($p-$c));
   return $a if $pa<=$pb && $pa<=$pc;
   return $b if $pb<=$pc;
   return $c;
}
sub png_rgb_rows {
   my($path)=@_;
   my $png=read_binary($path);
   substr($png,0,8) eq "\x89PNG\r\n\x1a\n" or die "$path is not PNG\n";
   my($w,$h,$depth,$ct,$interlace,$idat); $idat='';
   my $off=8;
   while ($off<length($png)) {
      my $n=unpack('N',substr($png,$off,4));
      my $type=substr($png,$off+4,4); $off+=8;
      my $data=substr($png,$off,$n); $off+=$n+4;
      if ($type eq 'IHDR') {
         ($w,$h,$depth,$ct,undef,undef,$interlace)=unpack('NNCCCCC',$data);
      }
      elsif ($type eq 'IDAT') { $idat.=$data; }
      elsif ($type eq 'IEND') { last; }
   }
   defined($w) && $w==320 && $h==228 && $depth==8 && $ct==2 && $interlace==0
      or die "$path is not the reviewed 320x228 RGB Stella snapshot format\n";
   my $rowbytes=$w*3;
   my $raw=uncompress($idat); defined($raw) or die "$path has invalid PNG data\n";
   length($raw)==($rowbytes+1)*$h or die "$path has unexpected PNG scanline bytes\n";
   my @prev=(0)x$rowbytes; my @rows; my $pos=0;
   for my $y (0..$h-1) {
      my $filter=ord(substr($raw,$pos++,1));
      my @row=unpack('C*',substr($raw,$pos,$rowbytes)); $pos+=$rowbytes;
      for my $x (0..$#row) {
         my $left=$x>=3 ? $row[$x-3] : 0;
         my $up=$prev[$x];
         my $ul=$x>=3 ? $prev[$x-3] : 0;
         if ($filter==1) { $row[$x]=($row[$x]+$left)&255; }
         elsif ($filter==2) { $row[$x]=($row[$x]+$up)&255; }
         elsif ($filter==3) { $row[$x]=($row[$x]+int(($left+$up)/2))&255; }
         elsif ($filter==4) { $row[$x]=($row[$x]+paeth($left,$up,$ul))&255; }
         elsif ($filter!=0) { die "$path uses unknown PNG filter $filter\n"; }
      }
      push @rows,pack('C*',@row);
      @prev=@row;
   }
   my %colors;
   for my $row (@rows) {
      for (my $x=0;$x<length($row);$x+=3) {
         ++$colors{substr($row,$x,3)};
      }
   }
   my @base=sort { $colors{$b}<=>$colors{$a} } keys %colors;
   @base>=3 or die "$path has too few colors for the reviewed Stella scene\n";
   my %non_sprite=map { $_=>1 } @base[0..2]; # background, black border, playfield
   return (\@rows,\%non_sprite);
}
sub snapshot_sprite_rows {
   my($rows,$non_sprite,$x0,$y0,$label)=@_;
   my @out;
   for my $r (0..7) {
      my @pair;
      for my $dy (0,1) {
         my $bits='0b';
         for my $b (0..7) {
            my $pixel=substr($rows->[$y0+$r*2+$dy],($x0+$b*2)*3,3);
            $bits.=(exists($non_sprite->{$pixel}) ? '.' : 'X');
         }
         push @pair,$bits;
      }
      $pair[0] eq $pair[1]
         or die "$label Stella reference changes within doubled source row $r\n";
      push @out,$pair[0];
   }
   return \@out;
}
sub decimal_assignment {
   my($text,$name)=@_;
   $text =~ /^\s*\Q$name\E\s*:=\s*(\d+)\s*;/m
      or die "missing literal initial $name\n";
   return int($1);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO\n");
my $faithful_path=File::Spec->catfile($repo,qw(examples 04_renderers faithful_legacy_player_color faithful_legacy_playercolors_interactive.c26));
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
   [qw(examples 04_renderers player_color no_score player_color_192_interactive.c26)],
   [qw(examples 05_all_five_192 01_interactive all_five_192_interactive.c26)],
   [qw(examples _common player_color_181_interactive_common.c26)],
   [qw(examples _common all_five_181_interactive_common.c26)],
   [qw(examples 16_all_five_player_color_181 all_five_player_color_181_interactive_common.c26)],
   [qw(examples 11_all_five_170 01_score_above_and_below 01_interactive all_five_170_score_above_and_below_interactive.c26)],
);

# The reviewed Stella reference is optional to regenerate, but its visible sprite
# artwork must never silently drift from the normal-suite source contract.  Decode
# the two 8x8 doubled sprite regions from the PNG and compare them directly with
# the animation frames selected by the public example's literal initial X/Y.
my $pc192_path=File::Spec->catfile($repo,qw(examples 04_renderers player_color no_score player_color_192_interactive.c26));
my $pc192=read_file($pc192_path);
my $pc192_p0=frames(initializer($pc192,'p0_animation',32),'game_SPRITE_GLYPH');
my $pc192_p1=frames(initializer($pc192,'p1_animation',32),'game_SPRITE_GLYPH');
my $p0_frame=(decimal_assignment($pc192,'game_PLAYER0_X') ^ decimal_assignment($pc192,'game_player0_y')) & 3;
my $p1_frame=(decimal_assignment($pc192,'game_PLAYER1_X') ^ decimal_assignment($pc192,'game_player1_y')) & 3;
my $stella_reference=File::Spec->catfile($repo,qw(test fixtures player_color_192 reference_interactive_stella_pinned.png));
my($snapshot_rows,$snapshot_non_sprite)=png_rgb_rows($stella_reference);
# The pinned-palette Stella 320x228 1x viewport places these initial public-example
# sprites at the following doubled-pixel rectangles.  A position/crop change is
# itself a visible reference change and must therefore fail this guard.
same(snapshot_sprite_rows($snapshot_rows,$snapshot_non_sprite,86,139,'P0'),$pc192_p0->[$p0_frame],
   'player-color-192 Stella reference P0');
same(snapshot_sprite_rows($snapshot_rows,$snapshot_non_sprite,214,85,'P1'),$pc192_p1->[$p1_frame],
   'player-color-192 Stella reference P1');

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
   return unless -f $_ && /\.c26\z/;
   my $path=$File::Find::name;
   return unless $path =~ m{/\d+_interactive/} || $path eq $faithful_path;
   push @leaves,$path;
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
               $text =~ /include\s+"\.\.\/\.\.\/\.\.\/_common\/(?:player_color|all_five)_181_interactive_common\.c26|multisprite_interactive_common\.c26"/ ||
               $text =~ /include\s+"\.\.\/\.\.\/all_five_player_color_181_interactive_common\.c26"/;
   $covered or die "$path does not use a normalized interactive sprite definition\n";
}

print "interactive sprite orientation matches faithful legacy example\n";
