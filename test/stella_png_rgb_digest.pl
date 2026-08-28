#!/usr/bin/perl
# Print a metadata-independent SHA-256 of decoded PNG RGB pixels.
use strict;
use warnings;
use Compress::Zlib qw(uncompress);
use Digest::SHA qw(sha256_hex);

sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return $d // ''; }
sub paeth { my($a,$b,$c)=@_; my $p=$a+$b-$c; my($pa,$pb,$pc)=(abs($p-$a),abs($p-$b),abs($p-$c)); return $a if $pa<=$pb && $pa<=$pc; return $b if $pb<=$pc; return $c; }
my $first_lit = 0;
my @mask_rows;
my $dark_rect;
while (@ARGV && $ARGV[0] =~ /^--/) {
   my $arg=shift @ARGV;
   if ($arg eq '--first-lit-row') { $first_lit = 1; next; }
   if ($arg eq '--assert-dark-rect') {
      @ARGV or die "--assert-dark-rect requires X0,Y0,X1,Y1\n";
      my $rect=shift @ARGV;
      $rect =~ /^(\d+),(\d+),(\d+),(\d+)$/ && $1 <= $3 && $2 <= $4
         or die "invalid --assert-dark-rect '$rect'\n";
      $dark_rect=[$1,$2,$3,$4];
      next;
   }
   if ($arg eq '--mask-rows') {
      @ARGV or die "--mask-rows requires START-END\n";
      my $range=shift @ARGV;
      $range =~ /^(\d+)-(\d+)$/ && $1 <= $2
         or die "invalid --mask-rows range '$range'\n";
      push @mask_rows,[$1,$2];
      next;
   }
   die "unknown option $arg\n";
}
@ARGV==1 or die "usage: $0 [--first-lit-row] [--assert-dark-rect X0,Y0,X1,Y1] [--mask-rows START-END] SNAPSHOT.png\n";
my $path=$ARGV[0]; my $png=read_file($path);
substr($png,0,8) eq "\x89PNG\r\n\x1a\n" or die "$path is not PNG\n";
my($w,$h,$depth,$ct,$interlace,$palette,$idat); ($palette,$idat)=('','');
my $o=8;
while($o<length($png)) {
   my $n=unpack('N',substr($png,$o,4)); my $type=substr($png,$o+4,4); $o+=8;
   my $d=substr($png,$o,$n); $o+=$n+4;
   if($type eq 'IHDR') { ($w,$h,$depth,$ct,undef,undef,$interlace)=unpack('NNCCCCC',$d); }
   elsif($type eq 'PLTE') { $palette=$d; }
   elsif($type eq 'IDAT') { $idat.=$d; }
   elsif($type eq 'IEND') { last; }
}
defined($w) && $depth==8 && $interlace==0 or die "$path uses unsupported PNG encoding\n";
my %ch=(0=>1,2=>3,3=>1,4=>2,6=>4); exists($ch{$ct}) or die "$path uses unsupported PNG color type $ct\n";
my $c=$ch{$ct}; my $rowbytes=$w*$c; my $raw=uncompress($idat); defined($raw) or die "$path has invalid compressed data\n";
length($raw)==($rowbytes+1)*$h or die "$path has unexpected scanline bytes\n";
my @prev=(0)x$rowbytes; my $pos=0; my $rgb=''; my $first_lit_row;
for my $y (0..$h-1) {
   my $filter=ord(substr($raw,$pos++,1)); my @row=unpack('C*',substr($raw,$pos,$rowbytes)); $pos+=$rowbytes;
   for my $x (0..$#row) {
      my $left=$x >= $c ? $row[$x-$c] : 0; my $up=$prev[$x]; my $ul=$x >= $c ? $prev[$x-$c] : 0;
      if($filter==1){$row[$x]=($row[$x]+$left)&255} elsif($filter==2){$row[$x]=($row[$x]+$up)&255}
      elsif($filter==3){$row[$x]=($row[$x]+int(($left+$up)/2))&255} elsif($filter==4){$row[$x]=($row[$x]+paeth($left,$up,$ul))&255}
      elsif($filter!=0){die "$path uses unknown PNG filter $filter\n"}
   }
   my $row_rgb='';
   for my $x (0..$w-1) {
      my $i=$x*$c;
      if($ct==0 || $ct==4){$row_rgb.=pack('C3',($row[$i])x3)}
      elsif($ct==3){my $p=$row[$i]*3; $row_rgb.=substr($palette,$p,3)}
      else{$row_rgb.=pack('C3',@row[$i,$i+1,$i+2])}
   }
   if ($dark_rect && $y >= $dark_rect->[1] && $y <= $dark_rect->[3]) {
      my($x0,undef,$x1)=@$dark_rect;
      $x1 < $w or die "dark rectangle exceeds PNG width\n";
      for my $x ($x0..$x1) {
         my @pixel=unpack('C3',substr($row_rgb,$x*3,3));
         if (grep { $_ > 16 } @pixel) {
            die "$path has lit pixel in required-dark rectangle at ($x,$y)\n";
         }
      }
   }
   for my $range (@mask_rows) {
      if ($y >= $range->[0] && $y <= $range->[1]) {
         $row_rgb="\0" x ($w*3);
         last;
      }
   }
   if (!defined($first_lit_row)) {
      my @px=unpack('C*',$row_rgb);
      for my $v (@px) { if ($v > 16) { $first_lit_row=$y; last; } }
   }
   $rgb.=$row_rgb;
   @prev=@row;
}
if ($first_lit) {
   defined($first_lit_row) or die "$path has no lit pixels above threshold\n";
   print "$first_lit_row\n";
} else {
   print "$w x $h ",sha256_hex($rgb),"\n";
}
