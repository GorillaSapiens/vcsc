#!/usr/bin/perl
# Private command adapter used by stella_test_lib.pl. Only VCSC options are
# intercepted; the rest of the original deterministic Stella command is retained.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Fcntl qw(:flock);
use POSIX qw(:sys_wait_h setpgid);
use Time::HiRes qw(time sleep);
my($repo,$stella,@args)=@ARGV;
defined($stella) or die "usage: $0 REPO STELLA [Stella args] --capture-frames RANGE --capture-dir DIR ROM\n";
my($frames,$directory);my@command;
while(@args) {
   my$a=shift@args;
   if($a eq'--capture-frames'){defined($frames)and die'duplicate capture selection';$frames=shift@args;}
   elsif($a eq'--capture-dir'){defined($directory)and die'duplicate capture directory';$directory=shift@args;}
   else{push@command,$a;}
}
defined($frames)&&defined($directory)or die "capture frames and directory required\n";
make_path($directory);$directory=abs_path($directory);
my$work=tempdir('rawstream-XXXXXX',DIR=>$directory,CLEANUP=>0);
my$images="$work/png";make_path($images);
open my$pending,'>',"$work/inprogress"or die$!;close$pending;
my$raw="$work/capture.raw";my$log="$work/converter.log";
my$owner=$$;my$failure='capture interrupted';
$SIG{__DIE__}=sub{$failure=join('',@_)if$$==$owner;};
my$converter="$repo/test/rawstream2png/rawstream2png";
my%children;
sub stop {
   my$p=shift;return unless delete$children{$p};
   my$r=waitpid($p,WNOHANG);return if$r==$p||$r==-1;
   kill'TERM',-$p;
   for(1..20){$r=waitpid($p,WNOHANG);return if$r==$p||$r==-1;sleep .01;}
   kill'KILL',-$p;waitpid($p,0);
}
END {
   my$status=$?;local$?;
   stop($_)for keys%children;
   if(defined($owner)&&$$==$owner&&$status) {
      if(open my$f,'>',"$work/failure.txt") {
         print$f "$failure\nRecording: $raw\nConverter log: $log\n";close$f;
      }
   }
}
$SIG{TERM}=sub{exit 143};$SIG{INT}=sub{exit 130};
sub spawn {
   my($output,@cmd)=@_;my$p=fork();defined$p or die"fork: $!";
   if(!$p){setpgid(0,0);if(defined$output){open STDOUT,'>:raw',$output or die$!;open STDERR,'>&STDOUT' or die$!;}exec@cmd;die"exec @cmd: $!";}
   eval{setpgid($p,$p)};$children{$p}=1;return$p;
}
# Serialize incremental builds across independent tests/checkouts of this tree.
open my$lock,'>>',"$repo/test/rawstream2png/.build.lock"or die$!;
flock($lock,LOCK_EX)or die$!;
my$b=spawn("$work/build.log",'make','--no-print-directory','-C',"$repo/test/rawstream2png");
waitpid($b,0);my$status=$?;delete$children{$b};
$status==0 or die"converter build failed: $work/build.log\n";
close$lock;
my$pid=spawn(undef,$stella,'-rawstream',$raw,@command);
my$extract=spawn($log,$converter,'--input',$raw,'--frames',$frames,'--output-dir',$images,
   '--prefix','frame_','--follow','--finish-selected','--timeout','60','--max-bytes','536870912');
my$deadline=time()+60;
while(1) {
   my$r=waitpid($extract,WNOHANG);
   if($r==$extract) {
      my$s=$?;delete$children{$extract};
      stop($pid);
      if($s){open my$f,'<',$log;local$/;my$text=<$f>//'';die"RawStream converter failed ($s): $text\nRecording retained: $raw\n";}
      # All requested identities were checked by the converter, and only fully
      # closed PNGs are published. Keep failed recordings; remove successful ones.
      for my$png(sort glob"$images/*.png") {
         (my$name=$png)=~s!.*/!!;
         link($png,"$directory/$name")or die"publish $name (never overwrite): $!";
         unlink$png or die$!;
      }
      rmdir$images or die$!;
      unlink$raw or die"remove $raw: $!";
      unlink"$work/build.log",$log;
      unlink"$work/inprogress"or die$!;
      rmdir$work or die"remove $work: $!";
      exit 0;
   }
   if(waitpid($pid,WNOHANG)==$pid){my$s=$?;delete$children{$pid};die"Stella exited before capture completed (status $s); recording: $raw; converter: $log\n";}
   if(time()>$deadline || (-e$raw&&-s$raw>536870912)) {
      die"RawStream capture deadline/size limit exceeded; recording: $raw; converter: $log\n";
   }
   sleep .01;
}
