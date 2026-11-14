#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: rawstream2png_contract ok
# expectexit: 0
use strict;
use warnings;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;make_path($tmp);
sub read_file{open my$f,'<:raw',$_[0]or die$!;local$/;return<$f>;}
sub save{open my$f,'>:raw',$_[0]or die$!;print$f $_[1];close$f or die$!;}
sub run{my$err=gensym;my$p=open3(my$i,my$o,$err,@_);close$i;local$/;my$s=<$o>//'';my$e=<$err>//'';waitpid($p,0);return($?,$s.$e);}
my($built,$buildlog)=run('make','--no-print-directory','-C',"$repo/test/rawstream2png");$built==0 or die$buildlog;
my$tool="$repo/test/rawstream2png/rawstream2png";
sub chunk{my($tag,$bytes)=@_;return$tag.pack('V',length$bytes).$bytes;}
sub head{my$tv=shift//0;return chunk('HEAD',pack('vCCVVvv',1,$tv,0,$tv?31200:31440,$tv?1185600:1194720,160,0).pack('v*',(0)x47).pack('v',4).'test'.pack('v',3).'abc'.'extension');}
my@palette=map{pack('C3',$_,255-$_,($_*7)&255)}0..255;
my$pal=chunk('PALT',join('',@palette));
sub frame{my($n,$h,$index)=@_;return chunk('FRAM',pack('Q<Vvvvv',0x100000000+$n*19912,$n,262,23,160,$h).(pack('C',$index)x(160*$h)).'extension');}
my$prefix=head().$pal.chunk('AUDI',"\x23"x524).chunk('RAM ',"\x42"x128);
my$raw=$prefix.frame(12,3,46).chunk('FUTR','unknown extension').frame(14,4,84).head(1).chunk('PALT',join('',reverse@palette)).frame(15,5,46).chunk('END ','');
save("$tmp/sample.raw",$raw);
my$helpers=read_file("$repo/test/stella_png_sequence.pl");$helpers=~s/\n\@ARGV>=2.*\z//s or die'PNG helper boundary';eval$helpers;die$@if$@;
for my$run(1,2){my($s,$out)=run($tool,'--input',"$tmp/sample.raw",'--frames','12,14-15,14','--output-dir',"$tmp/run$run",'--prefix','test_','--list');$s==0 or die$out;
   $out=~/frame=12\tcycles=4295206240\tscanlines=262\tfirst=23\twidth=160\theight=3\ttv=0\taudio_samples=524\tram=4242/ or die"metadata mismatch $out";
   for my$entry([12,3,$palette[46]],[14,4,$palette[84]],[15,5,$palette[209]]){
      my($n,$h,$pixel)=@$entry;my$path=sprintf("$tmp/run$run/test_%08d.png",$n);
      my($w,$height,$rgb)=decode_rgb($path);$w==160&&$height==$h&&$rgb eq$pixel x(160*$h)or die"native/palette/frame mismatch $n";
      read_file($path)eq read_file(sprintf("$tmp/run1/test_%08d.png",$n))or die'nondeterministic PNG';
   }
}
my($s,$out)=run($tool,'--input',"$tmp/sample.raw",'--all','--output-dir',"$tmp/all");$s==0 or die$out;
my@all=glob"$tmp/all/*.png";@all==3 or die'--all frame count';
save("$tmp/boundaries.raw",$prefix.frame(0,1,46).frame(4294967295,1,84).chunk('END ',''));
($s,$out)=run($tool,'--input',"$tmp/boundaries.raw",'--frames','0,4294967295','--output-dir',"$tmp/boundaries");
$s==0&&-s"$tmp/boundaries/frame_00000000.png"&&-s"$tmp/boundaries/frame_4294967295.png"or die"uint32 boundary identities: $out";
save("$tmp/pixels.raw",head().$pal.chunk('FRAM',pack('Q<Vvvvv',19912,7,312,19,160,2).pack('C*',map{$_&255}0..319)).chunk('END ',''));
($s,$out)=run($tool,'--input',"$tmp/pixels.raw",'--frames','7','--output-dir',"$tmp/pixels");$s==0 or die$out;
my($pw,$ph,$pixels)=decode_rgb("$tmp/pixels/frame_00000007.png");
$pw==160&&$ph==2&&$pixels eq join('',map{$palette[$_&255]}0..319)or die'all256 palette entries/row order';
my($collision,$collision_log)=run($tool,'--input',"$tmp/sample.raw",'--frames','12','--output-dir',"$tmp/all");
$collision&&$collision_log=~/never overwrite/ or die'collision accepted';
my@bad=(['missing',$raw,'13',qr/missing requested frame: 13/],
   ['truncated',substr($raw,0,-9),'12',qr/truncated/],
   ['short_frame',head().$pal.chunk('FRAM',"\0"x19).chunk('END ',''),'12',qr/short chunk/],
   ['no_palette',head().frame(12,3,46).chunk('END ',''),'12',qr/HEAD\/PALT/],
   ['version',chunk('HEAD',pack('v',2).("\0"x112)).chunk('END ',''),'12',qr/unsupported.*version/],
   ['duplicate',$prefix.frame(12,3,46).chunk('JUMP',"\1").frame(12,3,84).chunk('END ',''),'12',qr/duplicate selected/],
   ['oversize','FRAM'.pack('V',0xffffffff),'12',qr/oversized/],
   ['trailing',$raw.'x','12',qr/after END/]);
for my$b(@bad){my($name,$data,$select,$error)=@$b;save("$tmp/$name.raw",$data);my($s,$out)=run($tool,'--input',"$tmp/$name.raw",'--frames',$select,'--output-dir',"$tmp/$name");$s&&$out=~$error or die"$name incorrectly accepted/diagnosed: $out";}
for my$select('','1,','-1','2-1','1--2','1-2-3','4294967296','a','1, 2'){
   my($s,$out)=run($tool,'--input',"$tmp/sample.raw",'--frames',$select,'--output-dir',"$tmp/invalid");$s&&$out=~/invalid|descending|exceeds/ or die"invalid range accepted: $select $out";
}
($s,$out)=run($tool,'--input',"$tmp/sample.raw",'--frames','12','--output-dir',"$tmp/limited",'--max-bytes','8');
$s&&$out=~/byte limit/ or die'byte limit not enforced';
# A live file is deliberately delivered in pieces, including inside FRAM.
my$writer=fork();defined$writer or die$!;
if(!$writer){open my$f,'>:raw',"$tmp/live.raw"or die$!;select((select($f),$|=1)[0]);for my$part(unpack('(a137)*',$prefix.frame(12,3,46))){print$f $part;select undef,undef,undef,.001;}close$f;exit 0;}
($s,$out)=run($tool,'--input',"$tmp/live.raw",'--frames','12','--output-dir',"$tmp/live",'--follow','--finish-selected','--timeout','3');waitpid($writer,0);$s==0 or die"live failed: $out";
($s,$out)=run($tool,'--input',"$tmp/live.raw",'--frames','13','--output-dir',"$tmp/timeout",'--follow','--finish-selected','--timeout','1');$s&&$out=~/timeout/ or die'live deadline missing';
print "rawstream2png_contract ok\n";
