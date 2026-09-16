#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# serial
# timeout: 300
# expectexit: 0
# Independently compare Stella snapshots for 4K, F8, and F8SC compositions.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my $e=gensym; my $p=open3(my $i,my $o,$e,@c); close($i); my $so=slurp_fh($o); my $se=slurp_fh($e); waitpid($p,0); return ($?>>8,$?&127,$so,$se); }
sub ok { my($label,@c)=@_; my($r,$s,$o,$e)=capture(@c); $r==0 && !$s or die "$label failed rc=$r sig=$s\n@c\n$o$e"; return($o,$e); }
sub findexe { my($n)=@_; return abs_path($n) if $n=~m{/} && -x$n; for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p} return undef; }
sub terminate { my($p)=@_; return unless $p; kill 'TERM',$p; for(1..20){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.05} kill 'KILL',$p;waitpid($p,0); }
@ARGV==2 or die "usage: $0 REPO TMP\n";
my $repo=abs_path($ARGV[0]) or die "resolve repo\n"; my $tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my $stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella') or die "set STELLA or VCSC_STELLA\n";
require File::Spec->catfile($repo,qw(test stella_test_lib.pl));
my $xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb') or die "Xvfb required\n"; my $perl=findexe('perl') or die "perl required\n";
my $keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl)); my $sequence=File::Spec->catfile($repo,qw(test stella_png_sequence.pl));
my $driver=File::Spec->catfile($repo,qw(driver vcsc)); my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(examples 07_diagnostics/bankswitching standard_renderer banked_standard_renderer.c26));
my $renderer=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc standard_4k_ntsc_renderer.s26));
my @runs=(['4k','4K',['-DUNBANKED_REFERENCE'],undef],['f8','F8',['-DMAPPER_BANKS=2'],1],['f8sc','F8SC',['-DMAPPER_BANKS=2','-DSUPERCHIP_TEST'],1]);
my %dig; my $display=130+($$%50);
for my $r(@runs){my($name,$mapper,$defs,$start)=@$r; my$rom=File::Spec->catfile($tmp,"$name.bin"); ok("build $name",$driver,'-I',$vcs,@$defs,$source,$renderer,'-o',$rom);
   $display++ while -e "/tmp/.X11-unix/X$display"; my$d=":$display"; $display++;
   my$xpid=fork(); defined$xpid or die"fork Xvfb\n"; if(!$xpid){open(STDOUT,'>:raw',"$tmp/$name.xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
   select undef,undef,undef,.2; local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null'; local$ENV{HOME}=$tmp; local$ENV{SDL_AUDIODRIVER}='dummy';
   my$snap=File::Spec->catdir($tmp,"snap_$name"); my$user=File::Spec->catdir($tmp,"user_$name"); make_path($snap,$user); unlink glob("$snap/*.png");
   my@cmd=($stella,vcsc_stella_palette_args($repo,$user),'-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','0','-speed','1','-uimessages','0','-audio.enabled','0','-bs',$mapper,'-snapsavedir',$snap,'-snapname','rom','-sssingle','0','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user); push@cmd,('-startbank',$start)if defined$start; push@cmd,$rom;
   my$pid=fork(); defined$pid or die"fork Stella\n"; if(!$pid){open(STDOUT,'>:raw',"$tmp/$name.stella.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
   ok("capture completed $name frames",$perl,$keys,'--fast','--every-frame',
      '--snapshot-dir',$snap,'--snapshot-count','20','--snapshot-timeout','20');
   my@png=sort grep{-s$_}glob("$snap/*.png"); terminate($pid);terminate($xpid);
   @png>=12 or die"$name produced only ".scalar(@png)." completed-frame snapshots\n";
   my($out,$err)=ok("stable digest $name",$perl,$sequence,'--stable-tail','8',@png); $err eq'' or die$err; chomp$out; $dig{$name}=$out;
}
$dig{f8} eq $dig{'4k'} or die "F8 Stella raster differs: $dig{f8} vs $dig{'4k'}\n";
$dig{f8sc} eq $dig{'4k'} or die "F8SC Stella raster differs: $dig{f8sc} vs $dig{'4k'}\n";
print "Stella standard renderer banked raster passed: $dig{'4k'}\n";
