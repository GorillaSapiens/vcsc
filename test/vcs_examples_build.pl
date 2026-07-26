#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub without_cartridge_usage {
   my($out)=@_; $out =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//; return $out;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $faithful_cfg=File::Spec->catfile($vcs,qw(kernels faithful_legacy_playercolors faithful_legacy_playercolors.cfg));
my @examples=(
   ['01_solid_color','solid_color.c26',[]],
   ['02_ode_to_joy','ode_to_joy.c26',[]],
   ['03_six_digit_score','six_digit_score.c26',[]],
   ['04_fingerprint','fingerprint.c26',['-Wa,--illegals']],
   ['05_faithful_legacy_static_test','faithful_legacy_static_test.c26',['-Wa,--illegals','-T',$faithful_cfg]],
   ['06_static_kernel_test','static_kernel_test.c26',[]],
   ['07_object_motion_test','object_motion_test.c26',[]],
   ['08_playercolor_static_test','playercolor_static_test.c26',[]],
   ['09_playercolor_motion_test','playercolor_motion_test.c26',[]],
   ['10_xy_motion','xy_motion.c26',[]],
);

for my $entry (@examples) {
   my($dir,$file,$extra)=@$entry;
   my $source=File::Spec->catfile($repo,'examples',$dir,$file);
   my $bin=File::Spec->catfile($tmp,"$dir.bin");
   my $map=File::Spec->catfile($tmp,"$dir.map");
   -f $source or die "missing editable example $source\n";
   my @cmd=($driver,'-I',$vcs,'-Map',$map,@$extra);
   # Kernel source operands must follow the C source. Move any trailing .s26
   # operand after the example while leaving compiler/linker options in place.
   my @kernel=grep { /\.s26\z/ } @cmd;
   @cmd=grep { !/\.s26\z/ } @cmd;
   push @cmd,$source,@kernel,'-o',$bin;
   my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$dir build failed\nstdout:\n$out\nstderr:\n$err";
   without_cartridge_usage($out) eq '' or die "$dir wrote unexpected stdout:\n$out";
   $err eq '' or die "$dir wrote stderr:\n$err";
   my $rom=read_file($bin);
   length($rom)==4096 or die "$dir produced ".length($rom)." bytes, expected 4096\n";
   my($nmi,$reset,$irq)=unpack('v3',substr($rom,0x0ffa,6));
   for my $v ($nmi,$reset,$irq) {
      $v>=0xf000 && $v<=0xffff or die sprintf("%s vector %04X is outside ROM\n",$dir,$v);
   }
}

print "vcs_examples_build ok: all ten editable examples compile and link\n";
