#!/usr/bin/perl
# Authoritative Stella 7.0 raster certification for the heart-score component.
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
my @wanted=(
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

my $display=180+($$%50); $display++ while -e "/tmp/.X11-unix/X$display";
my $d=":$display";
my $xpid=fork(); defined$xpid or die "fork Xvfb\n";
if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2;
local $ENV{DISPLAY}=$d; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp; local $ENV{SDL_AUDIODRIVER}='dummy';
my $snap=File::Spec->catdir($tmp,'snap'); my$user=File::Spec->catdir($tmp,'user'); make_path($snap,$user);

for my $score (0..11) {
   my $rom=File::Spec->catfile($tmp,"heart_score_$score.bin");
   ok("build heart score $score",$driver,'-I',$vcs,"-DHEART_SCORE=$score",$source,'-o',$rom);
   unlink glob("$snap/*.png");
   my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
      '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
      '-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my $pid=fork(); defined$pid or die "fork Stella\n";
   if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_$score.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   ok("snapshot heart score $score",$perl,$keys);
   my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
   terminate($pid); @png==1 or die "Stella produced ".scalar(@png)." snapshots for score $score\n";
   my($actual,$ae)=ok("digest heart score $score",$perl,$digest,$png[0]);
   $ae eq '' or die $ae; chomp $actual;
   $actual eq $wanted[$score] or die "heart score $score raster differs: actual=$actual wanted=$wanted[$score]\n";
}
terminate($xpid);
print "vcs_heart_score_stella ok\n";
