#!/usr/bin/perl
# Reject a bank diagnostic Stella snapshot unless it shows the green PASS frame.

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
      $offset += $length+4; # Data plus CRC.

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

@ARGV==1 or die "usage: $0 SNAPSHOT.png\n";
my($width,$height,$rgb_at)=decode_png_rgb($ARGV[0]);
my @center=$rgb_at->(int($width/2),int($height/2));
$center[1] > $center[0]+30 && $center[1] > $center[2]+30
   or die "FAIL-colored final frame: center=(@center)\n";
my @bright;
for my $y (0..$height-1) {
   for my $x (0..$width-1) {
      my($red,$green,$blue)=$rgb_at->($x,$y);
      push @bright,[$x,$y] if $green>150 && $green>$red+30 && $green>$blue+30;
   }
}
@bright>=100 or die "PASS glyph missing or too small: bright-green pixels=".scalar(@bright)."\n";

# The diagnostic deliberately uses the default-font P at double player width.
# At Stella's 1x snapshot scale each source pixel is four PNG pixels wide.
# Verify the actual silhouette, rather than accepting any sufficiently large
# bright-green splatter (which is how the old torn/zero-page-loaded glyph got
# through this test).
my($min_x,$max_x,$min_y,$max_y)=($width,0,$height,0);
for my $point (@bright) {
   my($x,$y)=@$point;
   $min_x=$x if $x<$min_x; $max_x=$x if $x>$max_x;
   $min_y=$y if $y<$min_y; $max_y=$y if $y>$max_y;
}
$max_x-$min_x+1==24
   or die "PASS glyph has wrong width: ".($max_x-$min_x+1)." pixels\n";
$max_y-$min_y+1>=14 && $max_y-$min_y+1<=16
   or die "PASS glyph has wrong height: ".($max_y-$min_y+1)." pixels\n";

my @rows;
for my $y ($min_y..$max_y) {
   my $bits='';
   for my $column (0..5) {
      my $count=0;
      for my $dx (0..3) {
         my($red,$green,$blue)=$rgb_at->($min_x+$column*4+$dx,$y);
         $count++ if $green>150 && $green>$red+30 && $green>$blue+30;
      }
      $count==0 || $count==4
         or die "PASS glyph has a torn source pixel at y=$y column=$column\n";
      $bits .= $count ? '1' : '0';
   }
   push @rows,$bits;
}
my(@shape,@runs);
for my $row (@rows) {
   if (!@shape || $shape[-1] ne $row) { push @shape,$row; push @runs,1; }
   else { $runs[-1]++; }
}
join(',',@shape) eq '111110,110011,111110,110000'
   or die "PASS glyph is not the default-font P: rows=".join(',',@shape)."\n";
$runs[0]>=1 && $runs[0]<=3 && $runs[1]>=3 && $runs[1]<=5 &&
$runs[2]>=1 && $runs[2]<=3 && $runs[3]>=6 && $runs[3]<=9
   or die "PASS glyph has unexpected row scaling: runs=".join(',',@runs)."\n";

print "${width}x${height} center=(@center) pass_pixels=".scalar(@bright).
      " glyph=P bbox=$min_x,$min_y-$max_x,$max_y\n";
