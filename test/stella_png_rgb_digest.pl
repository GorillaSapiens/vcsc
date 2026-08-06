#!/usr/bin/perl
# Print a metadata-independent SHA-256 of decoded PNG RGB pixels.
use strict;
use warnings;
use Compress::Zlib qw(uncompress);
use Digest::SHA qw(sha256_hex);

sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return $d // ''; }
sub paeth { my($a,$b,$c)=@_; my $p=$a+$b-$c; my($pa,$pb,$pc)=(abs($p-$a),abs($p-$b),abs($p-$c)); return $a if $pa<=$pb && $pa<=$pc; return $b if $pb<=$pc; return $c; }
@ARGV==1 or die "usage: $0 SNAPSHOT.png\n";
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
my @prev=(0)x$rowbytes; my $pos=0; my $rgb='';
for my $y (0..$h-1) {
   my $filter=ord(substr($raw,$pos++,1)); my @row=unpack('C*',substr($raw,$pos,$rowbytes)); $pos+=$rowbytes;
   for my $x (0..$#row) {
      my $left=$x >= $c ? $row[$x-$c] : 0; my $up=$prev[$x]; my $ul=$x >= $c ? $prev[$x-$c] : 0;
      if($filter==1){$row[$x]=($row[$x]+$left)&255} elsif($filter==2){$row[$x]=($row[$x]+$up)&255}
      elsif($filter==3){$row[$x]=($row[$x]+int(($left+$up)/2))&255} elsif($filter==4){$row[$x]=($row[$x]+paeth($left,$up,$ul))&255}
      elsif($filter!=0){die "$path uses unknown PNG filter $filter\n"}
   }
   for my $x (0..$w-1) {
      my $i=$x*$c;
      if($ct==0 || $ct==4){$rgb.=pack('C3',($row[$i])x3)}
      elsif($ct==3){my $p=$row[$i]*3; $rgb.=substr($palette,$p,3)}
      else{$rgb.=pack('C3',@row[$i,$i+1,$i+2])}
   }
   @prev=@row;
}
print "$w x $h ",sha256_hex($rgb),"\n";
