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

@ARGV>=1 && @ARGV<=2 or die "usage: $0 SNAPSHOT.png [pass|fail]\n";
my $expect=lc($ARGV[1] // 'pass');
$expect eq 'pass' || $expect eq 'fail'
   or die "result must be pass or fail\n";

my($width,$height,$rgb_at)=decode_png_rgb($ARGV[0]);
my @center=$rgb_at->(int($width/2),int($height/2));
if ($expect eq 'pass') {
   $center[1] > $center[0]+30 && $center[1] > $center[2]+30
      or die "expected green PASS background: center=(@center)\n";
}
else {
   $center[0] > $center[1]+20 && $center[0] > $center[2]+20
      or die "expected red FAIL background: center=(@center)\n";
}

my @white;
for my $y (0..$height-1) {
   for my $x (0..$width-1) {
      my($red,$green,$blue)=$rgb_at->($x,$y);
      my $max=$red>$green ? ($red>$blue?$red:$blue) : ($green>$blue?$green:$blue);
      my $min=$red<$green ? ($red<$blue?$red:$blue) : ($green<$blue?$green:$blue);
      push @white,[$x,$y] if $min>150 && $max-$min<45;
   }
}
@white>=250 or die "white status word missing or too small: pixels=".scalar(@white)."\n";

my($min_x,$max_x,$min_y,$max_y)=($width,0,$height,0);
for my $point (@white) {
   my($x,$y)=@$point;
   $min_x=$x if $x<$min_x; $max_x=$x if $x>$max_x;
   $min_y=$y if $y<$min_y; $max_y=$y if $y>$max_y;
}
my $bbox_width=$max_x-$min_x+1;
my $bbox_height=$max_y-$min_y+1;
$bbox_width%54==0 or die "status word has unexpected width $bbox_width; expected 54 scaled source pixels\n";
$bbox_height%8==0 or die "status word has unexpected height $bbox_height; expected eight scaled source rows\n";
my $xscale=int($bbox_width/54);
my $yscale=int($bbox_height/8);
$xscale>=1 && $xscale<=4 or die "status word horizontal scale $xscale is unsupported\n";
$yscale>=1 && $yscale<=4 or die "status word vertical scale $yscale is unsupported\n";
my $center_x=($min_x+$max_x)/2;
my $center_y=($min_y+$max_y)/2;
abs($center_x-($width-1)/2) <= $xscale
   or die "status word is not horizontally centered: bbox=$min_x-$max_x image_width=$width\n";
abs($center_y-($height-1)/2) <= 2*$yscale
   or die "status word is not vertically centered: bbox=$min_y-$max_y image_height=$height\n";

my %glyph_rows=(
   P=>[qw(111110 110011 110011 111110 110000 110000 110000 110000)],
   A=>[qw(011110 110011 110011 110011 111111 110011 110011 110011)],
   S=>[qw(011110 110011 110000 011110 000011 000011 110011 011110)],
   F=>[qw(111111 110000 110000 111110 110000 110000 110000 110000)],
   I=>[qw(111111 001100 001100 001100 001100 001100 001100 111111)],
   L=>[qw(110000 110000 110000 110000 110000 110000 110000 111111)],
);
my @letters=split //, uc($expect);
for my $g (0..3) {
   my $want=$glyph_rows{$letters[$g]} or die "missing expected glyph $letters[$g]\n";
   for my $row (0..7) {
      for my $col (0..5) {
         my $expected=substr($want->[$row],$col,1) eq '1';
         for my $dy (0..$yscale-1) {
            for my $dx (0..$xscale-1) {
               my $x=$min_x+($g*16+$col)*$xscale+$dx;
               my $y=$min_y+$row*$yscale+$dy;
               my($red,$green,$blue)=$rgb_at->($x,$y);
               my $max=$red>$green ? ($red>$blue?$red:$blue) : ($green>$blue?$green:$blue);
               my $min=$red<$green ? ($red<$blue?$red:$blue) : ($green<$blue?$green:$blue);
               my $white=$min>150 && $max-$min<45;
               $white==$expected
                  or die "$letters[$g] glyph mismatch at row=$row col=$col pixel=$x,$y\n";
            }
         }
      }
   }
}

print "${width}x${height} center=(@center) white_pixels=".scalar(@white).
      " word=".uc($expect)." bbox=$min_x,$min_y-$max_x,$max_y scale=${xscale}x${yscale}\n";
