#!/usr/bin/perl
# Optional independent Stella 7.0 raster certification for the faithful
# unbanked/non-Superchip multisprite diagnostic.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_fh { my($f)=@_; local $/; return <$f>//''; }
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
my $profile=File::Spec->catdir($vcs,qw(renderers faithful_legacy_multisprite));
my $source=File::Spec->catfile($repo,qw(examples 10_faithful_legacy_multisprite 01_diagnostic faithful_legacy_multisprite_diagnostic.c26));
my $fixture=File::Spec->catfile($repo,qw(examples 10_faithful_legacy_multisprite 01_diagnostic faithful_legacy_multisprite_diagnostic_data.s26));
my $renderer=File::Spec->catfile($profile,'faithful_legacy_multisprite_renderer.s26');
my $startup=File::Spec->catfile($profile,'faithful_legacy_multisprite_startup.s26');
my $reference=File::Spec->catfile($repo,qw(test fixtures faithful_legacy_multisprite reference_diagnostic_stella_7.0.png));
my $keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));
my $digest=File::Spec->catfile($repo,qw(test stella_png_rgb_digest.pl));
my $rom=File::Spec->catfile($tmp,'faithful_legacy_multisprite_diagnostic.bin');
ok('build faithful multisprite diagnostic',$driver,'-nostdlib','-I',$vcs,'-Wa,--illegals',
   '-T',$cfg,$source,$fixture,$renderer,$startup,'-o',$rom);

my $display=250+($$%20); $display++ while -e "/tmp/.X11-unix/X$display";
my $d=":$display";
my $xpid=fork(); defined$xpid or die "fork Xvfb\n";
if(!$xpid){open(STDOUT,'>:raw',"$tmp/xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
select undef,undef,undef,.2;
local $ENV{DISPLAY}=$d; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp; local $ENV{SDL_AUDIODRIVER}='dummy';
my $snap=File::Spec->catdir($tmp,'snap'); my$user=File::Spec->catdir($tmp,'user'); make_path($snap,$user); unlink glob("$snap/*.png");
my @cmd=($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','4K',
   '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
   '-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
my $pid=fork(); defined$pid or die "fork Stella\n";
if(!$pid){open(STDOUT,'>:raw',"$tmp/stella.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
ok('snapshot faithful multisprite diagnostic',$perl,$keys);
my @png; for(1..40){@png=grep{-s$_}glob("$snap/*.png");last if@png==1;select undef,undef,undef,.05}
terminate($pid); terminate($xpid); @png==1 or die "Stella produced ".scalar(@png)." snapshots\n";
my($actual,$ae)=ok('actual digest',$perl,$digest,$png[0]); my($wanted,$we)=ok('reference digest',$perl,$digest,$reference);
$ae eq ''&&$we eq '' or die $ae.$we; $actual eq $wanted or die "faithful multisprite Stella raster differs: actual=$actual reference=$wanted";
chomp $actual; print "Stella faithful multisprite raster passed: $actual\n";
