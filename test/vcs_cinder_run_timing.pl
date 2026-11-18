#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_cinder_run_timing ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);
use File::Path qw(make_path);
use POSIX qw(setpgid WNOHANG);
use Time::HiRes qw(time sleep);
my($repo,$tmp)=@ARGV;
$repo=abs_path($repo);make_path($tmp);$tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub slurp {open my$f,'<:raw',$_[0] or die$!;local$/;return <$f>;}
sub run {open my$f,'-|',@_ or die$!;local$/;my$out=<$f>//'';close$f or die "@_ failed\n$out";}
sub findexe {my$n=shift;return abs_path($n) if -x$n;for(split/:/,$ENV{PATH}//'') {return abs_path("$_/$n") if -x"$_/$n";}die "missing $n\n";}
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Map',"$tmp/game.map",
   "$repo/examples/06_games/cinder_run/cinder_run.c26",'-o',"$tmp/game.bin");
my$md5=md5_hex(slurp("$tmp/game.bin"));my$map=slurp("$tmp/game.map");
my%address;
for my$name(qw(run_feet run_grounded)) {
   $map=~/^\s*\$([0-9a-f]+)\s+\Q$name\E\s/im or die "missing $name\n";
   $address{$name}=hex($1);$address{$name}>=0x80&&$address{$name}<0x100 or die "$name not RIOT RAM\n";
}
# Reuse the maintained dependency-free X11/XTEST helpers, not their snapshot
# main program. Inputs go to the unmodified game ROM; no scripted CPU workload
# is inserted into the game's already deadline-sensitive blanking phases.
my$keys=slurp("$repo/test/stella_snapshot_keys.pl");
my($xhelpers)=$keys=~/\A(.*?)\nmy \$reset=0;/s or die 'X11 helper boundary';
my($xtest)=$keys=~/(sub x_test_opcode \{.*?)(?=\nsub toggle_every_frame_snapshots)/s or die 'XTEST helper boundary';
eval$xhelpers.$xtest;die$@ if$@;
my%children;
sub spawn {
   my($log,@command)=@_;my$p=fork();defined$p or die$!;
   if(!$p) {setpgid(0,0);open STDOUT,'>',"$tmp/$log" or die$!;open STDERR,'>&STDOUT';exec@command;die$!;}
   eval{setpgid($p,$p)};$children{$p}=1;return$p;
}
sub stop {
   my$p=shift;return unless delete$children{$p};
   return if waitpid($p,WNOHANG)==$p;
   kill 'TERM',-$p;
   for(1..40) {my$r=waitpid($p,WNOHANG);return if$r==$p||$r==-1;sleep .01;}
   kill 'KILL',-$p;waitpid($p,0);
}
END {local$?;stop($_) for keys%children;}
my(undef,$display)=vcsc_reserve_x_display(810,40);
my$xp=spawn('xvfb.log',$xvfb,$display,'-ac','-screen','0','1024x768x24');
vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{SDL_VIDEODRIVER}='x11';local$ENV{SDL_AUDIODRIVER}='dummy';
my$sp=spawn('stella.log',$stella,vcsc_stella_palette_args($repo,"$tmp/user"),
   '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
   '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
   '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','0','-audio.enabled','0',
   '-bs','F6SC','-exitlauncher','0','-confirmexit','0','-userdir',"$tmp/user",'-rawstream',"$tmp/game.raw","$tmp/game.bin");
my($x,$root)=x_connect();my$window;my$deadline=time()+45;
while(!defined($window)) {
   $window=largest_mapped_descendant($x,$root);
   time()<$deadline or die "Stella window timeout\n";sleep .01 unless defined$window;
}
send_request($x,42,2,pack('VV',$window,0),0);
my$opcode=x_test_opcode($x);my%down;
sub input {
   my@want=@_;my%want=map{$_=>1}@want;
   for my$k(keys%down) {x_test_key($x,$opcode,3,$k,$root) unless$want{$k};}
   for my$k(@want) {x_test_key($x,$opcode,2,$k,$root) unless$down{$k};}
   %down=%want;
}
while(!-e"$tmp/game.raw") {time()<$deadline or die 'RawStream startup timeout';sleep .01;}
open my$raw,'<:raw',"$tmp/game.raw" or die$!;
open my$trace,'>',"$tmp/frames.tsv" or die$!;
print{$trace}"frame\tcycles\tscanlines\tfeet\tgrounded\n";
my($buffer,$ram)=('','');my($bytes,$frames,$jumps,$last_frame,$last_cycles,$last_grounded)=(0,0,0,undef,undef,1);
my($header,@bad);my%lines;
while($frames<650) {
   time()<$deadline or die "RawStream/input deadline ($frames frames, $jumps jumps)\n";
   my$n=sysread($raw,my$more,262144);defined$n or die$!;
   $bytes+=$n;$bytes<=67108864 or die 'RawStream byte limit';$buffer.=$more;
   while(length($buffer)>=8) {
      my($tag,$size)=unpack('a4V',substr($buffer,0,8));$size<=1048576 or die 'RawStream chunk bound';
      last if length($buffer)<8+$size;
      substr($buffer,0,8,'');my$body=substr($buffer,0,$size,'');
      if($tag eq 'HEAD') {
         unpack('v',$body)==1 or die 'RawStream version';my$at=110;
         my$length=unpack('v',substr($body,$at,2));$at+=2+$length;
         $length=unpack('v',substr($body,$at,2));$at+=2;
         lc(substr($body,$at,$length)) eq $md5 or die 'recorded ROM identity mismatch';$header=1;
      }
      elsif($tag eq 'RAM ') {length($body)==128 or die 'RIOT snapshot geometry';$ram=$body;}
      elsif($tag eq 'FRAM') {
         $header&&length($ram)==128 or die 'frame before identity/RAM';
         my($cycles,$frame,$line)=unpack('Q<Vv',$body);
         !defined($last_frame)||$frame==$last_frame+1 or die 'nonconsecutive recorded frame identity';
         my$feet=ord(substr($ram,$address{run_feet}-0x80,1));
         my$grounded=ord(substr($ram,$address{run_grounded}-0x80,1));
         $jumps++ if !$grounded&&$last_grounded;
         print{$trace}"$frame\t$cycles\t$line\t$feet\t$grounded\n";
         if($frame>=12) {
            $lines{$line}++;push@bad,"frame $frame: $line lines, feet=$feet grounded=$grounded" if$line!=262;
            if(defined$last_cycles&&$cycles-$last_cycles!=$line*76) {die "RawStream cycle/scanline disagreement at $frame\n";}
         }
         ($last_frame,$last_cycles,$last_grounded)=($frame,$cycles,$grounded);$frames++;
         # Stock private-Xvfb codes: Space=65, Up=111, Left=113, Right=114.
         # Use completed recorded frames to schedule input, never wall-clock
         # frame guesses. Fire and Up do not overlap; repeated Fire can restart
         # after game over as well as exercise combat during ordinary play.
         if($frame>=12&&$frame<20) {input(65);}
         elsif($frame>=32) {
            my$phase=($frame-32)%52;my$round=int(($frame-32)/52);my@keys;
            push@keys,111 if$phase<8;
            push@keys,($round%3==1?113:114) if$round%3&&$phase<40;
            push@keys,65 if$phase>=44&&$phase<48;
            input(@keys);
         }
         else {input();}
      }
   }
   sleep .005 unless$n;
}
input();stop($sp);stop($xp);close$trace;close$raw;
$jumps>=8 or die "input route did not exercise repeated jumps ($jumps)\n";
@bad and die "unstable Stella frame period: ".join('; ',@bad[0..($#bad<19?$#bad:19)])."\nTrace: $tmp/frames.tsv\n";
unlink "$tmp/game.raw" unless$ENV{VCSC_KEEP_RAWSTREAM};
print "vcs_cinder_run_timing ok\n";
