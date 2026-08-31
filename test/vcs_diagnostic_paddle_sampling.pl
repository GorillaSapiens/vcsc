#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: diagnostic paddle sampling passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub run_capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=run_capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
}
sub read_file {
   my($p)=@_; open(my $fh,'<',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub map_symbol_addr {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n";
   return hex($1);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $example=File::Spec->catdir($repo,qw(examples 19_diagnostic 01_diagnostic));
my $source=File::Spec->catfile($example,'vcsc_diagnostic.c26');
my $boot=File::Spec->catfile($example,'diagnostic_boot.s26');
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $timing_source=File::Spec->catfile($repo,'test','vcs_frame_timing.cpp');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_diagnostic_paddles');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');

require_ok('compile diagnostic paddle timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic',
   '-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);

sub build_paddle_diag {
   my($tag,$tv)=@_;
   my $bin=File::Spec->catfile($tmp,"diagnostic-paddles-$tag.bin");
   my $map_path=File::Spec->catfile($tmp,"diagnostic-paddles-$tag.map");
   require_ok("build $tag paddle diagnostic",$driver,'-I',$vcs,'-I',$example,'-T',$generic,
      '-Wa,--illegals',"-DDIAGNOSTIC_TEST_TV=$tv",'-DDIAGNOSTIC_TEST_CONTROLLER=1',
      '-Map',$map_path,$source,$boot,'-o',$bin);
   my $map=read_file($map_path);
   my @pos=map { map_symbol_addr($map,"diagnostic_paddles_position$_") } 0..3;
   for my $i (1..3) {
      $pos[$i]==$pos[0]+$i or die "diagnostic paddle positions are no longer contiguous\n";
   }
   return ($bin,$pos[0]);
}

my($ntsc,$position0)=build_paddle_diag('ntsc',0);

# Exhaustively check every equal NTSC threshold. These ordinary cases are a
# value oracle, so they use a short run with an explicit checked-frame floor;
# the historically timing-sensitive boundary and high-end phase cases retain
# full 45-frame soaks below. Keeping this loop serial avoids nested worker pools
# when the outer repository test runner is already using --jobs N.
for my $threshold (0..255) {
   my $lines=join(',',($threshold) x 4);
   require_ok("NTSC equal paddle threshold $threshold",$timing,$ntsc,'12','--no-audio',
      '--minimum-checked-frames','9','--raw-lines','264','--released-inputs',
      '--paddle-lines',$lines,
      '--expect-memory-equal',sprintf('0x%04x',$position0),'4');
}

# Keep a long soak on the old completion-phase boundary even though the full
# 0..255 sweep above uses the shorter multi-frame window.
for my $threshold (227,228,229) {
   my $lines=join(',',($threshold) x 4);
   require_ok("NTSC long equal paddle threshold $threshold",$timing,$ntsc,'45','--no-audio',
      '--raw-lines','264','--released-inputs','--paddle-lines',$lines,
      '--expect-memory-equal',sprintf('0x%04x',$position0),'4');
}


# The field failure first appears just above the displayed ~57 boundary, when a
# measurement can remain active into the next frame.  The old code alternated
# the phase of VBLANK/visible/overscan WSYNC writes depending on whether a
# channel completed, producing a stable frame count but a visibly jittering
# raster.  Exercise each paddle independently at threshold 270 (displayed 61)
# and pin the lifecycle-owned WSYNC phases on representative raster lines.
# The final scheduler-owned overscan alignment line is intentionally omitted:
# its phase is absorbed by the following fixed WSYNC before the next VSYNC.
for my $channel (0..3) {
   my @thresholds=(100,100,100,100);
   $thresholds[$channel]=270;
   require_ok("NTSC paddle $channel above-57 raster phase stability",$timing,$ntsc,'12','--no-audio',
      '--minimum-checked-frames','9','--raw-lines','264','--released-inputs',
      '--paddle-lines',join(',',@thresholds),
      '--require-stable-tia-write-phase','0x02','4',
      '--require-stable-tia-write-phase','0x02','5',
      '--require-stable-tia-write-phase','0x02','59',
      '--require-stable-tia-write-phase','0x02','123',
      '--require-stable-tia-write-phase','0x02','234',
      '--expect-memory',sprintf('0x%04x',$position0+$channel),'61');
}

# A real high-resistance paddle can remain below threshold for much longer than
# 255 scanlines. At about 380 scanlines the diagnostic's two-scanline elapsed
# scale reports 95. Before this regression, channel 1 completed inside the
# visible six-glyph setup and moved a GRP0 write by ten CPU cycles on alternating
# measurement frames even though total frame length remained 262. Exercise all
# four channels independently and require the visible GRP0 phase set to stay
# identical from frame to frame.
for my $channel (0..3) {
   my @thresholds=(100,100,100,100);
   $thresholds[$channel]=380;
   require_ok("NTSC paddle $channel high-end 95 phase stability",$timing,$ntsc,'45','--no-audio',
      '--raw-lines','264','--released-inputs','--paddle-lines',join(',',@thresholds),
      '--require-stable-tia-write-phase','0x1b','125',
      '--expect-memory',sprintf('0x%04x',$position0+$channel),'95');
}

for my $spec (['pal',1,314],['secam',2,314]) {
   my($tag,$tv,$raw)=@$spec;
   my($bin,$addr)=build_paddle_diag($tag,$tv);
   for my $threshold (0,16,64,128,255) {
      my $lines=join(',',($threshold) x 4);
      require_ok(uc($tag)." equal paddle threshold $threshold",$timing,$bin,'45','--no-audio',
         '--raw-lines',"$raw",'--released-inputs','--paddle-lines',$lines,
         '--expect-memory-equal',sprintf('0x%04x',$addr),'4');
   }
}

print "diagnostic paddle sampling passed\n";
