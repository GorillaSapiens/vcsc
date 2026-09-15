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
my $line_source=File::Spec->catfile($repo,qw(test fixtures heart_score lines.c26));
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

my @wanted_lines=(
'320 x 228 62a828766ef7260961fdc0afd07273891f0dfa11cced7a96b54e0e2a01464d45',
'320 x 228 5315350d47938c0b1ebcd8e271be532c60b921bd94d542d0ad1803667f967b4c',
'320 x 228 8287ef17c47e4b068371feda948228bd15c8b4762f861636f8e059a711258366',
'320 x 228 a09609f4cac61a61641a4b18f9e32c099ca801754849eb6923bf0c066741ae3e',
'320 x 228 d06a50a72af9d201e8f17a6bd8364ea0309a43dbf719aa028e9dff35992d698a',
'320 x 228 2611c21075fcd6f54ac3dc81aab34b79bb21f6830eaeab0f253e284ade66289e',
'320 x 228 672a0a0152f3c05744b3c563d9f1548b4fc2204c36bd5855e73a4f3312b6e76e',
'320 x 228 b6b83c6543dff76a1b8acf941bb62a4c7ec3529191da0ee165eaacfb2d803e84',
'320 x 228 536c4e5311383d0af969bea5cd751452fb39010ef178b50d3dcedbc280c1c5c6',
'320 x 228 7b94550877141054e07fdf22107a1093068b82962b6929245f6bc5e1bec88336',
'320 x 228 e0314a4bce3558cff4d555e16b3dfd45f4fb29833f0de09937b8d54fcd214507',
'320 x 228 9197e1098213f5fbd592a1abcdc6c9749ae7c5db474d6b1b60e8ad5c2305d2b7'
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
   my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
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
      neutral=>'320 x 228 8e6a0911a09179774b8dcbeb5ba13fb7b8eb21ddcf5da57d7c5fea9cf58d86ba',
      score_up=>'320 x 228 174f265af3bc63a35370eaf2d2f5eec7eb51705bd22c186678ff24c1d9a50ee2',
      score_down=>'320 x 228 953eeb5b84f71eff832f98aeaf76b403126973f259f384002840ea028afa3b7c',
      lines_down=>'320 x 228 f176dd46c61ea77d9f59e2bc29adbe8f0a4ad29db00e7065812ac76c81c5c7c0',
      lines_up=>'320 x 228 48ebc35ab9bfdd974268f8ec3d07af12f54d15125eb3d24d4b47258e5b73d511',
      move_right=>'320 x 228 a2c3bdb7b1c17e8585826fa4432b8ec1a5949ce83609613a9a0e046502c6910c',
   },
   below=>{
      neutral=>'320 x 228 a72a00cb44acce3b895aa38ddb201c0bf8bc4e1ca0af10612dfa0667f1b94861',
      score_up=>'320 x 228 b24b5119ec669f8ecc1e4a9d966988b5d1fbf0c089b9eaa6730c122ebca9e3f9',
      score_down=>'320 x 228 16fc703cebf3cf7273a653f585800b506dd95adcde1081969c3dba2df7dffeec',
      lines_down=>'320 x 228 a2dd1851c482df1aa3ccc6008a64f3e0430d8808e4f76ef160faf44de333a5ed',
      lines_up=>'320 x 228 e707ba6ef44f0fe51f4ebd2933cb2948338f28c0fe2119d65f9c7de321a5b5dc',
      move_right=>'320 x 228 15035ce398f0bf57c916fde1a69e4d1c6201cc1d3f84b34a9c8be5bb1cbc60ae',
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
   [0,1,'0.5','320 x 228 0a2f524431c634ccb4af0aa6b27cd1d97913f8d98c979291fe96dee0fcedd9c4'],
   [1,0,'1.0','320 x 228 ee0fc63e9b99fe4f3f5b514c0900585047f04354bb17ea7805b2d6d69c6a8252'],
   [1,1,'1.5','320 x 228 ab706c767ba8c11d2e92b26a4f4e592afe9b36ef53812089df1795bdf4c67904'],
   [2,0,'2.0','320 x 228 85e29f6f44708c4ea87e1de3716cfd180b7d1828dd9a43695a3746590fe49435'],
   [2,1,'2.5','320 x 228 1632b26a264bc83ccb06a3f2e19f1bb40fbddc0edb76dd6bb6a6d854b21f6a7d'],
   [3,0,'3.0','320 x 228 3c5f3543cafcd697abe6ad591c8232a078e32ae9ac49b82f2cb23160752ab014'],
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
      '--mask-rows','0-197','--mask-rows','204-227',$png[0]);
   $ae eq '' or die $ae; chomp $actual;
   $actual eq $wanted
      or die "bottom composition $label heart rows differ: actual=$actual wanted=$wanted\n";
}

terminate($xpid);
print "vcs_heart_score_stella ok\n";
