#!/usr/bin/perl
# Explicit Stella 7.0 full-raster equivalence test for score-composed
# all_five_player_color_181. Not a default e2e dependency.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_fh { my($f)=@_; local$/; return <$f>//''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp_fh($o); my$se=slurp_fh($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
sub ok { my($label,@c)=@_; my($r,$s,$o,$e)=capture(@c); $r==0&&!$s or die "$label failed rc=$r sig=$s\n@c\n$o$e"; return($o,$e); }
sub findexe { my($n)=@_; return abs_path($n) if$n=~m{/}&&-x$n; for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p} return undef; }
sub terminate { my($p)=@_; return unless$p; kill'TERM',$p; for(1..20){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.05} kill'KILL',$p;waitpid($p,0); }
sub read_file { my($p)=@_; open(my$f,'<:raw',$p)or die"read $p: $!\n";local$/;my$s=<$f>//'';close$f;return$s; }
sub write_file { my($p,$s)=@_; open(my$f,'>:raw',$p)or die"write $p: $!\n";print{$f}$s;close$f; }

@ARGV==2 or die "usage: $0 REPO TMP\n";
my$repo=abs_path($ARGV[0])or die"resolve repo\n"; my$tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my$stella=$ENV{VCSC_STELLA}||$ENV{STELLA}||findexe('stella')or die"set STELLA or VCSC_STELLA\n";
my$xvfb=findexe('Xvfb')or die"Xvfb required\n"; my$perl=findexe('perl')or die"perl required\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc)); my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl)); my$digest=File::Spec->catfile($repo,qw(test stella_png_rgb_digest.pl));
my$cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));

my$display=250+($$%20); $display++ while-e"/tmp/.X11-unix/X$display"; my$d=":$display";
my$xpid=fork(); defined$xpid or die"fork Xvfb\n"; if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2; local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{HOME}=$tmp; local$ENV{SDL_AUDIODRIVER}='dummy';

sub build_rom {
   my($name,$src)=@_; my$rom=File::Spec->catfile($tmp,"$name.bin"); ok("build $name",$driver,'-I',$vcs,'-T',$cfg,$src,'-o',$rom); return$rom;
}
sub snapshot_digest {
   my($name,$rom)=@_; my$snap=File::Spec->catdir($tmp,"snap_$name"); my$user=File::Spec->catdir($tmp,"user_$name"); remove_tree($snap,$user); make_path($snap,$user);
   my@cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my$pid=fork(); defined$pid or die"fork Stella\n"; if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_$name.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   select undef,undef,undef,.4; ok("snapshot $name",$perl,$keys); my@png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05} terminate($pid); @png==1 or die"$name produced ".scalar(@png)." snapshots\n";
   my($dg,$de)=ok("digest $name",$perl,$digest,$png[0]); $de eq'' or die$de; chomp$dg; return$dg;
}
sub same_raster { my($label,$a,$b)=@_; my$da=snapshot_digest("${label}_candidate",$a); my$db=snapshot_digest("${label}_golden",$b); $da eq$db or die"$label Stella raster differs\ncandidate=$da\ngolden=$db\n"; }

sub make_pair {
   my($order,$source)=@_;
   my$c=read_file($source);
   # Keep Ball in the left quarter so the terminal delayed-latch flush is part
   # of every maintained equivalence snapshot. This reproduces the old ghost
   # where Ball reappeared on the renderer's final scanline.
   $c =~ s/game_BALL_X := 80;/game_BALL_X := 20;/ or die "$order Ball X marker missing\n";
   $c =~ s/page const uint8_t game_player0_colors\[8\] := \{.*?\};/page const uint8_t game_player0_colors[8] := { 0x0e,0x0e,0x0e,0x0e,0x0e,0x0e,0x0e,0x0e };/s
      or die "$order P0 colors marker missing\n";
   $c =~ s/page const uint8_t game_player1_colors\[8\] := \{.*?\};/page const uint8_t game_player1_colors[8] := { 0xc8,0xc8,0xc8,0xc8,0xc8,0xc8,0xc8,0xc8 };/s
      or die "$order P1 colors marker missing\n";
   my$cs=File::Spec->catfile($tmp,"candidate_$order.c26"); write_file($cs,$c);
   my$g=$c;
   $g =~ s/page const uint8_t game_player0_colors\[8\] := \{.*?\};\n//s or die "$order remove P0 colors\n";
   $g =~ s/page const uint8_t game_player1_colors\[8\] := \{.*?\};\n//s or die "$order remove P1 colors\n";
   $g =~ s#instantiate "renderers/all_five_player_color_181/all_five_player_color_181\.c26" as game#instantiate "renderers/all_five/all_five.c26" as game (lines:=181)# or die "$order replace renderer\n";
   $g =~ s/(CTRLPF\s*:=\s*0x21;)/$1\n   game_player0_color := 0x0e;\n   game_player1_color := 0xc8;\n   game_playfield_position := 8;/ or die "$order add all-five controls\n";
   my$gs=File::Spec->catfile($tmp,"golden_$order.c26"); write_file($gs,$g);
   return(build_rom("candidate_$order",$cs),build_rom("golden_$order",$gs));
}

my@orders=(
 ['above',File::Spec->catfile($repo,qw(examples 16_all_five_player_color_181 01_score_above 01_static all_five_player_color_181_score_above.c26))],
 ['below',File::Spec->catfile($repo,qw(examples 16_all_five_player_color_181 02_score_below 01_static all_five_player_color_181_score_below.c26))],
);
for my$j(@orders){my($name,$src)=@$j; my($cand,$gold)=make_pair($name,$src); same_raster("score_$name",$cand,$gold);}

# Physical player-X regression. The historical 181 visible-entry handoff mapped
# source X=13,14,15,16 onto one physical position every 15 pixels. Build those
# four coordinates with the other player parked far away; all four Stella RGB
# digests must differ. This is intentionally an emulator-level check because
# the bad register sequences looked internally self-consistent to CPU oracles.
sub check_player_gap {
   my($which,$source)=@_; my%seen;
   for my$x(13..16){
      my$c=read_file($source);
      if($which==0){
         $c =~ s/game_PLAYER0_X := 20;/game_PLAYER0_X := $x;/ or die "P0 X marker missing\n";
         $c =~ s/game_PLAYER1_X := 130;/game_PLAYER1_X := 100;/ or die "P1 park marker missing\n";
      } else {
         $c =~ s/game_PLAYER0_X := 20;/game_PLAYER0_X := 100;/ or die "P0 park marker missing\n";
         $c =~ s/game_PLAYER1_X := 130;/game_PLAYER1_X := $x;/ or die "P1 X marker missing\n";
      }
      my$name="player${which}_x$x";
      my$src=File::Spec->catfile($tmp,"$name.c26"); write_file($src,$c);
      my$dg=snapshot_digest($name,build_rom($name,$src));
      die "P$which physical X plateau returned at source X=$x\n" if$seen{$dg}++;
   }
}
check_player_gap(0,$orders[0][1]);
check_player_gap(1,$orders[0][1]);
terminate($xpid);
print "Stella all-five player-color 181 score equivalence passed\n";
