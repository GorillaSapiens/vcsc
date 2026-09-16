#!/usr/bin/perl
# Helpers for deterministic Stella continuous-snapshot certification.
# Compare decoded RGB pixels, never PNG container bytes/metadata.
use strict;
use warnings;
use Compress::Zlib qw(uncompress);
use Digest::SHA qw(sha256_hex);

sub read_file {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/;
   my $data=<$fh>;
   close($fh);
   return $data // '';
}
sub paeth {
   my($a,$b,$c)=@_;
   my $p=$a+$b-$c;
   my($pa,$pb,$pc)=(abs($p-$a),abs($p-$b),abs($p-$c));
   return $a if $pa<=$pb && $pa<=$pc;
   return $b if $pb<=$pc;
   return $c;
}
sub decode_rgb {
   my($path)=@_;
   my $png=read_file($path);
   substr($png,0,8) eq "\x89PNG\r\n\x1a\n" or die "$path is not PNG\n";
   my($w,$h,$depth,$ct,$interlace,$palette,$idat); ($palette,$idat)=('','');
   my $o=8;
   while ($o<length($png)) {
      my $n=unpack('N',substr($png,$o,4));
      my $type=substr($png,$o+4,4); $o+=8;
      my $data=substr($png,$o,$n); $o+=$n+4;
      if ($type eq 'IHDR') { ($w,$h,$depth,$ct,undef,undef,$interlace)=unpack('NNCCCCC',$data); }
      elsif ($type eq 'PLTE') { $palette=$data; }
      elsif ($type eq 'IDAT') { $idat.=$data; }
      elsif ($type eq 'IEND') { last; }
   }
   defined($w) && $depth==8 && $interlace==0 or die "$path uses unsupported PNG encoding\n";
   my %channels=(0=>1,2=>3,3=>1,4=>2,6=>4);
   exists($channels{$ct}) or die "$path uses unsupported PNG color type $ct\n";
   my $c=$channels{$ct}; my $rowbytes=$w*$c;
   my $raw=uncompress($idat); defined($raw) or die "$path has invalid compressed data\n";
   length($raw)==($rowbytes+1)*$h or die "$path has unexpected scanline bytes\n";
   my @prev=(0)x$rowbytes; my $pos=0; my $rgb='';
   for my $y (0..$h-1) {
      my $filter=ord(substr($raw,$pos++,1));
      my @row=unpack('C*',substr($raw,$pos,$rowbytes)); $pos+=$rowbytes;
      for my $x (0..$#row) {
         my $left=$x >= $c ? $row[$x-$c] : 0;
         my $up=$prev[$x];
         my $ul=$x >= $c ? $prev[$x-$c] : 0;
         if ($filter==1) { $row[$x]=($row[$x]+$left)&255; }
         elsif ($filter==2) { $row[$x]=($row[$x]+$up)&255; }
         elsif ($filter==3) { $row[$x]=($row[$x]+int(($left+$up)/2))&255; }
         elsif ($filter==4) { $row[$x]=($row[$x]+paeth($left,$up,$ul))&255; }
         elsif ($filter!=0) { die "$path uses unknown PNG filter $filter\n"; }
      }
      for my $x (0..$w-1) {
         my $i=$x*$c;
         if ($ct==0 || $ct==4) { $rgb.=pack('C3',($row[$i])x3); }
         elsif ($ct==3) { my $p=$row[$i]*3; $rgb.=substr($palette,$p,3); }
         else { $rgb.=pack('C3',@row[$i,$i+1,$i+2]); }
      }
      @prev=@row;
   }
   return($w,$h,$rgb);
}
sub histogram_key {
   my($w,$h,$rgb)=@_;
   my %count;
   for (my $i=0;$i<length($rgb);$i+=3) { $count{substr($rgb,$i,3)}++; }
   return join('',pack('NN',$w,$h),map { $_.pack('N',$count{$_}) } sort keys %count);
}
sub rgb_digest {
   my($w,$h,$rgb)=@_;
   return "$w x $h ".sha256_hex($rgb);
}

@ARGV>=2 or die "usage: $0 --stable-tail N [--reference REF.png] SNAP.png...\n       $0 --histogram-match REF.png SNAP.png...\n";
my $mode=shift @ARGV;
if ($mode eq '--stable-tail') {
   my $need=shift @ARGV;
   defined($need) && $need =~ /^\d+$/ && $need>0 or die "--stable-tail requires a positive count\n";
   my $reference;
   if (@ARGV>=2 && $ARGV[0] eq '--reference') { shift @ARGV; $reference=shift @ARGV; }
   @ARGV >= $need or die "only ".scalar(@ARGV)." snapshots, need stable tail of $need\n";
   my @tail=@ARGV[@ARGV-$need..$#ARGV];
   my $expected;
   for my $path (@tail) {
      my($w,$h,$rgb)=decode_rgb($path);
      my $digest=rgb_digest($w,$h,$rgb);
      $expected //= $digest;
      $digest eq $expected or die "Stella completed-frame tail is not stable: $tail[0] => $expected, $path => $digest\n";
   }
   if (defined($reference)) {
      my($rw,$rh,$rrgb)=decode_rgb($reference);
      my $wanted=rgb_digest($rw,$rh,$rrgb);
      $expected eq $wanted or die "stable Stella raster differs: actual=$expected reference=$wanted\n";
   }
   print "$expected\n";
   exit 0;
}
elsif ($mode eq '--histogram-match') {
   my $reference=shift @ARGV // die "--histogram-match requires reference PNG\n";
   @ARGV or die "--histogram-match requires candidate PNGs\n";
   my($rw,$rh,$rrgb)=decode_rgb($reference);
   my $wanted=histogram_key($rw,$rh,$rrgb);
   my $index=0;
   for my $path (@ARGV) {
      my($w,$h,$rgb)=decode_rgb($path);
      if (histogram_key($w,$h,$rgb) eq $wanted) {
         print "$index $path ".rgb_digest($w,$h,$rgb)."\n";
         exit 0;
      }
      $index++;
   }
   die "no Stella completed-frame snapshot matches the reviewed reference color population\n";
}
else { die "unknown mode $mode\n"; }
