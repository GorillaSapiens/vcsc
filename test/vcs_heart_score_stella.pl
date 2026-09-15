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

# Composition certification: the real 181-line player-color renderer and the
# seven-line heart renderer must coexist in either visible order. The initial
# 5.5 state plus held right-joystick UP/DOWN lock one health transition in each
# direction (6.0 and 5.0). Held left-joystick RIGHT locks real gameplay motion
# of the initially selected P0 so these cartridges cannot regress to static
# "interactive" demos again.
my %demo_wanted=(
   above=>{
      neutral=>'320 x 228 e7c4ad08dab58982e519427730ee521e10f22f4559ce880759ab9e31385b9bf2',
      score_up=>'320 x 228 e990766e5c3a72b66636a8fa6dc0b9f03c7e168118bb8c10c388bc9163c9b9be',
      score_down=>'320 x 228 7f185d1dba6c0f630f42d0e08b2140f856d0ed4cd123a7d8019a616d1f412504',
      move_right=>'320 x 228 7acfac858feb57d6b1daf666c0a0336d3aede1b67dc878b69178ffd65d6d6351',
   },
   below=>{
      neutral=>'320 x 228 37f583c87535a6099d7b9c916de8abacd53d768fb3a94b0b2c3a6aa5ab715fd6',
      score_up=>'320 x 228 1480a0544803c5afbacd635e79ee968ca80c4dce81296dd1c2af7ce9ce5a4de3',
      score_down=>'320 x 228 3e335dbe9805188cab1ce1a9d29e72a745749d599c83d559c395e2a193de677e',
      move_right=>'320 x 228 3bee9ad675144951b87a48afe8c2c5def455e45fa0ed7cfbb12bbda0bb5f3442',
   },
);
my @demo_inputs=(
   [neutral=>[]],
   [score_up=>['-holdjoy1','U']],
   [score_down=>['-holdjoy1','D']],
   [move_right=>['-holdjoy0','R']],
);
for my $kind (qw(above below)) {
   my $demo_source=File::Spec->catfile($repo,qw(examples 01_basic 14_heart_score),"heart_score_${kind}_interactive.c26");
   my $rom=File::Spec->catfile($tmp,"heart_score_${kind}_interactive.bin");
   ok("build heart score $kind composition",$driver,'-I',$vcs,$demo_source,'-o',$rom);
   -s $rom==4096 or die "heart score $kind composition is not a 4K ROM\n";
   for my $case (@demo_inputs) {
      my($label,$joy)=@$case;
      unlink glob("$snap/*.png");
      my $demo_user=File::Spec->catdir($tmp,"user_${kind}_${label}"); make_path($demo_user);
      my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
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
   [0,1,'0.5','320 x 228 b602f9750d4cfe22c587495f54ed231e71903a659faea0733587e6141011cfef'],
   [1,0,'1.0','320 x 228 bfd918d2ccc6bb2d56aeef63fdbb15a236ac0bf2c7926cac8bee2ea966070845'],
   [1,1,'1.5','320 x 228 fc8be92aab18f7b20f9d2f6526948699a97ba55637f2e22c549939a299f0eac3'],
   [2,0,'2.0','320 x 228 a438f06da3b5d876a136bebb78956a4af03fe8b512558eb57ab843108664a695'],
   [2,1,'2.5','320 x 228 f29aa8e23eb00b91b07747562c3a9bd640f545db04822c1aa5b9143c3a9986f3'],
   [3,0,'3.0','320 x 228 45c2ebd6f0c285ae9967c199b0495bed32286494c04aaf725fa7814d26578af9'],
);
my $below_source=File::Spec->catfile($repo,qw(examples 01_basic 14_heart_score),'heart_score_below_interactive.c26');
for my $case (@below_low) {
   my($score,$half,$label,$wanted)=@$case;
   my $rom=File::Spec->catfile($tmp,"heart_score_below_low_${score}_${half}.bin");
   ok("build bottom composition $label",$driver,'-I',$vcs,
      "-DHEART_SCORE_INITIAL_SCORE=$score","-DHEART_SCORE_INITIAL_HALF=$half",
      $below_source,'-o',$rom);
   unlink glob("$snap/*.png");
   my $low_user=File::Spec->catdir($tmp,"user_below_low_${score}_${half}"); make_path($low_user);
   my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
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
