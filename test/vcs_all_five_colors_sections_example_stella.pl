#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 600
# expectstdout: combined-colour preview Stella composite ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
$repo=abs_path($repo);$tmp=abs_path($tmp);
sub slurp { open(my$f,'<',$_[0]) or die$!;local$/;return <$f>; }
sub save { open(my$f,'>',$_[0]) or die$!;print{$f}$_[1];close$f; }
sub run {
   my$err=gensym;my$p=open3(my$i,my$o,$err,@_);close$i;
   local$/;my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   $?==0 or die "@_ failed\n$out$e";
}
sub findexe { my($n)=@_;return abs_path($n) if$n=~m{/}&&-x$n;for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p}die"missing $n"; }
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
require "$repo/test/stella_test_lib.pl";
my$helpers=slurp("$repo/test/stella_png_sequence.pl");
$helpers =~ s/\n\@ARGV>=2.*\z//s or die 'PNG helper boundary';
eval$helpers;die$@ if$@;
my%children;
sub terminate {
   my$p=shift;return unless delete$children{$p};
   return if waitpid($p,WNOHANG)!=0;
   kill'TERM',$p;
   for(1..20){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.05}
   kill'KILL',$p;waitpid($p,0);
}
END { local$?;terminate($_) for keys%children; }
my(undef,$display)=vcsc_reserve_x_display(650,40);
my$xp=fork();defined$xp or die$!;
if(!$xp){open(STDOUT,'>',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$display,'-ac','-screen','0','800x600x24');die$!}
$children{$xp}=1;vcsc_xvfb_assert_ready($display,$xp);
$ENV{DISPLAY}=$display;$ENV{XAUTHORITY}='/dev/null';$ENV{SDL_AUDIODRIVER}='dummy';
my$fixture="$repo/test/fixtures/all_five_colors_sections_preview";
my$source="$fixture/interactive.c26";
my$driver="$repo/driver/vcsc";
run($driver,'-I',"$repo/libraries/vcs",$source,'-o',"$tmp/actual.bin");
sub snapshot {
   my($name)=@_;my$snap="$tmp/snap_$name";my$user="$tmp/user_$name";
   !-e$snap or die "capture directory already exists: $snap";
   make_path($snap,$user);
   my@cmd=($stella,vcsc_stella_palette_args($repo,$user),'-video','software','-turbo','1','-audio.enabled','0',
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0',
      '-bs','F8','-framesnap','200','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
      '-exitlauncher','0','-confirmexit','0','-userdir',$user,"$tmp/$name.bin");
   my$p=fork();defined$p or die$!;
   if(!$p){open(STDOUT,'>',"$tmp/stella_$name.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   $children{$p}=1;my@png=vcsc_stella_wait_snapshots("$snap/*.png",1);terminate($p);
   @png==1 or die"$name produced ".scalar(@png)." snapshots";
   return[decode_rgb($png[0])];
}
my$actual=snapshot('actual');
my$ordinary=slurp($source);
$ordinary =~ s#"sprites.c26"#"$fixture/sprites.c26"#g;
$ordinary =~ s#instantiate "component.c26" as game \(.*?\)#instantiate "renderers/all_five_player_color_192/all_five_player_color_192.c26" as game#s or die 'preview instantiation';
my@pal=([0x2e,0x84],[0x46,0xc2],[0x8e,0x26],[0xae,0x64]);
my@references;
for my$n(0..3) {
   my$s=$ordinary;
   $s =~ s/game_INITIAL_COLUPF/$pal[$n][0]/g;
   $s =~ s/game_INITIAL_COLUBK/$pal[$n][1]/g;
   save("$tmp/golden$n.c26",$s);
   run($driver,'-I',"$repo/libraries/vcs","$tmp/golden$n.c26",'-o',"$tmp/golden$n.bin");
   push@references,snapshot("golden$n");
}
my($w,$h,$rgb)=@{$references[0]};
$w==320 or die 'unexpected raster width';
my%counts;for my$y(0..$h-1){$counts{substr($rgb,($y*$w+20)*3,3)}++}
my($background)=sort{$counts{$b}<=>$counts{$a}}keys%counts;
my@visible=grep{substr($rgb,($_*$w+20)*3,3)eq$background}0..$h-1;
@visible==192 or die 'ordinary renderer visible extent is not 192';
my$first=$visible[0];my$expected=$rgb;
for my$line(0..191) {
   my$n=$line<64?int($line/16)%4:int(($line-64)/32)%4;
   substr($expected,($first+$line)*$w*3,$w*3)=substr($references[$n][2],($first+$line)*$w*3,$w*3);
}
# The terminal section's background persists in the blank tail until VBLANK.
# Compare the gameplay rectangle only; frame timing and tail cleanup are checked
# independently by the CPU lifecycle test, not inferred from palette selection.
$actual->[0]==$w&&$actual->[1]==$h or die 'preview viewport differs';
substr($actual->[2],$first*$w*3,192*$w*3) eq substr($expected,$first*$w*3,192*$w*3)
   or die 'interactive preview RGB differs from independent ordinary-renderer composite';
print "combined-colour preview Stella composite ok\n";
