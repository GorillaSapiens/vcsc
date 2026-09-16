#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# serial
# timeout: 900
# expectexit: 0
# Authoritative pinned-palette Stella raster certification for the 0..11 heart-score component.
# This is part of the normal e2e suite; Stella and Xvfb are required.

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
my $stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella') or die "set STELLA or VCSC_STELLA\n";
require File::Spec->catfile($repo,qw(test stella_test_lib.pl));
my $xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb') or die "Xvfb required\n";
my $perl=findexe('perl') or die "perl required\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(test fixtures heart_score golden.c26));
my $line_source=File::Spec->catfile($repo,qw(test fixtures heart_score lines.c26));
my $keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));
my $digest=File::Spec->catfile($repo,qw(test stella_png_rgb_digest.pl));
my $sequence=File::Spec->catfile($repo,qw(test stella_png_sequence.pl));
my @wanted_full=(
'320 x 228 9c7cd035a63fe7b118918767c4a41828110d89645cd46870c1795b9de34762b3',
'320 x 228 aaa906c18e06f9eb7d074f0b747e03558c0e8e3707db965828f59354ae215a2a',
'320 x 228 c3f6fad94e0dbb720c8b08278a1f13851f88bcb0bce3c22214a677956a7dc169',
'320 x 228 f276027d3b2f75c14a08527bf80620534277e77eee60e4106ece31ad7e526313',
'320 x 228 a15a6ea0bc3cf0ef3a23e9d2ff9ba8458af8ee4835dec1aa6ab5c7c2366e1f2a',
'320 x 228 bb7e234f3e7a04367b3051481867a4f2b73c0578727f5c82c536882c90f0309b',
'320 x 228 480821fb5b502fee816776844613b0bedd4ebd3fb0e9395a1d078b12a52beacd',
'320 x 228 75e5cb85d3cb06f15b59a96eb0d0d0e09398809fe8b249a2c6dfa1acb0b76caf',
'320 x 228 ecd2bbcaf80531f9c23827def4d0ff8df412f121dd125d527b79614034698a0c',
'320 x 228 0b5474409bbd23f2c59b33fc163642f96f16b845c721a868678ec4a6cae5c93f',
'320 x 228 f62bd438ea247a1c67ba9b9a71bf19fa1c50f79d43b1c9ea64506e204ddbe738',
'320 x 228 919c73faf2e3ac6cf11e3400b601286f0f7c7160e29c458321a069a75755daaf',
);
my @wanted_half=(
'320 x 228 5f32ec8e36200455ad5b52e5349e57c4b3b5b5d547533ab7facbdcb3aa1e652b',
'320 x 228 84721393795db9c264e945a1a04e4c099900145e5e14fd5e57a6975cddad193a',
'320 x 228 cc2ecb7995dc850f79c46622500a842a97f02ce9793224d6ce6a038f2714c4b1',
'320 x 228 f66757e8576d83118482a88ed9938b4554046c6184e652ed5c74337e32b2a0db',
'320 x 228 84f54b182eba89e3668529125cbfee72aa290c6714a0cd99740876e2bca38118',
'320 x 228 3f735485112a9a15691f8ca278e5a988931fb0762c8dba4a43be45d5401434b0',
'320 x 228 16bcb28b99ae033ec56cf7c88f50a6c42f683ad0d4d6b2521e8dde212d7fd35d',
'320 x 228 a0532604450e9a3571ed9f6a8a42d18489e48a6eb3604b4ed9c003749431547d',
'320 x 228 0efe4d52c613b1222eca43b6433ae2ae6c25551bac418ed8a333e15413b98af2',
'320 x 228 5654d61d5c4f406ca1e3dd1ca04e1752572895cfd7db77259d79e7c5a22f02d4',
'320 x 228 5f5403c119c6ec1d2d00bb2791072af81bafe0e294b73cdfcdf8e014d2c3a62d',
'320 x 228 919c73faf2e3ac6cf11e3400b601286f0f7c7160e29c458321a069a75755daaf',
);

my @wanted_lines=(
'320 x 228 3f735485112a9a15691f8ca278e5a988931fb0762c8dba4a43be45d5401434b0',
'320 x 228 f9fd5c9f8a50a8c8c9c8d6418d1779d9338bd98a94cce7efccca3a455b16cab3',
'320 x 228 896c5d1ea01d675c76ddd8fadaf33b10285ec5bd5e86712da93c503b26b6ed06',
'320 x 228 c24eda3db1c1d3fad1976792ecc4131fa711880d298c997aab94759a6a024b63',
'320 x 228 fa0777092593a6fe74cf774f844d30e7417208858ab1c2e3d8650669e0f5cf5b',
'320 x 228 d483fea89b2fa4cecd46fcf7ca69e6efd17225a7634e6d63c452109e2731fd63',
'320 x 228 08b1246175f4e8709018c5584b75293a7e17eb444e676df7fa4b980751af1ea7',
'320 x 228 30956060ccc17f55e04cec5fb47d08ce7fcd4ce7f9db5cfdd3baf5e19cb3cec8',
'320 x 228 c09f428edc700be529b0b687bb5bd630e08dc11533d32b2454f4a74d4a4c32fc',
'320 x 228 23e56bcf71a1d515f8a3e0c976bfc85d98b88fd447c5bdb687e7c635a873767f',
'320 x 228 54b2e93dbeca416ae5c2db68abe12df4187a5598e47cd1b271031e0bba606d0b',
'320 x 228 c8ad60dab5d6a7ad89360bc39405af81a09c743821c481020c9bac361261d8e4',
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
      my @cmd=($stella,vcsc_stella_palette_args($repo,$user),'-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
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

# Compile-time-enabled marker certification. The heart state stays fixed at 5.5
# while the independent runtime marker count walks all twelve 0..11 prefixes.
# The hashes lock both top and bottom marker lines, the blank separation, and
# exact 8-pixel / 12-pixel-pitch alignment without changing the default heart
# profile above.
for my $lines (0..11) {
   my $rom=File::Spec->catfile($tmp,"heart_score_lines_${lines}.bin");
   ok("build heart line markers $lines",$driver,'-I',$vcs,"-DHEART_LINES=$lines",$line_source,'-o',$rom);
   unlink glob("$snap/*.png");
   my $line_user=File::Spec->catdir($tmp,"user_lines_${lines}"); make_path($line_user);
   my @cmd=($stella,vcsc_stella_palette_args($repo,$user),'-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
      '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
      '-exitlauncher','0','-confirmexit','0','-userdir',$line_user,$rom);
   my $pid=fork(); defined$pid or die "fork Stella\n";
   if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_lines_${lines}.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   ok("snapshot heart line markers $lines",$perl,$keys,'--fast');
   my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
   terminate($pid); @png==1 or die "Stella produced ".scalar(@png)." snapshots for line markers $lines\n";
   my($actual,$ae)=ok("digest heart line markers $lines",$perl,$digest,$png[0]);
   $ae eq '' or die $ae; chomp $actual;
   $actual eq $wanted_lines[$lines]
      or die "heart line markers $lines raster differs: actual=$actual wanted=$wanted_lines[$lines]\n";
}

# Composition certification: the real 181-line player-color renderer and the
# ten-line line-marker heart profile must coexist in either visible order.
# The initial 5.5 health / 8-marker state plus held right-joystick UP/DOWN locks
# one health transition in each direction (6.0 and 5.0), while LEFT/RIGHT locks
# one marker transition (7 and 9). Held left-joystick RIGHT locks real gameplay motion
# of the initially selected P0 so these cartridges cannot regress to static
# "interactive" demos again.
my %demo_wanted=(
   above=>{
      neutral=>'320 x 228 1389335a8e55df76bd622f95e91d177f9214c4cb8118cfef527dac69d7f245aa',
      score_up=>'320 x 228 1e769aa3a15696abbd4769cd5f0ac57726bff7d344307faee64d2773cd3460f5',
      score_down=>'320 x 228 9223e9789442e4bbe7d151edd1b1540521c2e69125153d88773f4082597c726c',
      lines_down=>'320 x 228 d6b06220ce708da14e3db3098e3e579b0811f26d71b3507b10f643d925f2bfbc',
      lines_up=>'320 x 228 550b63c1b2acf1ff2be11098893c6349a7cabbbccd0046fc3c55be28f264e195',
      move_right=>'320 x 228 6e1ea7f420b097a75a7155a28ad672d94c81009056f9547045157cebf9656373',
   },
   below=>{
      neutral=>'320 x 228 884d7a705fe3610575d7ddb0d1f94f67d68af50c38f0b373acd05802421132d7',
      score_up=>'320 x 228 0d305807f0c68bfbf48a1b19b03166f2c911fbedcd04e5957fe3ae02711f5b5f',
      score_down=>'320 x 228 9e9534a3cc703796ed8ceddb50031b64e92d44b54a171156ed1e748c2bd74d17',
      lines_down=>'320 x 228 4ad9f6d91271290bf90dc1de8ed38e2bc0ceb8ce3af9dfe9a08f800ea2e32f01',
      lines_up=>'320 x 228 ed8277d72289feccbf376655a43d80d708ec3c0f06de03c28154dce071c3599f',
      move_right=>'320 x 228 552137179d1db22cfee2f9474ba600e5e3457678b76af89eff3caf08f4f07365',
   },
);
my @demo_inputs=(
   [neutral=>[]],
   [score_up=>['-holdjoy1','U']],
   [score_down=>['-holdjoy1','D']],
   [lines_down=>['-holdjoy1','L']],
   [lines_up=>['-holdjoy1','R']],
   [move_right=>['-holdjoy0','R']],
);
for my $kind (qw(above below)) {
   my $demo_source=File::Spec->catfile($repo, qw(examples 04_renderers player_color), "score_${kind}", "heart", "heart_score_${kind}_interactive.c26");
   my $rom=File::Spec->catfile($tmp,"heart_score_${kind}_interactive.bin");
   ok("build heart score $kind composition",$driver,'-I',$vcs,$demo_source,'-o',$rom);
   -s $rom==4096 or die "heart score $kind composition is not a 4K ROM\n";
   for my $case (@demo_inputs) {
      my($label,$joy)=@$case;
      unlink glob("$snap/*.png");
      my $demo_user=File::Spec->catdir($tmp,"user_${kind}_${label}"); make_path($demo_user);
      my @cmd=($stella,vcsc_stella_palette_args($repo,$user),'-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
         @$joy,'-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
         '-exitlauncher','0','-confirmexit','0','-userdir',$demo_user,$rom);
      my $pid=fork(); defined$pid or die "fork Stella\n";
      if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_${kind}_${label}.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
      my $actual;
      if ($label eq 'move_right') {
         # RIGHT is intentionally held continuously.  A one-shot F12 can land
         # while P0 is still crossing the screen, so certify the completed-frame
         # endpoint after the public X clamp at 159 has settled.
         ok("snapshot heart score $kind $label",$perl,$keys,'--fast','--every-frame',
            '--snapshot-dir',$snap,'--snapshot-count','20','--snapshot-timeout','30');
         my @png=sort grep{-s$_}glob("$snap/*.png");
         terminate($pid); @png>=20 or die "Stella produced only ".scalar(@png)." completed frames for heart score $kind $label\n";
         my($stable,$se)=ok("stable heart score $kind $label endpoint",$perl,$sequence,'--stable-tail','3',@png);
         $se eq '' or die $se; chomp $stable; $actual=$stable;
      }
      else {
         ok("snapshot heart score $kind $label",$perl,$keys,'--fast');
         my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
         terminate($pid); @png==1 or die "Stella produced ".scalar(@png)." snapshots for heart score $kind $label\n";
         my($value,$ae)=ok("digest heart score $kind $label",$perl,$digest,$png[0]);
         $ae eq '' or die $ae; chomp $value; $actual=$value;
      }
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
   [0,1,'0.5','320 x 228 a31af16f6729922543c27ed54f6e8a19a0443423de240a72c880dee3fa7575fa'],
   [1,0,'1.0','320 x 228 a120a30ed6733b82fc56317eab7ef9efe7a4956dcfaf67589f973936acddcd2a'],
   [1,1,'1.5','320 x 228 ff5b87ca21836fefcc3ecb20a7c77e035900e176024151da9b599bef859e5e73'],
   [2,0,'2.0','320 x 228 bfbfe5afeccf50bd77b7151c77dfde3d1ec6c91e0603cc8f66d668a507a16a34'],
   [2,1,'2.5','320 x 228 7ca82beee088b1297d00d0ccbd894945286ca9c1dde68e9b003c30da10e063f9'],
   [3,0,'3.0','320 x 228 8518031d34ab5fe0112071b0b3918c1cfb18e9b6fc47e30a50684e3961149125'],
);
my $below_source=File::Spec->catfile($repo,qw(examples 04_renderers player_color score_below heart),'heart_score_below_interactive.c26');
for my $case (@below_low) {
   my($score,$half,$label,$wanted)=@$case;
   my $rom=File::Spec->catfile($tmp,"heart_score_below_low_${score}_${half}.bin");
   ok("build bottom composition $label",$driver,'-I',$vcs,
      "-DHEART_SCORE_INITIAL_SCORE=$score","-DHEART_SCORE_INITIAL_HALF=$half",
      $below_source,'-o',$rom);
   unlink glob("$snap/*.png");
   my $low_user=File::Spec->catdir($tmp,"user_below_low_${score}_${half}"); make_path($low_user);
   my @cmd=($stella,vcsc_stella_palette_args($repo,$user),'-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
      '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
      '-exitlauncher','0','-confirmexit','0','-userdir',$low_user,$rom);
   my $pid=fork(); defined$pid or die "fork Stella\n";
   if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_below_low_${score}_${half}.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   ok("snapshot bottom composition $label",$perl,$keys,'--fast');
   my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
   terminate($pid); @png==1 or die "Stella produced ".scalar(@png)." snapshots for bottom composition $label\n";
   my($actual,$ae)=ok("digest bottom composition $label",$perl,$digest,
      '--mask-rows','0-197','--mask-rows','204-227',$png[0]);
   $ae eq '' or die $ae; chomp $actual;
   $actual eq $wanted
      or die "bottom composition $label heart rows differ: actual=$actual wanted=$wanted\n";
}

terminate($xpid);
print "vcs_heart_score_stella ok\n";
