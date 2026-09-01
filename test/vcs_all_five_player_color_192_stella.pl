#!/usr/bin/perl
# Explicit Stella 7.0 raster equivalence test for all_five_player_color_192.
# Not a default e2e dependency: hosts without Stella/Xvfb can run the normal suite.
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

my$display=230+($$%20); $display++ while-e"/tmp/.X11-unix/X$display"; my$d=":$display";
my$xpid=fork(); defined$xpid or die"fork Xvfb\n"; if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2; local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{HOME}=$tmp; local$ENV{SDL_AUDIODRIVER}='dummy';

sub build_rom {
   my($name,$src)=@_; my$rom=File::Spec->catfile($tmp,"$name.bin"); ok("build $name",$driver,'-I',$vcs,$src,'-o',$rom); return$rom;
}
sub snapshot_digest {
   my($name,$rom)=@_; my$snap=File::Spec->catdir($tmp,"snap_$name"); my$user=File::Spec->catdir($tmp,"user_$name"); remove_tree($snap,$user); make_path($snap,$user);
   my@cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my$pid=fork(); defined$pid or die"fork Stella\n"; if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_$name.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   select undef,undef,undef,.4; ok("snapshot $name",$perl,$keys); my@png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05} terminate($pid); @png==1 or die"$name produced ".scalar(@png)." snapshots\n";
   my($dg,$de)=ok("digest $name",$perl,$digest,$png[0]); $de eq'' or die$de; chomp$dg; return$dg;
}
sub same_raster { my($label,$a,$b)=@_; my$da=snapshot_digest("${label}_candidate",$a); my$db=snapshot_digest("${label}_golden",$b); $da eq$db or die"$label Stella raster differs\ncandidate=$da\ngolden=$db\n"; }

my$cand_pc=build_rom('candidate_player_color',File::Spec->catfile($repo,qw(test fixtures all_five_player_color_192 player_color_match.c26)));
my$gold_pc=build_rom('golden_player_color',File::Spec->catfile($repo,qw(test fixtures player_color_192 smoke.c26)));
same_raster('player_color',$cand_pc,$gold_pc);

my$cand_all=build_rom('candidate_all_five',File::Spec->catfile($repo,qw(test fixtures all_five_player_color_192 all_five_match.c26)));
my$gold_all=build_rom('golden_all_five',File::Spec->catfile($repo,qw(test fixtures all_five_192 smoke.c26)));
same_raster('all_five',$cand_all,$gold_all);

my$stress=read_file(File::Spec->catfile($repo,qw(test fixtures all_five_player_color_192 p1_ball_stress.c26)));
for my$y(15,16,31){
   my$c=$stress; $c =~ s/game_player1_y:=31;/game_player1_y:=$y;/ or die"stress P1 Y marker missing\n";
   my$cs=File::Spec->catfile($tmp,"candidate_stress_$y.c26"); write_file($cs,$c);
   my$g=$c;
   $g =~ s/page const uint8_t game_player0_colors\[8\] := \{.*?\};\n//s or die"remove P0 colors\n";
   $g =~ s/page const uint8_t game_player1_colors\[8\] := \{.*?\};\n//s or die"remove P1 colors\n";
   $g =~ s#instantiate "renderers/all_five_player_color_192/all_five_player_color_192\.c26" as game#instantiate "renderers/all_five/all_five.c26" as game (lines:=192)# or die"replace renderer\n";
   $g =~ s/(CTRLPF:=0x20;)/$1\n game_player0_color:=0x3e; game_player1_color:=0xce; game_playfield_position:=0;/ or die"add solid-color controls\n";
   my$gs=File::Spec->catfile($tmp,"golden_stress_$y.c26"); write_file($gs,$g);
   same_raster("p1_ball_y$y",build_rom("candidate_stress_$y",$cs),build_rom("golden_stress_$y",$gs));
}
terminate($xpid);
print "Stella all-five player-color 192 equivalence passed\n";
