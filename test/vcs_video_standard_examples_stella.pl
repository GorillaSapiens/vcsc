#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c);close$i;my$so=slurp_fh($o);my$se=slurp_fh($e);waitpid($p,0);return($?>>8,$?&127,$so,$se); }
sub findexe { my($n)=@_;return abs_path($n)if$n=~m{/}&&-x$n;for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p}return undef; }
sub terminate { my($p)=@_;return unless$p;kill'TERM',$p;for(1..20){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.05}kill'KILL',$p;waitpid($p,0); }
sub png_dimensions { my($p)=@_;open(my$f,'<:raw',$p)or die"read $p: $!\n";read($f,my$h,24)==24 or die"short PNG $p\n";close$f;substr($h,0,8)eq"\x89PNG\r\n\x1a\n"or die"not PNG $p\n";return unpack('NN',substr($h,16,8)); }
sub ok { my($label,@c)=@_;my($r,$s,$o,$e)=capture(@c);$r==0&&!$s or die"$label failed\n@c\n$o$e";return($o,$e); }
sub read_file { my($p)=@_;open(my$f,'<:raw',$p)or die"read $p: $!\n";local$/;my$d=<$f>;close$f;return defined($d)?$d:''; }

@ARGV==2 or die"usage: $0 REPO TMP\n";
my$repo=abs_path($ARGV[0])or die"repo\n";my$tmp=$ARGV[1];make_path($tmp);$tmp=abs_path($tmp);
my$stella=$ENV{VCSC_STELLA}||$ENV{STELLA}||findexe('stella')or die"set STELLA or VCSC_STELLA\n";
my$xvfb=findexe('Xvfb')or die"Xvfb required\n";my$perl=findexe('perl')or die"perl required\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));my$vcs=File::Spec->catdir($repo,qw(libraries vcs));my$keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));
my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));
my$mos_obj=File::Spec->catfile($mos,'mos6502.o');
my@mos_input=-f$mos_obj?($mos_obj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$phase_src=File::Spec->catfile($repo,qw(test vcs_playfield_phase.cpp));
my$phase=File::Spec->catfile($tmp,'vcs_video_standard_playfield_phase');
for my$spec(
   ['pal','__builtin_pal_rgb',qw(17_video_standards pal 00_blank pal50_blank.c26)],
   ['pal','__builtin_pal_rgb',qw(17_video_standards pal 01_all_five pal_all_five_228_interactive.c26)],
   ['pal','__builtin_pal_rgb',qw(17_video_standards pal 02_player_color pal_player_color_228_interactive.c26)],
   ['pal','__builtin_pal_rgb',qw(17_video_standards pal 03_all_five_unofficial pal_all_five_unofficial_228_interactive.c26)],
   ['pal','__builtin_pal_rgb',qw(17_video_standards pal 04_multisprite pal_multisprite_228_interactive.c26)],
   ['pal','__builtin_pal_rgb',qw(17_video_standards pal 05_enhanced_multisprite_asymmetric pal_enhanced_multisprite_asymmetric_228_interactive.c26)],
   ['secam','__builtin_secam_rgb',qw(17_video_standards secam 00_blank secam50_blank.c26)],
   ['secam','__builtin_secam_rgb',qw(17_video_standards secam 01_all_five secam_all_five_228_interactive.c26)],
   ['secam','__builtin_secam_rgb',qw(17_video_standards secam 02_player_color secam_player_color_228_interactive.c26)],
   ['secam','__builtin_secam_rgb',qw(17_video_standards secam 03_all_five_unofficial secam_all_five_unofficial_228_interactive.c26)],
   ['secam','__builtin_secam_rgb',qw(17_video_standards secam 04_multisprite secam_multisprite_228_interactive.c26)],
   ['secam','__builtin_secam_rgb',qw(17_video_standards secam 05_enhanced_multisprite_asymmetric secam_enhanced_multisprite_asymmetric_228_interactive.c26)]) {
   my($standard,$builtin,@parts)=@$spec;
   my$src=File::Spec->catfile($repo,'examples',@parts);
   -f$src or die"missing reorganized $standard example $src\n";
   my$text=read_file($src);
   $text =~ /\Q$builtin\E\s*\(/ or die"$src does not use $builtin directly\n";
   $text !~ /^\s*include\s+"color_(?:pal|secam)\.c26"/m
      or die"$src hides RGB matching behind a color alias include\n";
   if ($src =~ /_228_interactive\.c26$/) {
      $text =~ /lines\s*:=\s*228/ or die"$src is not a native 228-line renderer example\n";
      $text !~ /visible_(?:pre|tail|border)|hide_border|border_handoff/i
         or die"$src reintroduced synthetic visible padding\n";
   }
}
ok('build 50 Hz playfield phase harness',$cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$phase_src,@mos_input,'-o',$phase);

# The all-five profile has an independent PF-write phase oracle.
for my$case(
   ['pal',qw(17_video_standards pal 01_all_five pal_all_five_228_interactive.c26)],
   ['secam',qw(17_video_standards secam 01_all_five secam_all_five_228_interactive.c26)]) {
   my($standard,@parts)=@$case;
   my$src=File::Spec->catfile($repo,'examples',@parts);
   my$rom=File::Spec->catfile($tmp,"$standard-all-five-phase.bin");
   ok("build $standard all-five phase example",$driver,'-I',$vcs,$src,'-o',$rom);
   my($phase_out,$phase_err)=ok("$standard playfield phase",$phase,$rom,'15','15','48','all-five-phase-228');
   $phase_out eq "vcs_playfield_all_five_phase_228 ok: 228 lines (4 + 14x16) with proven PF phases\n"
      or die "$standard playfield phase output: $phase_out";
   $phase_err eq '' or die "$standard playfield phase stderr: $phase_err";
}

# Every native 228-line renderer gets a real Stella 7 launch/snapshot check.
for my$case(
   ['pal','PAL','all-five',[],qw(17_video_standards pal 01_all_five pal_all_five_228_interactive.c26)],
   ['pal','PAL','player-color',[],qw(17_video_standards pal 02_player_color pal_player_color_228_interactive.c26)],
   ['pal','PAL','all-five-unofficial',['-Wa,--illegals'],qw(17_video_standards pal 03_all_five_unofficial pal_all_five_unofficial_228_interactive.c26)],
   ['pal','PAL','multisprite',['-Wa,--illegals'],qw(17_video_standards pal 04_multisprite pal_multisprite_228_interactive.c26)],
   ['pal','PAL','enhanced-asymmetric',['-nostdlib','-DMULTISPRITE_NO_RETAINED_PF_ROWS'],qw(17_video_standards pal 05_enhanced_multisprite_asymmetric pal_enhanced_multisprite_asymmetric_228_interactive.c26)],
   ['secam','SECAM','all-five',[],qw(17_video_standards secam 01_all_five secam_all_five_228_interactive.c26)],
   ['secam','SECAM','player-color',[],qw(17_video_standards secam 02_player_color secam_player_color_228_interactive.c26)],
   ['secam','SECAM','all-five-unofficial',['-Wa,--illegals'],qw(17_video_standards secam 03_all_five_unofficial secam_all_five_unofficial_228_interactive.c26)],
   ['secam','SECAM','multisprite',['-Wa,--illegals'],qw(17_video_standards secam 04_multisprite secam_multisprite_228_interactive.c26)],
   ['secam','SECAM','enhanced-asymmetric',['-nostdlib','-DMULTISPRITE_NO_RETAINED_PF_ROWS'],qw(17_video_standards secam 05_enhanced_multisprite_asymmetric secam_enhanced_multisprite_asymmetric_228_interactive.c26)]) {
   my($standard,$format,$family,$flags,@parts)=@$case;
   my$tag="$standard-$family";
   my$src=File::Spec->catfile($repo,'examples',@parts);
   my$rom=File::Spec->catfile($tmp,"$tag.bin");
   my@inputs=($src);
   if ($family eq 'enhanced-asymmetric') {
      (my$startup=$src) =~ s/\.c26\z/_startup.s26/;
      push@inputs,$startup;
   }
   ok("build $tag example",$driver,'-I',$vcs,@$flags,@inputs,'-o',$rom);
   my$display=360+($$%40);$display++ while-e"/tmp/.X11-unix/X$display";my$d=":$display";
   my$xpid=fork();defined$xpid or die"fork Xvfb\n";if(!$xpid){open(STDOUT,'>:raw',"$tmp/$tag.xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
   select undef,undef,undef,.2;local$ENV{DISPLAY}=$d;local$ENV{XAUTHORITY}='/dev/null';local$ENV{HOME}="$tmp/home-$tag";local$ENV{SDL_AUDIODRIVER}='dummy';make_path($ENV{HOME});
   my$snap="$tmp/snap-$tag";my$user="$tmp/user-$tag";make_path($snap,$user);unlink glob("$snap/*.png");
   my$bs=$family eq 'enhanced-asymmetric' ? 'F8' : '4K';
   my@cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-format',$format,'-bs',$bs,'-snapsavedir',$snap,'-snapname',$tag,'-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my$pid=fork();defined$pid or die"fork Stella\n";if(!$pid){open(STDOUT,'>:raw',"$tmp/$tag.stella.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   ok("snapshot $tag example",$perl,$keys);my@png;for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}terminate($pid);terminate($xpid);@png==1 or die"$tag Stella produced ".scalar(@png)." snapshots\n";
   my($w,$h)=png_dimensions($png[0]);$w==320&&$h==274 or die"$tag example snapshot ${w}x${h}, expected 320x274\n";
}
print "vcs_video_standard_examples_stella ok\n";
