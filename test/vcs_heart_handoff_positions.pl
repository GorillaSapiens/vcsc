#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: vcs_heart_handoff_positions ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
my($repo,$tmp)=@ARGV; $repo=abs_path($repo); make_path($tmp); $tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub slurp { open my$f,'<:raw',$_[0] or die$!; local$/; return <$f>; }
sub run { open my$f,'-|',@_ or die$!; local$/; my$s=<$f>//''; close$f or die "@_ failed\n$s"; return$s; }
sub findexe { my$n=shift; return abs_path($n) if -x$n; for(split/:/,$ENV{PATH}//''){return abs_path("$_/$n") if -x"$_/$n";} die "missing $n"; }
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(730,30);
my$p=fork(); defined$p or die$!;
if(!$p){open STDOUT,'>',"$tmp/xvfb.log" or die$!; open STDERR,'>&STDOUT'; exec $xvfb,$display,'-ac','-screen','0','1024x768x24'; die$!;}
vcsc_xvfb_assert_ready($display,$p);
local$ENV{DISPLAY}=$display; local$ENV{SDL_VIDEODRIVER}='x11'; local$ENV{SDL_AUDIODRIVER}='dummy';
my$helpers=slurp("$repo/test/stella_png_sequence.pl"); $helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG boundary'; eval$helpers; die$@ if$@;
# Independently derive the two sprite colors from the pinned input palette.
my$pal=slurp("$repo/test/fixtures/stella/stella.pal");
my@colors=map {
   my($r,$g,$b)=unpack('C3',substr($pal,($_/2)*3,3)); $b=int($b-.001*$r-.001*$g);
   pack('C3',map{int(($_/255)**1.1333*256+.5)}($r,$g,$b));
} (0x46,0xc6);
my@positions=(0..15,108,119,132,133,140,151,152,159);
my@frames=map {390+8*$_} 0..$#positions;
my@errors;
for my$below(2,0,1) {
   my$dir="$tmp/order$below"; make_path($dir,"$dir/user");
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","-DHEART_COMPOSITION_BELOW=$below",
      '-DHEART_POSITION_BASELINE='.($below==2?1:0),
      "$repo/test/fixtures/heart_score/handoff_positions.c26",'-o',"$dir/probe.bin");
   run(vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,"$dir/user"),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
      '-bs','4K','-exitlauncher','0','-confirmexit','0','-userdir',"$dir/user",
      '--capture-frames',join(',',@frames),'--capture-dir',$dir,"$dir/probe.bin");
   for my$i(0..$#frames) {
      my($w,$h,$rgb)=decode_rgb(sprintf("$dir/frame_%08d.png",$frames[$i]));
      $w==160 or die 'expected native160';
      for my$lane(0,1) {
         my%columns; my%rows;
         for my$y(0..$h-1) { for my$x(0..$w-1) {
            next unless substr($rgb,($y*$w+$x)*3,3) eq $colors[$lane];
            $columns{$x}++; $rows{$y}++;
         }}
         my$x=$positions[$i];
         # The retained 192-line renderer's hardware origin is X-1, modulo160.
         # Require exactly the same geometry in both compositions, including
         # wrap at both edges; no captured image supplies the expected mask.
         my@wanted=sort{$a<=>$b}map{($x+159+$_)%160}0..7;
         {
            join(',',sort{$a<=>$b}keys%columns) eq join(',',@wanted)
               or push@errors,"order$below P$lane requested X$x, drawn columns ".join(',',sort{$a<=>$b}keys%columns)."\n";
         }
         keys(%rows)==16 or die "order$below P$lane sprite height changed at X$x\n";
      }
   }
}
die join('',@errors) if@errors;
print "vcs_heart_handoff_positions ok\n";
