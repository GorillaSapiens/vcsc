#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_example_vsync_contract ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find qw(find);
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
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return defined($d)?$d:'';
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $examples=File::Spec->catdir($repo,'examples');
my @direct;
find({no_chdir=>1,wanted=>sub {
   return unless -f $_ && /\.(?:c26|s26)\z/;
   my $p=$File::Find::name; my $t=read_file($p);
   # Catch source assignments and hand-written assembly stores to VSYNC ($00).
   # Deliberately ignore indexed $00,x/$00,y clear loops: those are bulk TIA
   # initialization, not frame generators.
   if ($t =~ /\bVSYNC\s*:=/ ||
       $t =~ /\bst[axy](?:\.[A-Za-z]+)?\s+(?:VSYNC|\$00)\b(?!\s*,)/i) {
      push @direct,File::Spec->abs2rel($p,$repo);
   }
}},$examples);
@direct=sort @direct;
my @expected=(
   'examples/01_basic/01_blank_screen/blank_screen.c26',
   'examples/01_basic/02_blank_noasm/blank_noasm.c26',
   'examples/01_basic/03_ode_to_joy/ode_to_joy.c26',
);
join("\n",@direct) eq join("\n",@expected)
   or die "direct example VSYNC writers changed:\n".join("\n",@direct)."\n";

my $asm=read_file(File::Spec->catfile($repo,split('/', $expected[0])));
$asm =~ /asm lda #2;\s*asm sta WSYNC;\s*asm sta VSYNC;\s*asm lda #0;\s*asm sta WSYNC;\s*asm sta WSYNC;\s*asm sta WSYNC;\s*asm sta VSYNC;/s
   or die "blank_screen lost exact same-phase VSYNC stores\n";
for my $rel (@expected[1,2]) {
   my $t=read_file(File::Spec->catfile($repo,split('/', $rel)));
   $t =~ /WSYNC\s*:=\s*2\s*;\s*VSYNC\s*:=\s*2\s*;\s*WSYNC\s*:=\s*0\s*;\s*WSYNC\s*:=\s*0\s*;\s*WSYNC\s*:=\s*0\s*;\s*VSYNC\s*:=\s*0\s*;/s
      or die "$rel lost exact same-phase VSYNC sequence\n";
}
for my $standard (qw(pal secam)) {
   my $root=File::Spec->catdir($examples,'17_video_standards',$standard);
   find({no_chdir=>1,wanted=>sub {
      return unless -f $_ && /\.c26\z/;
      my $t=read_file($File::Find::name);
      $t =~ /\bvcs_${standard}_vsync\s*\(\s*\)/
         or die "$File::Find::name does not use vcs_${standard}_vsync()\n";
      my @helpers=($t =~ /\bvcs_(ntsc|pal|secam)_vsync\s*\(\s*\)/g);
      for my $helper (@helpers) {
         $helper eq $standard or die "$File::Find::name mixes video-standard VSYNC helpers\n";
      }
   }},$root);
}

# Execute the lowest-level assembly example through the common timing harness,
# so its source-level exception is protected by a measured 228-cycle pulse
# and an actual 262-scanline assertion-to-assertion frame period.
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,split('/', $expected[0]));
my $bin=File::Spec->catfile($tmp,'blank_screen.bin');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$source,'-o',$bin);
$rc==0 && !$sig or die "blank_screen build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "blank_screen build wrote output\n$out$err";
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_frame_timing_vsync_contract');
($rc,$sig,$out,$err)=capture('c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "timing harness build failed\n$out$err";
$out eq '' && $err eq '' or die "timing harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($harness,$bin,'45','--no-audio','--raw-lines','262');
$rc==0 && !$sig or die "blank_screen timing failed\n$out$err";
$out eq "vcs_frame_timing ok: 42 frames at 262 lines, 1 AUDV0 writes\n"
   or die "unexpected blank_screen timing output: $out";
$err eq '' or die "blank_screen timing stderr: $err";

print "vcs_example_vsync_contract ok\n";
