#!/usr/bin/perl
# Shared runner for the independently budgeted native matrix shards.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
my($repo,$tmp,$family)=@ARGV;
defined($family)&&$family=~/^[0-5]$/ or die "usage: $0 REPO TMP FAMILY(0..5)\n";
$repo=abs_path($repo); make_path($tmp); $tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
sub slurp { open my$f,'<:raw',$_[0] or die$!; local$/; return <$f>; }
sub run { open my$f,'-|',@_ or die$!; local$/; my$s=<$f>//''; close$f or die "@_ failed\n$s"; return$s; }
sub findexe { my$n=shift; return abs_path($n) if -x$n; for(split/:/,$ENV{PATH}//''){return abs_path("$_/$n") if -x"$_/$n";} die "missing $n"; }
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(800,100);
my$p=fork(); defined$p or die$!;
if(!$p){open STDOUT,'>',"$tmp/xvfb.log" or die$!; open STDERR,'>&STDOUT'; exec $xvfb,$display,'-ac','-screen','0','1024x768x24'; die$!;}
vcsc_xvfb_assert_ready($display,$p);
local$ENV{DISPLAY}=$display; local$ENV{SDL_VIDEODRIVER}='x11'; local$ENV{SDL_AUDIODRIVER}='dummy';
my$helpers=slurp("$repo/test/stella_png_sequence.pl"); $helpers=~s/\n\@ARGV>=2.*\z//s or die 'PNG boundary'; eval$helpers; die$@ if$@;
my$pal=slurp("$repo/test/fixtures/stella/stella.pal");
my@colors=map {
   my($r,$g,$b)=unpack('C3',substr($pal,($_/2)*3,3)); $b=int($b-.001*$r-.001*$g);
   pack('C3',map{int(($_/255)**1.1333*256+.5)}($r,$g,$b));
} (0x46,0xc6);
my@positions=(0..15,108,119,132,133,140,151,152,159);
my@frames=map {390+8*$_} 0..$#positions;
my@layouts=qw(centered left right wide two_plus_two three_plus_three);

sub capture_case {
   my($tag,$score,$below,$late,$baseline)=@_;
   my$dir="$tmp/$tag"; make_path($dir,"$dir/user");
   # The unofficial player-color component is181-only. Its independent192-line
   # baseline is the retained official player-color renderer.
   my$f=$baseline&&$family==2?0:$family;
   my$source="$repo/test/fixtures/score_handoff_positions.c26";
   if($late) {
      my$body=slurp($source);
      my$delay="   asm lda #0;\n   asm sta COLUPF;\n   asm lda #0;\n   asm sta COLUPF;\n";
      $body=~s/(   score_draw\(\);\n)(   vcs_ntsc_component_handoff\(\);\n   game_draw\(\);)/$1 . $delay . $2/e
         or die 'missing late-entry mutation site';
      $source="$dir/late.c26";
      open my$out,'>:raw',$source or die$!; print {$out} $body; close$out or die$!;
   }
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Wa,--illegals',
      "-DPOSITION_FAMILY=$f",'-DPOSITION_LINES='.($baseline?192:181),
      "-DPOSITION_SCORE=$score","-DPOSITION_BELOW=$below",
      $source,'-o',"$dir/probe.bin");
   -s"$dir/probe.bin"==4096 or die "$tag must remain a4K ROM\n";
   # All cases keep unique user/output paths and the adapter's unchanged60s /
   # 512MiB bounds, strict FRAM selection and process-group cleanup.
   run(vcsc_stella_capture_launcher($repo,$stella),vcsc_stella_palette_args($repo,"$dir/user"),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0',
      '-bs','4K','-exitlauncher','0','-confirmexit','0','-userdir',"$dir/user",
      '--capture-frames',join(',',@frames),'--capture-dir',$dir,"$dir/probe.bin");
   my@errors;
   for my$i(0..$#frames) {
      my($w,$h,$rgb)=decode_rgb(sprintf("$dir/frame_%08d.png",$frames[$i]));
      $w==160 or die 'expected native160';
      my@columns=({},{}); my@rows=({},{});
      # Score ink is a third color, so neither score placement nor sprite
      # overlaps can create a false player-coordinate match.
      for my$y(0..$h-1) { for my$x(0..$w-1) {
         my$c=substr($rgb,($y*$w+$x)*3,3);
         for my$lane(0,1) {
            next unless $c eq $colors[$lane];
            $columns[$lane]{$x}++; $rows[$lane]{$y}++;
         }
      }}
      for my$lane(0,1) {
         my$x=$positions[$i];
         my@wanted=sort{$a<=>$b}map{($x+159+$_)%160}0..7;
         my@actual=sort{$a<=>$b}keys%{$columns[$lane]};
         join(',',@actual) eq join(',',@wanted)
            or push@errors,"$tag frame$frames[$i] P$lane X$x columns=".join(',',@actual)." wanted=".join(',',@wanted)."\n";
         keys(%{$rows[$lane]})==16
            or push@errors,"$tag frame$frames[$i] P$lane X$x height=".scalar(keys%{$rows[$lane]})." wanted16\n";
         # Demand a solid rectangle, not merely the right bounding box.
         for my$column(@actual) {
            $columns[$lane]{$column}==16 or push@errors,"$tag P$lane incomplete column$column\n";
         }
      }
   }
   return @errors;
}
my@errors=capture_case('baseline',0,0,0,1);
for my$score(0..$#layouts) {
   # The all-five per-row-color renderer plus three-plus-three exceeds stock
   # 128-byte RAM; do not claim a native-supported composition for that pair.
   next if $family==4 && $score==5;
   # The extra sections shard certifies its maintained centered-score profile;
   # the four standard renderer shards above cover the full six-layout matrix.
   next if $family==5 && $score!=0;
   for my$below(0,1) {
      push@errors,capture_case("$layouts[$score]_".($below?'below':'above'),$score,$below,0,0);
   }
   # Per-layout native negative controls prove this is not just another golden
   # that happens to accept the historical ten-cycle shift.
   my@bad=capture_case("$layouts[$score]_late",$score,0,1,0);
   grep(/P1 X108 columns=/,@bad) or die "$layouts[$score] delayed handoff was not rejected spatially\n";
}
die join('',@errors) if@errors;
print "vcs_score_handoff_positions family$family ok\n";
