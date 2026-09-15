#!/usr/bin/perl
# Authoritative Stella 7.0 raster certification for the 0..11 heart-score component.
# This is an explicit Stella target rather than a default e2e dependency so the
# normal suite remains runnable on hosts without Stella/Xvfb.

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp_fh($o); my$se=slurp_fh($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
sub ok { my($label,@c)=@_; my($r,$s,$o,$e)=capture(@c); $r==0&&!$s or die "$label failed rc=$r sig=$s\n@c\n$o$e"; return($o,$e); }
sub findexe { my($n)=@_; return abs_path($n) if $n=~m{/}&&-x$n; for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p} return undef; }
sub terminate { my($p)=@_; return unless$p; kill 'TERM',$p; for(1..20){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.05} kill 'KILL',$p;waitpid($p,0); }

@ARGV==2 or die "usage: $0 REPO TMP\n";
my $repo=abs_path($ARGV[0]) or die "resolve repo\n";
my $tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my $stella=$ENV{VCSC_STELLA}||$ENV{STELLA}||findexe('stella') or die "set STELLA or VCSC_STELLA\n";
my $xvfb=findexe('Xvfb') or die "Xvfb required\n";
my $perl=findexe('perl') or die "perl required\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures heart_score golden.c26));
my $keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));
my $digest=File::Spec->catfile($repo,qw(test stella_png_rgb_digest.pl));
my @wanted_full=(
'320 x 228 886f3e370499d568119b2e5958a2b778abbc45cda3e050ecd5f4051cab830ec6',
'320 x 228 5720092920966b0bbcaf357f7981e8192f3724c652551c6a8e796e444334bf02',
'320 x 228 5fa062f652de8b43875a1f15b1105f31ba5ab269da3907fe0780d385c55f2896',
'320 x 228 36497f3a9ad18b9d0223dbf2bed17c604632cf460a78ba5bd44ba94fb057e9e7',
'320 x 228 cfef7b04b326925b0293e519a5ee7beb63da6fe8a0679dcd13a2053be3a0c7f8',
'320 x 228 9d8fcfa3e2426da924f6d5808572d8a9b86d7ce9fe3cc88aef57ccbb26c0aa83',
'320 x 228 085faba4d704cc5b0c0c618f1975e2b2d1bf9dcf105433e01f69ba9f3c2cd004',
'320 x 228 d452f14a3f232787afc03929d613102a5364290752fbbcdc06d589c7f3154914',
'320 x 228 3876460aa952798667d07f1733b5d851f418b6d0dd0b352e6d08f8e03cc5796e',
'320 x 228 3d426bd5de5af558b53122aca20d44cfe1939d3fad3ede047f2c444958d1331a',
'320 x 228 906203811de9cc3a39ae0e68a8acf5b1fbb3fd5e8384a7955917c3aec3886c5f',
'320 x 228 8f6a51ac3e0df1b1683758cbfe7dcf13c965b2ce6565bc864734cf132f501eac',
);
my @wanted_half=(
'320 x 228 b10182e48eca7d97d8f42cccaf46b97be080eba511f69b2766fb34265b6f046d',
'320 x 228 6d5a17fcafeb39cea2da9f7291be02c706e51363d97aa17ef48d629c4010cb8d',
'320 x 228 e4500ca971b8ed323609013cca2b4d42ada83512ebd976dbbab6a1d04fa960b4',
'320 x 228 3526eec635bc924451c891215886fb352c4d64da72ca23a8df65307d9065e1b7',
'320 x 228 d1200de65fe09bf2295bb75ed9abbfac218dc6d76aad80ad5b7aa502e56cb11a',
'320 x 228 62a828766ef7260961fdc0afd07273891f0dfa11cced7a96b54e0e2a01464d45',
'320 x 228 b8e8ef7ed4d70e613523987933d37a990133161da7d3e7a30f4561df4cb1fdbf',
'320 x 228 0e7dd85d818be161a1e0c318df241dc4ceb2e17f70cc4bdfa286c4ac8de2304f',
'320 x 228 f339284c0ad2ab05bf1912d03d115f58a4b278145e48372254581a8a1eee68e1',
'320 x 228 f66e0f4904d9ae5ec9dbf33b4f532dfca5bc0c3ef25410e14b626786ada46f67',
'320 x 228 61acf0d5927fda0bcd2cb29353ce9a9a75a9a47d22751736d4ce27c92323bbb3',
'320 x 228 8f6a51ac3e0df1b1683758cbfe7dcf13c965b2ce6565bc864734cf132f501eac',
);

my $display=180+($$%50); $display++ while -e "/tmp/.X11-unix/X$display";
my $d=":$display";
my $xpid=fork(); defined$xpid or die "fork Xvfb\n";
if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2;
local $ENV{DISPLAY}=$d; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp; local $ENV{SDL_AUDIODRIVER}='dummy';
my $snap=File::Spec->catdir($tmp,'snap'); my$user=File::Spec->catdir($tmp,'user'); make_path($snap,$user);

for my $half (0,1) {
   my $wanted=$half ? \@wanted_half : \@wanted_full;
   for my $score (0..11) {
      my $label=$half ? ($score == 11 ? "11+half(max)" : "$score.5") : "$score";
      my $rom=File::Spec->catfile($tmp,"heart_score_${score}_${half}.bin");
      ok("build heart score $label",$driver,'-I',$vcs,"-DHEART_SCORE=$score","-DHEART_HALF=$half",$source,'-o',$rom);
      unlink glob("$snap/*.png");
      my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
         '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
         '-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
      my $pid=fork(); defined$pid or die "fork Stella\n";
      if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_${score}_${half}.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
      ok("snapshot heart score $label",$perl,$keys,'--fast');
      my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
      terminate($pid); @png==1 or die "Stella produced ".scalar(@png)." snapshots for score $label\n";
      my($actual,$ae)=ok("digest heart score $label",$perl,$digest,$png[0]);
      $ae eq '' or die $ae; chomp $actual;
      $actual eq $wanted->[$score] or die "heart score $label raster differs: actual=$actual wanted=$wanted->[$score]\n";
   }
}

# Capacity-box certification: hide the zero-heart sprite and render the box
# color visibly against the fixture background. One hash per 0..11 capacity
# locks the asymmetric PF1/PF2 geometry and fixed 12-pixel slot pitch.
my @wanted_boxes=(
   '320 x 228 886f3e370499d568119b2e5958a2b778abbc45cda3e050ecd5f4051cab830ec6',
   '320 x 228 b8fd09e14006a0bb98b7235c65bc06a17282d1d60d2b8aa9bb581cade0c92c8b',
   '320 x 228 52ca493dea49d8af1140608060f2428a55960f903add13e895dfe2215e29e7d0',
   '320 x 228 30574139c4228ec7d3c299144236ffda8317dba45fc9a3c28425bc170aa381a0',
   '320 x 228 86033d331fcfa40dbebdb70b0bb4f2db68b2ea21cc76e652ba34af7a7d09db80',
   '320 x 228 088e0327bc379923c62ffbb38192d98270da124790d4569abde35786114d3b00',
   '320 x 228 02bae99ff18eaf8c7534870a73dfb6ee8a7c59d237ac04ec1b3deb05de4ddd04',
   '320 x 228 ef4ab4e272bc6986a774eb065cdd3d54c8328df5817e0d9514916dc1d01bf72e',
   '320 x 228 eb89d87587b87f654048a0b4b167230fb2f5b1d2614c967d8f27a737cd98b3cc',
   '320 x 228 4a569bb9ce792f8de69c0aeb4c31f77648285828bd0592673f235147eee43cf2',
   '320 x 228 751bdc8b29ccbb1edced06d806078bcd377455b115a4d5fe90c70c33fdb5dbf2',
   '320 x 228 33e78af9f6b347e834d5e7ee4310e2ce2e45d9a2158d1cfadc47b601d2879bb2',
);
for my $boxes (0..11) {
   my $rom=File::Spec->catfile($tmp,"heart_boxes_${boxes}.bin");
   ok("build heart boxes $boxes",$driver,'-I',$vcs,'-DHEART_SCORE=0','-DHEART_HALF=0',
      "-DHEART_BOXES=$boxes",'-DHEART_BOX_COLOR=46',$source,'-o',$rom);
   unlink glob("$snap/*.png");
   my $box_user=File::Spec->catdir($tmp,"user_boxes_${boxes}"); make_path($box_user);
   my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
      '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
      '-exitlauncher','0','-confirmexit','0','-userdir',$box_user,$rom);
   my $pid=fork(); defined$pid or die "fork Stella\n";
   if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_boxes_${boxes}.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   ok("snapshot heart boxes $boxes",$perl,$keys,'--fast');
   my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
   terminate($pid); @png==1 or die "Stella produced ".scalar(@png)." snapshots for boxes $boxes\n";
   my($actual,$ae)=ok("digest heart boxes $boxes",$perl,$digest,$png[0]);
   $ae eq '' or die $ae; chomp $actual;
   $actual eq $wanted_boxes[$boxes]
      or die "heart box raster $boxes differs: actual=$actual wanted=$wanted_boxes[$boxes]\n";
}

# Composition certification: the real 181-line player-color renderer and the
# seven-line heart renderer must coexist in either visible order. The initial
# 5.5 state plus held right-joystick UP/DOWN lock one health transition in each
# direction (6.0 and 5.0), while LEFT/RIGHT lock one capacity transition
# (7 and 9 boxes). Held left-joystick RIGHT locks real gameplay motion
# of the initially selected P0 so these cartridges cannot regress to static
# "interactive" demos again.
my %demo_wanted=(
   above=>{
      neutral=>'320 x 228 e7956c278ee1a146de0e4f313be0eb91b11d5eeb332dbeaa6912d2e8d75d5ca1',
      score_up=>'320 x 228 5b912aed8ed9fa87a36cd0cd358c904362ee5c8497d4f5c60e07a2a442bfc9fe',
      score_down=>'320 x 228 dbb9bfb3f843a65a3c3accca35e540ea5f8a5c14ff7ab23f52b90561518e5082',
      boxes_left=>'320 x 228 76dbc1c7dff4d1f11cb090e78c63139d2b4a90973f343b68703989bd27007db4',
      boxes_right=>'320 x 228 8219cfd9543c5d6a9655cca14a3f849f0e5509975bd937256818e4062baac958',
      move_right=>'320 x 228 57022ebd988f8f6ac4e59c126d96f9e44bd98a4b457821f0d37d5816ff490835',
   },
   below=>{
      neutral=>'320 x 228 e2045597687c3b4b583b0e62793efcaae77e78e178811c29b9d95019f56c9005',
      score_up=>'320 x 228 e8aecda62efe1c19232f01ea0aa2b80089270ff70ba0de3281d1a04da55ea5d9',
      score_down=>'320 x 228 6b5755a968ddb7433f862fd194729bf53bd768171053540459cebdbd045f89df',
      boxes_left=>'320 x 228 66bf72249036aa0ca953860daf5f9064320e91cb2fedeb8d4c6058c033b4c50c',
      boxes_right=>'320 x 228 b61ebaa7d3be1a16fe48634ff38d532d90f4d2df1058753dc92613cec96cfeea',
      move_right=>'320 x 228 0c2f30107ef62ae610b80f9eb0a2a05fabb1f0bc5650086b12be843ba9b06359',
   },
);
my @demo_inputs=(
   [neutral=>[]],
   [score_up=>['-holdjoy1','U']],
   [score_down=>['-holdjoy1','D']],
   [boxes_left=>['-holdjoy1','L']],
   [boxes_right=>['-holdjoy1','R']],
   [move_right=>['-holdjoy0','R']],
);
for my $kind (qw(above below)) {
   my $demo_source=File::Spec->catfile($repo,qw(examples 01_basic 14_heart_score),"heart_score_${kind}_interactive.c26");
   my $rom=File::Spec->catfile($tmp,"heart_score_${kind}_interactive.bin");
   ok("build heart score $kind composition",$driver,'-I',$vcs,$demo_source,'-o',$rom);
   -s $rom==8192 or die "heart score $kind composition is not an 8K F8 ROM\n";
   for my $case (@demo_inputs) {
      my($label,$joy)=@$case;
      unlink glob("$snap/*.png");
      my $demo_user=File::Spec->catdir($tmp,"user_${kind}_${label}"); make_path($demo_user);
      my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','F8',
         @$joy,'-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
         '-exitlauncher','0','-confirmexit','0','-userdir',$demo_user,$rom);
      my $pid=fork(); defined$pid or die "fork Stella\n";
      if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_${kind}_${label}.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
      ok("snapshot heart score $kind $label",$perl,$keys,'--fast');
      my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
      terminate($pid); @png==1 or die "Stella produced ".scalar(@png)." snapshots for heart score $kind $label\n";
      my($actual,$ae)=ok("digest heart score $kind $label",$perl,$digest,$png[0]);
      $ae eq '' or die $ae; chomp $actual;
      $actual eq $demo_wanted{$kind}{$label}
         or die "heart score $kind $label raster differs: actual=$actual wanted=$demo_wanted{$kind}{$label}\n";
   }
}

# The bottom composition specifically certifies the low-count states that depend
# on singleton P0/P1 geometry.  A preceding player renderer is allowed to leave
# arbitrary horizontal player state; score_draw() must re-establish its own
# footprint.  Mask everything except the six score rows so unrelated scene
# pixels cannot make a bad heart placement look valid.
my @below_low=(
   [0,1,'0.5','320 x 228 b25472103fcf50a4a46fc12517a68e5299c54a4fb735f5ad0ac1e2314cd7dcf3'],
   [1,0,'1.0','320 x 228 09e78490daa36994d0ca4e61b77693d369f31d4415c079b7b0764adabb7f4f6d'],
   [1,1,'1.5','320 x 228 47a29d570b03080496714da93cf697a72cffda25f3c0657d625d3b32a88c143a'],
   [2,0,'2.0','320 x 228 42f079299882a4e4a95ded6532b18aa9519d2cc3544ace4d7de2b12e74c4c7d1'],
   [2,1,'2.5','320 x 228 eab0285bf407c30090402fc923204ef47dc28be567e4e355eb603068647d3c57'],
   [3,0,'3.0','320 x 228 716cbb9adc3222933f24e7efe95fca4b9dde7607b32dbbac7d78b499f08a4697'],
);
my $below_source=File::Spec->catfile($repo,qw(examples 01_basic 14_heart_score),'heart_score_below_interactive.c26');
for my $case (@below_low) {
   my($score,$half,$label,$wanted)=@$case;
   my $rom=File::Spec->catfile($tmp,"heart_score_below_low_${score}_${half}.bin");
   ok("build bottom composition $label",$driver,'-I',$vcs,
      "-DHEART_SCORE_INITIAL_SCORE=$score","-DHEART_SCORE_INITIAL_HALF=$half","-DHEART_SCORE_INITIAL_BOX_COLOR=130",
      $below_source,'-o',$rom);
   unlink glob("$snap/*.png");
   my $low_user=File::Spec->catdir($tmp,"user_below_low_${score}_${half}"); make_path($low_user);
   my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','F8',
      '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
      '-exitlauncher','0','-confirmexit','0','-userdir',$low_user,$rom);
   my $pid=fork(); defined$pid or die "fork Stella\n";
   if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_below_low_${score}_${half}.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   ok("snapshot bottom composition $label",$perl,$keys,'--fast');
   my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
   terminate($pid); @png==1 or die "Stella produced ".scalar(@png)." snapshots for bottom composition $label\n";
   my($actual,$ae)=ok("digest bottom composition $label",$perl,$digest,
      '--mask-rows','0-199','--mask-rows','206-227',$png[0]);
   $ae eq '' or die $ae; chomp $actual;
   $actual eq $wanted
      or die "bottom composition $label heart rows differ: actual=$actual wanted=$wanted\n";
}

terminate($xpid);
print "vcs_heart_score_stella ok\n";
