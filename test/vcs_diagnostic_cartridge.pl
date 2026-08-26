#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: diagnostic cartridge passed
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

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $example=File::Spec->catdir($repo,qw(examples 19_diagnostic 01_diagnostic));
my $source=File::Spec->catfile($example,'vcsc_diagnostic.c26');
my $indices=File::Spec->catfile($example,'diagnostic_pair_indices.c26');
my $pairs=File::Spec->catfile($example,'pairs_message.txt');
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');

my $src=read_file($source);
my $idx=read_file($indices);
my $msg=read_file($pairs);
$src =~ /DIAG_PAIR_CO.*DIAG_PAIR_LR/s &&
$src =~ /DIAG_PAIR_BAMP.*DIAG_PAIR_W_SPACE/s &&
$idx =~ /DIAG_PAIR_LR\s*:=\s*36,\s*\/\/ 'LR'/ &&
$idx =~ /DIAG_PAIR_BAMP\s*:=\s*37,\s*\/\/ 'B&'/ &&
$idx =~ /DIAG_PAIR_W_SPACE\s*:=\s*105,\s*\/\/ 'W '/ &&
$msg =~ /COLRB&/ && $msg =~ /W\s*$/
   or die "diagnostic COLOR/B&W labels are not pre-cooked as COLR and B&W\n";

$src =~ /bank4 void diagnostic_driving_vblank\(void\).*?diagnostic_left_drive_begin_frame\(\);.*?diagnostic_right_drive_begin_frame\(\);.*?diagnostic_left_drive_sample\(\);.*?diagnostic_right_drive_sample\(\);.*?diagnostic_drive_position0.*?diagnostic_drive_position1/s
   or die "diagnostic driving mode lost its once-per-frame VBLANK sample\n";
$src !~ /diagnostic_driving_overscan/
   or die "diagnostic driving mode must not sample again in overscan\n";

my $timing_source=File::Spec->catfile($repo,'test','vcs_frame_timing.cpp');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_diagnostic');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
require_ok('compile diagnostic frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic',
   '-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);

# Each frame consumes one SWCHA read per controller. Repeat the same Gray
# phase for the left/right pair, then advance through the real clockwise
# sequence 3 -> 1 -> 0 -> 2 -> 3 on successive frames. This reproduces the
# moving-wheel decoder paths that made the old multi-sample diagnostic unstable.
for my $spec (['NTSC',0,264],['PAL',1,314],['SECAM',2,314]) {
   my($name,$tv,$raw)=@$spec;
   my $tag=lc($name);
   my $bin=File::Spec->catfile($tmp,"diagnostic-$tag-sweep.bin");
   my $map=File::Spec->catfile($tmp,"diagnostic-$tag-sweep.map");
   require_ok("build $name diagnostic sweep",$driver,'-I',$vcs,'-I',$example,'-T',$generic,
      '-DDIAGNOSTIC_TEST_SWEEP=1',"-DDIAGNOSTIC_TEST_TV=$tv",'-Map',$map,$source,'-o',$bin);
   -s $bin==32768 or die "diagnostic is not a 32K F4SC image\n";
   my($out,$err)=require_ok("$name moving driving timing",$timing,$bin,'130','--no-audio',
      '--raw-lines',"$raw",'--released-inputs','--read-sequence','0x280',
      '0x33,0x33,0x11,0x11,0x00,0x00,0x22,0x22');
   $out =~ /^vcs_frame_timing ok:/
      or die "unexpected $name moving-driving timing result:\n$out";
   $err eq '' or die "$name moving-driving timing wrote stderr:\n$err";
}

print "diagnostic cartridge passed\n";
