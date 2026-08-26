#!/usr/bin/perl
# Grade a bank-diagnostic Stella snapshot as either the PASS or FAIL frame.

use strict;
use warnings;
use Compress::Zlib qw(uncompress);

sub read_file {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/;
   my $data=<$fh>;
   close($fh) or die "close $path: $!\n";
   return defined($data) ? $data : '';
}

sub paeth {
   my($a,$b,$c)=@_;
   my $p=$a+$b-$c;
   my $pa=abs($p-$a);
   my $pb=abs($p-$b);
   my $pc=abs($p-$c);
   return $a if $pa <= $pb && $pa <= $pc;
   return $b if $pb <= $pc;
   return $c;
}

sub decode_png_rgb {
   my($path)=@_;
   my $png=read_file($path);
   substr($png,0,8) eq "\x89PNG\r\n\x1a\n"
      or die "$path is not a PNG file\n";

   my($width,$height,$depth,$color_type,$interlace);
   my($palette,$idat)=('', '');
   my $offset=8;
   while ($offset < length($png)) {
      $offset+12 <= length($png) or die "$path has a truncated PNG chunk\n";
      my $length=unpack('N',substr($png,$offset,4));
      my $type=substr($png,$offset+4,4);
      $offset += 8;
      $offset+$length+4 <= length($png)
         or die "$path has a truncated $type chunk\n";
      my $data=substr($png,$offset,$length);
      $offset += $length+4;

      if ($type eq 'IHDR') {
         $length==13 or die "$path has an invalid IHDR length\n";
         ($width,$height,$depth,$color_type,undef,undef,$interlace)=
            unpack('NNCCCCC',$data);
      }
      elsif ($type eq 'PLTE') { $palette=$data; }
      elsif ($type eq 'IDAT') { $idat.=$data; }
      elsif ($type eq 'IEND') { last; }
   }

   defined($width) && defined($height) or die "$path lacks IHDR\n";
   $depth==8 or die "$path uses unsupported PNG bit depth $depth\n";
   $interlace==0 or die "$path uses unsupported interlaced PNG data\n";
   my %channels=(0=>1,2=>3,3=>1,4=>2,6=>4);
   exists($channels{$color_type})
      or die "$path uses unsupported PNG color type $color_type\n";
   $color_type!=3 || length($palette)>=3
      or die "$path uses indexed color without a palette\n";

   my $channels=$channels{$color_type};
   my $row_bytes=$width*$channels;
   my $raw=uncompress($idat);
   defined($raw) or die "$path has invalid compressed PNG data\n";
   length($raw)==($row_bytes+1)*$height
      or die "$path has unexpected PNG scanline size\n";

   my @rows;
   my @previous=(0) x $row_bytes;
   my $pos=0;
   for my $y (0..$height-1) {
      my $filter=ord(substr($raw,$pos++,1));
      my @row=unpack('C*',substr($raw,$pos,$row_bytes));
      $pos += $row_bytes;
      for my $x (0..$#row) {
         my $left=$x >= $channels ? $row[$x-$channels] : 0;
         my $up=$previous[$x];
         my $upleft=$x >= $channels ? $previous[$x-$channels] : 0;
         if    ($filter==0) { }
         elsif ($filter==1) { $row[$x]=($row[$x]+$left)&255; }
         elsif ($filter==2) { $row[$x]=($row[$x]+$up)&255; }
         elsif ($filter==3) { $row[$x]=($row[$x]+int(($left+$up)/2))&255; }
         elsif ($filter==4) { $row[$x]=($row[$x]+paeth($left,$up,$upleft))&255; }
         else { die "$path uses unknown PNG filter $filter\n"; }
      }
      push @rows,\@row;
      @previous=@row;
   }

   my $rgb_at=sub {
      my($x,$y)=@_;
      my $row=$rows[$y];
      my $i=$x*$channels;
      return ($row->[$i],$row->[$i],$row->[$i]) if $color_type==0 || $color_type==4;
      if ($color_type==3) {
         my $p=$row->[$i]*3;
         $p+2 < length($palette) or die "$path contains an invalid palette index\n";
         return unpack('C3',substr($palette,$p,3));
      }
      return @{$row}[$i,$i+1,$i+2];
   };

   return ($width,$height,$rgb_at);
}

@ARGV>=2 && @ARGV<=3
   or die "usage: $0 SNAPSHOT.png pass|fail [F8|F6|F4|FA|4KSC|F8SC|F6SC|F4SC|E0|??????]\n";
my $expect=lc($ARGV[1]);
$expect eq 'pass' || $expect eq 'fail'
   or die "result must be pass or fail\n";
my $cart=$ARGV[2] // 'F8';
$cart =~ /^(?:F[468](?:SC)?|FA|4KSC|E0|\?{6})$/
   or die "cart type must be F8/F6/F4/FA/4KSC, F8SC/F6SC/F4SC, E0, or ??????\n";

my($width,$height,$rgb_at)=decode_png_rgb($ARGV[0]);
my @center=$rgb_at->(int($width/2),int($height/2));
if ($expect eq 'pass') {
   $center[1] > $center[0]+30 && $center[1] > $center[2]+30
      or die "expected green pass background: center=(@center)\n";
}
else {
   $center[0] > $center[1]+20 && $center[0] > $center[2]+20
      or die "expected red FAIL background: center=(@center)\n";
}

my @white;
my %white_at;
for my $y (0..$height-1) {
   for my $x (0..$width-1) {
      my($red,$green,$blue)=$rgb_at->($x,$y);
      my $max=$red>$green ? ($red>$blue?$red:$blue) : ($green>$blue?$green:$blue);
      my $min=$red<$green ? ($red<$blue?$red:$blue) : ($green<$blue?$green:$blue);
      if ($min>150 && $max-$min<45) {
         push @white,[$x,$y];
         $white_at{"$x,$y"}=1;
      }
   }
}
@white or die "white diagnostic text missing\n";

# Split the white pixels into the big result line and the smaller cart-type
# line. Both font rows are contiguous except for at most a one-row internal
# blank, while the component handoff leaves a larger vertical gap.
my %seen_y;
$seen_y{$_->[1]}=1 for @white;
my @ys=sort {$a<=>$b} keys %seen_y;
@ys>=2 or die "diagnostic has too few white rows\n";
my($split_after,$largest_gap)=($ys[0],0);
for my $i (0..$#ys-1) {
   my $gap=$ys[$i+1]-$ys[$i];
   if ($gap>$largest_gap) {
      $largest_gap=$gap;
      $split_after=$ys[$i];
   }
}
$largest_gap>=3
   or die "diagnostic result/cart lines are not vertically separated\n";
my @upper=grep { $_->[1] <= $split_after } @white;
my @lower=grep { $_->[1] >  $split_after } @white;
@upper && @lower or die "diagnostic is missing one of its two text lines\n";

my %big=(
   ' '=>[
      qw(00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000
         00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000)],
   p=>[
      qw(00000000 00000000 00000000 00000000 00000000 11111110 11111111 11100111
         11100111 11100111 11111111 11111110 11100000 11100000 11100000 00000000)],
   a=>[
      qw(00000000 00000000 00000000 00000000 00000000 00111110 01111111 00000111
         01111111 11100111 11111111 01111111 00000000 00000000 00000000 00000000)],
   s=>[
      qw(00000000 00000000 00000000 00000000 00000000 01111110 11111111 11110000
         01111110 00001111 11111111 01111110 00000000 00000000 00000000 00000000)],
   F=>[
      qw(00000000 00000000 11111111 11111111 11100000 11100000 11111100 11111100
         11100000 11100000 11100000 11100000 00000000 00000000 00000000 00000000)],
   A=>[
      qw(00000000 00000000 00011000 00111100 00111100 01111110 01100110 11100111
         11111111 11111111 11100111 11100111 00000000 00000000 00000000 00000000)],
   I=>[
      qw(00000000 00000000 01111100 01111100 00111000 00111000 00111000 00111000
         00111000 00111000 01111100 01111100 00000000 00000000 00000000 00000000)],
   L=>[
      qw(00000000 00000000 11100000 11100000 11100000 11100000 11100000 11100000
         11100000 11100000 11111111 11111111 00000000 00000000 00000000 00000000)],
);
my %small=(
   ' '=>[qw(00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000)],
   F=>[qw(01111110 01100000 01100000 01111100 01100000 01100000 01100000 01100000)],
   A=>[qw(00111100 01100110 01100110 01100110 01111110 01100110 01100110 01100110)],
   4=>[qw(00001100 00011100 00101100 01001100 01001100 01111110 00001100 00001100)],
   K=>[qw(01100110 01101100 01111000 01110000 01111000 01101100 01100110 01100110)],
   6=>[qw(00111100 01100010 01100000 01111100 01100110 01100110 01100110 00111100)],
   8=>[qw(00111100 01100110 01100110 00111100 01100110 01100110 01100110 00111100)],
   S=>[qw(00111100 01100110 01100000 00111100 00000110 00000110 01100110 00111100)],
   C=>[qw(00111100 01100110 01100000 01100000 01100000 01100000 01100110 00111100)],
   E=>[qw(01111110 01100000 01100000 01111100 01100000 01100000 01100000 01111110)],
   0=>[qw(00111100 01100110 01100110 01100110 01100110 01100110 01100110 00111100)],
   '?'=>[qw(00111100 01100110 00000110 00001100 00011000 00000000 00011000 00011000)],
);

sub expected_bitmap {
   my($text,$font,$pitch)=@_;
   my $rows=@{$font->{substr($text,0,1)}};
   my %set;
   for my $g (0..length($text)-1) {
      my $ch=substr($text,$g,1);
      my $glyph=$font->{$ch} or die "missing expected glyph '$ch'\n";
      @$glyph==$rows or die "inconsistent expected font height\n";
      for my $row (0..$rows-1) {
         for my $col (0..7) {
            $set{($g*$pitch+$col).",$row"}=1
               if substr($glyph->[$row],$col,1) eq '1';
         }
      }
   }
   return \%set;
}

sub crop_expected {
   my($set)=@_;
   my(@pts)=map { [split /,/] } keys %$set;
   @pts or die "expected text has no pixels\n";
   my($minx,$maxx,$miny,$maxy)=(1e9,-1,1e9,-1);
   for my $pt (@pts) {
      my($x,$y)=@$pt;
      $minx=$x if $x<$minx; $maxx=$x if $x>$maxx;
      $miny=$y if $y<$miny; $maxy=$y if $y>$maxy;
   }
   my %crop;
   for my $pt (@pts) {
      $crop{($pt->[0]-$minx).",".($pt->[1]-$miny)}=1;
   }
   return (\%crop,$maxx-$minx+1,$maxy-$miny+1);
}

sub grade_line {
   my($name,$points,$expected)=@_;
   my($cropped,$ew,$eh)=crop_expected($expected);
   my($minx,$maxx,$miny,$maxy)=($width,0,$height,0);
   for my $pt (@$points) {
      my($x,$y)=@$pt;
      $minx=$x if $x<$minx; $maxx=$x if $x>$maxx;
      $miny=$y if $y<$miny; $maxy=$y if $y>$maxy;
   }
   my $ow=$maxx-$minx+1;
   my $oh=$maxy-$miny+1;
   $ow%$ew==0 && $oh%$eh==0
      or die "$name has unexpected bounding box ${ow}x${oh}; expected a scaled ${ew}x${eh}\n";
   my $xs=int($ow/$ew);
   my $ys=int($oh/$eh);
   $xs>=1 && $xs<=4 && $ys>=1 && $ys<=4
      or die "$name has unsupported scale ${xs}x${ys}\n";
   my $expected_count=scalar(keys %$cropped)*$xs*$ys;
   @$points==$expected_count
      or die "$name has unexpected white pixels: got=".scalar(@$points).
             " expected=$expected_count\n";

   for my $y (0..$eh-1) {
      for my $x (0..$ew-1) {
         my $want=$cropped->{"$x,$y"} ? 1 : 0;
         for my $dy (0..$ys-1) {
            for my $dx (0..$xs-1) {
               my $actual=$white_at{($minx+$x*$xs+$dx).",".($miny+$y*$ys+$dy)} ? 1 : 0;
               $actual==$want
                  or die "$name glyph mismatch at source pixel $x,$y\n";
            }
         }
      }
   }
   my $cx=($minx+$maxx)/2;
   abs($cx-($width-1)/2) <= 2*$xs
      or die "$name is not horizontally centered: bbox=$minx-$maxx image_width=$width\n";
   return ($minx,$miny,$maxx,$maxy,$xs,$ys);
}

my $result_text=$expect eq 'pass' ? ' pass ' : ' FAIL ';
my $cart_text;
if ($cart eq '??????') {
   $cart_text='??????';
}
elsif ($cart =~ /SC$/) {
   $cart_text=' '.$cart.' ';
}
else {
   $cart_text='  '.$cart.'  ';
}
length($result_text)==6 && length($cart_text)==6
   or die "internal diagnostic text width error\n";

my $big_expected=expected_bitmap($result_text,\%big,16);
my $small_expected=expected_bitmap($cart_text,\%small,8);
my @ub=grade_line("big result '$result_text'",\@upper,$big_expected);
my @lb=grade_line("cart type '$cart_text'",\@lower,$small_expected);
$ub[1] < $lb[1] or die "cart type is not below result word\n";

print "${width}x${height} center=(@center) result=$result_text cart=$cart_text ".
      "big_bbox=$ub[0],$ub[1]-$ub[2],$ub[3] scale=$ub[4]x$ub[5] ".
      "cart_bbox=$lb[0],$lb[1]-$lb[2],$lb[3] scale=$lb[4]x$lb[5]\n";
