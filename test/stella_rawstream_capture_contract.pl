#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: stella_rawstream_capture_contract ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub save{open my$f,'>:raw',$_[0]or die$!;print$f $_[1];close$f;}
sub slurp{open my$f,'<:raw',$_[0]or die$!;local$/;return<$f>;}
sub run{my$e=gensym;my$p=open3(my$i,my$o,$e,@_);close$i;local$/;my$s=<$o>//'';my$t=<$e>//'';waitpid($p,0);return($?,$s.$t);}
sub chunk{my($tag,$data)=@_;return$tag.pack('V',length$data).$data;}
my$header=chunk('HEAD',pack('vCCVVvv',1,0,0,31440,1194720,160,0).pack('v*',(0)x47).pack('vv',0,0));
my$palette=chunk('PALT',pack('C3',10,20,30)x256);
my$frame=chunk('FRAM',pack('Q<Vvvvv',19912,200,262,20,160,2).("\0"x320));
save("$tmp/good.raw",$header.$palette.$frame); # deliberately no END: bounded live capture
save("$tmp/bad.raw",chunk('HEAD',pack('v',99)));
save("$tmp/emulator",'#!'.$^X."\n".<<'PERL');
use strict;
use warnings;
my$raw;
while(@ARGV){my$a=shift@ARGV;if($a eq'-rawstream'){$raw=shift@ARGV;}}
defined$raw or die 'helper did not pass -rawstream';
open my$p,'>',$ENV{FAKE_PID}or die$!;print$p $$;close$p;
exit 17 if$ENV{FAKE_EXIT};
open my$i,'<:raw',$ENV{FAKE_INPUT}or die$!;local$/;my$data=<$i>;close$i;
open my$o,'>:raw',$raw or die$!;print$o $data;close$o;
sleep 60;
PERL
chmod 0755,"$tmp/emulator"or die$!;
for my$kind(qw(good bad exited collision)) {
   my$d="$tmp/$kind";make_path($d);
   local$ENV{FAKE_INPUT}="$tmp/".($kind eq'bad'?'bad':'good').'.raw';
   local$ENV{FAKE_PID}="$tmp/pid_$kind";local$ENV{FAKE_EXIT}=$kind eq'exited';
   save("$d/frame_00000200.png",'do not overwrite')if$kind eq'collision';
   my($s,$out)=run(vcsc_stella_capture_launcher($repo,"$tmp/emulator"),
      '--capture-frames','200','--capture-dir',$d);
   my$pid=slurp("$tmp/pid_$kind");!kill(0,$pid)or die"emulator leaked for $kind";
   if($kind eq'good') {
      $s==0&&-s"$d/frame_00000200.png"or die"good capture failed: $out";
      !glob("$d/rawstream-*/*.raw")or die'success recording leaked';
   }else {
      $s or die"$kind incorrectly succeeded";
      $out=~($kind eq'exited'?qr/Stella exited/:$kind eq'collision'?qr/never overwrite/:qr/converter failed.*unsupported/s)or die"wrong $kind diagnostic: $out";
      my@failure=glob"$d/rawstream-*/failure.txt";@failure==1 or die'failure marker missing';
      if($kind ne'exited'){my@raw=glob"$d/rawstream-*/*.raw";@raw==1&&-s$raw[0]or die'failed recording lost';}
      eval{my@png=vcsc_stella_wait_snapshots("$d/*.png",1,1);1}and die'waiter ignored capture failure';
      $@=~/RawStream capture failed/ or die'waiter hid diagnostic';
      slurp("$d/frame_00000200.png")eq'do not overwrite' or die'collision overwrote file'if$kind eq'collision';
   }
}
print "stella_rawstream_capture_contract ok\n";
