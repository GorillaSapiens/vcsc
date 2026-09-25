#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# serial
# timeout: 300
# expectstdout: Stella all-five stripes 192 equivalence passed
# expectexit: 0
# Required pinned-palette Stella raster certification for the positive-stripe
# all-five kernel.  The reviewed fixture deliberately uses asymmetric PF1/PF2
# bytes; the simulator companion independently locks all six PF write values.
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

@ARGV==2 or die "usage: $0 REPO TMP\n";
my$repo=abs_path($ARGV[0])or die"resolve repo\n"; my$tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella')or die"set STELLA or VCSC_STELLA\n";
require File::Spec->catfile($repo,qw(test stella_test_lib.pl));
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb')or die"Xvfb required\n"; my$perl=findexe('perl')or die"perl required\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc)); my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl)); my$digest=File::Spec->catfile($repo,qw(test stella_png_rgb_digest.pl));

my$display=250+($$%20); $display++ while-e"/tmp/.X11-unix/X$display"; my$d=":$display";
my$xpid=fork(); defined$xpid or die"fork Xvfb\n"; if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2; local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{HOME}=$tmp; local$ENV{SDL_AUDIODRIVER}='dummy';

sub build_rom { my($name,$src)=@_; my$rom=File::Spec->catfile($tmp,"$name.bin"); ok("build $name",$driver,'-I',$vcs,$src,'-o',$rom); return$rom; }
sub snapshot_digest {
   my($name,$rom)=@_; my$snap=File::Spec->catdir($tmp,"snap_$name"); my$user=File::Spec->catdir($tmp,"user_$name"); remove_tree($snap,$user); make_path($snap,$user);
   my@cmd=($stella,vcsc_stella_palette_args($repo,$user),'-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0','-bs','4K','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
   my$pid=fork(); defined$pid or die"fork Stella\n"; if(!$pid){open(STDOUT,'>:raw',"$tmp/stella_$name.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   select undef,undef,undef,.4; ok("snapshot $name",$perl,$keys); my@png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05} terminate($pid); @png==1 or die"$name produced ".scalar(@png)." snapshots\n";
   my($dg,$de)=ok("digest $name",$perl,$digest,$png[0]); $de eq'' or die$de; chomp$dg; return$dg;
}

my$candidate=build_rom('candidate',File::Spec->catfile($repo,qw(test fixtures all_five_stripes_192 stella_match.c26)));
my$actual=snapshot_digest('candidate',$candidate);
my$expected='320 x 228 33e500f0df3b1990d7227cc6d3ec791c5544b92a72a3e80529f5e17c2b062631';
$actual eq $expected or die"stripe Stella raster changed\nactual=$actual\nexpected=$expected\n";
terminate($xpid);
print "Stella all-five stripes 192 equivalence passed\n";
