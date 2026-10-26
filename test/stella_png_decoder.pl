#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: stella_png_decoder ok
# expectexit: 0

# Synthetic source samples are the oracle, not another PNG decoder/digest.
use strict;
use warnings;
use Compress::Zlib qw(compress crc32);
my($repo,$tmp)=@ARGV;
open(my$f,'<',"$repo/test/stella_png_sequence.pl")or die$!;
my$helper=do{local$/;<$f>};close$f;
$helper =~ s/\n\@ARGV>=2.*\z//s or die 'PNG helper boundary';
eval$helper;die$@if$@;
sub chunk {my($name,$data)=@_;return pack('N',length$data).$name.$data.pack('N',crc32($name.$data));}
sub save_png {
   my($path,$w,$h,$ct,$raw,$palette)=@_;
   open(my$out,'>:raw',$path)or die$!;
   print{$out}"\x89PNG\r\n\x1a\n",chunk('IHDR',pack('NNCCCCC',$w,$h,8,$ct,0,0,0)),
      length($palette)?chunk('PLTE',$palette):'',chunk('IDAT',compress($raw)),chunk('IEND','');
   close$out or die$!;
}
my($w,$h)=(7,6);my%channels=(0=>1,2=>3,3=>1,4=>2,6=>4);
my@palette=map{pack('C3',($_*37)&255,($_*91)&255,($_*13+7)&255)}0..255;
for my$ct(sort{$a<=>$b}keys%channels){
   my$c=$channels{$ct};my@rows;my$expected='';
   for my$y(0..$h-1){
      my@row=map{($y*73+$_*41+$ct*17+($_%3)*89)&255}0..$w*$c-1;
      push@rows,\@row;
      for my$x(0..$w-1){my$i=$x*$c;
         $expected.=$ct==3?$palette[$row[$i]]:($ct==0||$ct==4)?pack('C3',($row[$i])x3):pack('C3',@row[$i,$i+1,$i+2]);
      }
   }
   # Uniform filters0..4 and one mixed-filter image. Reconstruct using the
   # original source rows, with a separate predictor implementation.
   for my$variant(0..5){my$raw='';
      for my$y(0..$h-1){my$filter=$variant==5?$y%5:$variant;my@encoded;
         for my$i(0..$w*$c-1){
            my$left=$i>=$c?$rows[$y][$i-$c]:0;
            my$up=$y?$rows[$y-1][$i]:0;
            my$ul=$y&&$i>=$c?$rows[$y-1][$i-$c]:0;
            my$predict=0;
            if($filter==1){$predict=$left;}
            elsif($filter==2){$predict=$up;}
            elsif($filter==3){$predict=int(($left+$up)/2);}
            elsif($filter==4){
               my$p=$left+$up-$ul;my@candidates=($left,$up,$ul);
               my($best)=sort{abs($p-$candidates[$a])<=>abs($p-$candidates[$b])||$a<=>$b}0..2;
               $predict=$candidates[$best];
            }
            push@encoded,($rows[$y][$i]-$predict)&255;
         }
         $raw.=pack('C',$filter).pack('C*',@encoded);
      }
      my$path="$tmp/type${ct}_filter${variant}.png";
      save_png($path,$w,$h,$ct,$raw,$ct==3?join('',@palette):'');
      my($dw,$dh,$rgb)=decode_rgb($path);
      $dw==$w&&$dh==$h&&$rgb eq$expected or die "type$ct filter$variant RGB mismatch\n";
   }
}
my$bad="$tmp/bad_filter.png";save_png($bad,1,1,2,"\x05\0\0\0",'');
eval{decode_rgb($bad)};$@=~/unknown PNG filter 5/ or die 'unknown filter accepted';
print "stella_png_decoder ok\n";
