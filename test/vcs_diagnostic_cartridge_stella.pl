#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# serial
# timeout: 1200
# expectexit: 0
# Independent pinned-palette Stella raster certification for the public F4SC field diagnostic.
# This is part of the normal e2e suite; Stella and Xvfb are required test dependencies.
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use IPC::Open3;
use Time::HiRes qw(time);
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);
$|=1;

sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture {
   my(@c)=@_;
   my($ofh,$opath)=tempfile(); my($efh,$epath)=tempfile();
   my$p=fork(); defined$p or die "fork command: $!\n";
   if(!$p) {
      open(STDIN,'<','/dev/null') or die $!;
      open(STDOUT,'>&',$ofh) or die $!;
      open(STDERR,'>&',$efh) or die $!;
      exec @c; die "exec @c: $!\n";
   }
   close($ofh); close($efh);
   my$deadline=time()+45; my$status;
   while(1) {
      my$d=waitpid($p,WNOHANG);
      if($d==$p) { $status=$?; last; }
      if($d==-1) { $status=$?; last; }
      if(time()>=$deadline) {
         kill 'TERM',$p; select undef,undef,undef,.1; kill 'KILL',$p; waitpid($p,0);
         unlink($opath,$epath); die "command timed out after 45 seconds: @c\n";
      }
      select undef,undef,undef,.05;
   }
   open(my$o,'<:raw',$opath) or die$!; my$so=slurp_fh($o); close$o;
   open(my$e,'<:raw',$epath) or die$!; my$se=slurp_fh($e); close$e;
   unlink($opath,$epath);
   return($status>>8,$status&127,$so,$se);
}
sub ok { my($label,@c)=@_; my($r,$s,$o,$e)=capture(@c); $r==0&&!$s or die "$label failed rc=$r sig=$s\n@c\n$o$e"; return($o,$e); }
sub findexe { my($n)=@_; return abs_path($n) if $n=~m{/}&&-x$n; for(split(/:/,$ENV{PATH}//'')){my$p="$_/$n";return abs_path($p)if-x$p} return undef; }
sub terminate { my($p)=@_; return unless$p; kill 'TERM',$p; for(1..20){my$d=waitpid($p,WNOHANG);return if$d==$p||$d==-1;select undef,undef,undef,.05} kill 'KILL',$p;waitpid($p,0); }

@ARGV==2 or die "usage: $0 REPO TMP\n";
my$repo=abs_path($ARGV[0])or die"resolve repo\n"; my$tmp=$ARGV[1]; make_path($tmp); $tmp=abs_path($tmp);
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella')or die"set STELLA or VCSC_STELLA\n";
require File::Spec->catfile($repo,qw(test stella_test_lib.pl));
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb')or die"Xvfb required\n"; my$perl=findexe('perl')or die"perl required\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$example=File::Spec->catdir($repo,qw(examples 07_diagnostics field_diagnostic));
my$source=File::Spec->catfile($example,'vcsc_diagnostic.c26');
my$boot=File::Spec->catfile($example,'diagnostic_boot.s26');
my$keys=File::Spec->catfile($repo,qw(test stella_snapshot_keys.pl));
my$digest=File::Spec->catfile($repo,qw(test stella_png_rgb_digest.pl));

my%requested=map { $_=>1 } grep { length } split(/,/, $ENV{VCSC_STELLA_CASES}//'');
my%seen;
my$display=350+($$%30);
for my$standard (
   ['ntsc',0,'NTSC'],
   ['pal',1,'PAL'],
   ['secam',2,'SECAM'],
) {
   my($standard_name,$tv,$format)=@$standard;
   for my$controller (
      ['joystick',0,'JOYSTICK'],
      ['paddle',1,'PADDLES'],
      ['keypad',2,'KEYBOARD'],
      ['driving',3,'DRIVING'],
   ) {
      my($controller_name,$mode,$stella_controller)=@$controller;
      my$name="${standard_name}_${controller_name}";
      next if %requested && !$requested{$name};
      $seen{$name}=1;
      my$rom=File::Spec->catfile($tmp,"diagnostic-$name.bin");
      my$reference=File::Spec->catfile($repo,'test','fixtures','diagnostic',"reference_${name}_stella_pinned.png");
      -s$reference or die"missing Stella reference $reference\n";
      ok("build $name diagnostic",$driver,'-I',$vcs,'-I',$example,'-Wa,--illegals',"-DDIAGNOSTIC_TEST_TV=$tv","-DDIAGNOSTIC_TEST_CONTROLLER=$mode",'-DDIAGNOSTIC_TEST_TIA_FREEZE=1',$source,$boot,'-o',$rom);

      # A fresh private X server per case avoids stale SDL/X11 state after
      # repeatedly terminating Stella during the 12-screen matrix.
      $display++ while -e "/tmp/.X11-unix/X$display";
      my$d=":$display"; $display++;
      my$xpid=fork(); defined$xpid or die"fork Xvfb\n";
      if(!$xpid){open(STDOUT,'>:raw',"$tmp/$name.xvfb.log");open(STDERR,'>&STDOUT');exec($xvfb,$d,'-ac','-screen','0','1024x768x24');die$!}
      select undef,undef,undef,.2;
      local$ENV{DISPLAY}=$d; local$ENV{XAUTHORITY}='/dev/null';
      local$ENV{HOME}="$tmp/home-$name"; local$ENV{SDL_AUDIODRIVER}='dummy'; make_path($ENV{HOME});

      my$snap=File::Spec->catdir($tmp,"snap-$name"); my$user=File::Spec->catdir($tmp,"user-$name");
      make_path($snap,$user); unlink glob("$snap/*.png");
      my@cmd=($stella,vcsc_stella_palette_args($repo,$user),'-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0','-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0','-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1','-audio.enabled','0','-format',$format,
         '-bs','F4SC','-bc',$stella_controller,'-snapsavedir',$snap,'-snapname',$name,'-sssingle','1','-ss1x','1',
         '-exitlauncher','0','-confirmexit','0','-userdir',$user,$rom);
      my$pid=fork(); defined$pid or die"fork Stella\n";
      if(!$pid){open(STDOUT,'>:raw',"$tmp/$name.stella.log");open(STDERR,'>&STDOUT');exec@cmd;die$!}
      # Capture completed frames instead of an asynchronous F12 framebuffer.
      # The diagnostic updates live controller detail in phases, so require the
      # masked certification raster to settle for three complete frames.
      ok("snapshot $name diagnostic",$perl,$keys,'--fast','--every-frame',
         '--snapshot-dir',$snap,'--snapshot-count','10','--snapshot-timeout','20');
      my@png=sort grep{-s$_}glob("$snap/*.png");
      terminate($pid); terminate($xpid);
      @png>=10 or die"$name Stella produced only ".scalar(@png)." completed-frame snapshots\n";
      # The Stella launcher installs the pinned NTSC/PAL/SECAM user palette,
      # so all three standards are certified with exact RGB outside live rows.
      my@digest_mask=('--mask-rows','125-133','--mask-rows','138-146');
      my@tail_digest;
      for my$frame (@png[-3..-1]) {
         my($value,$err)=ok("$name stable completed-frame digest",$perl,$digest,@digest_mask,$frame);
         $err eq '' or die$err; chomp$value; push@tail_digest,$value;
      }
      $tail_digest[0] eq $tail_digest[1] && $tail_digest[1] eq $tail_digest[2]
         or die"$name diagnostic completed-frame tail is not stable: @tail_digest\n";
      my$actual_png=$png[-1];
      my($actual_row,$are)=ok("$name actual first lit row",$perl,$digest,'--first-lit-row',$actual_png);
      my($reference_row,$rre)=ok("$name reference first lit row",$perl,$digest,'--first-lit-row',$reference);
      $are eq ''&&$rre eq '' or die$are.$rre;
      $actual_row eq $reference_row
         or die"$name diagnostic/reference first-lit-row mismatch: actual=$actual_row reference=$reference_row";
      if ($name eq 'ntsc_joystick') {
         # P1's live row ends at x=173 with no controller input.  badpatch.patch
         # exposed a nondeterministic staging failure that emitted extra glyphs
         # to the right; keep this assertion outside the masked live-row digest.
         ok("$name P1 trailing blank",$perl,$digest,'--assert-dark-rect','174,121,220,126',$actual_png);
      }

      # The two controller-detail text rows are intentionally live input.
      # Pinning their exact pixels made the golden raster depend on when F12
      # happened to land relative to the phased UI refresh (driving mode was
      # especially visible).  Ignore only those rows; the controller heading,
      # switch rows, collision bitmap, and collision lanes remain pixel-exact.
      my($actual,$ae)=ok("$name actual digest",$perl,$digest,@digest_mask,$actual_png);
      my($wanted,$we)=ok("$name reference digest",$perl,$digest,@digest_mask,$reference);
      $ae eq ''&&$we eq '' or die$ae.$we;
      $actual eq $wanted or die"$name diagnostic Stella raster differs: actual=$actual reference=$wanted";
      print "ok $name\n";
   }
}
if(%requested) {
   my@unknown=grep { !$seen{$_} } sort keys %requested;
   die "unknown VCSC_STELLA_CASES entries: @unknown\n" if @unknown;
}
print "vcs diagnostic cartridge Stella raster passed for NTSC/PAL/SECAM\n";
