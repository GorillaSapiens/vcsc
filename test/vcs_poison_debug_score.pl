#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_poison_debug_score ok
# expectexit: 0

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
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return defined($d)?$d:'';
}
sub without_usage {
   my($s)=@_;
   $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $s;
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $component=File::Spec->catfile($vcs,qw(renderers poison_debug_score poison_debug_score.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures poison_debug_score standalone.c26));
my $bin=File::Spec->catfile($tmp,'poison_debug_score.bin');
my $mapfile=File::Spec->catfile($tmp,'poison_debug_score.map');
my $asm=File::Spec->catfile($tmp,'poison_debug_score.s26');

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "poison debug score build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "poison debug score build wrote output\n$out$err";
-s $bin == 4096 or die "poison debug score ROM is not 4096 bytes\n";
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-S',$source,'-o',$asm);
$rc==0 && !$sig or die "poison debug score assembly compile failed\n$out$err";
$out eq '' && $err eq '' or die "poison debug score assembly compile wrote output\n$out$err";

my $text=read_file($component);
$text =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*11/ or die "poison visible contract is not eleven lines\n";
$text =~ /TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*1/ or die "poison public-RAM contract is not one byte\n";
$text =~ /TEMPLATE_MODULE_RAM_BYTES\s*:=\s*1/ or die "poison module-RAM contract is not one byte\n";
$text =~ /uint8_t\s+TEMPLATE_exit_background\s*;/ or die "poison component is missing its background handoff byte\n";
for my $phase (qw(init vblank draw overscan)) {
   $text =~ /require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/
      or die "poison component is missing TEMPLATE_$phase\n";
}
$text !~ /\b(?:VSYNC|VBLANK|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT|CXCLR)\b\s*:=/
   or die "poison component takes forbidden scheduler/collision ownership\n";

my $generated=read_file($asm);
$generated =~ /; begin inline expansion poison_draw #\d+\n(.*?); end inline expansion poison_draw #\d+/s
   or die "generated poison draw expansion is missing\n";
my $draw=$1;
my $wsync=()=$draw =~ /^\s*sta\s+\$02\b/gm;
$wsync==11 or die "poison draw emits $wsync WSYNC stores; expected eleven\n";
$draw =~ /lda\s+#\$44\s+sta\s+\$09/s or die "poison draw does not select the red NTSC background\n";
for my $required (qw(04 05 06 07 09 0B 0C 10 11 1B 1C 20 21 22 23 24 25 26 2A)) {
   $draw =~ /\b(?:sta|stx|sty)\s+\$$required\b/i
      or die "poison draw does not write TIA register \$$required\n";
}
for my $preserved (qw(0D 0E 0F 12 13 14 1D 1E 1F)) {
   $draw !~ /\b(?:sta|stx|sty)\s+\$$preserved\b/i
      or die "poison draw writes preserved playfield/missile/Ball register \$$preserved\n";
}
$draw =~ /lda #0\s+sta \$22\s+sta \$23\s+sta \$24/s
   or die "poison HMOVE does not explicitly preserve missile and Ball motion\n";
$draw =~ /lda\.z poison_exit_background\s+sta \$09/s
   or die "poison draw does not restore the caller-selected background\n";
my $map=read_file($mapfile);
$map =~ /BSS\.__vcsc_object\$poison_exit_background\s+run=\$[0-9A-Fa-f]{4}\s+size=\$0001\b/
   or die "poison component does not allocate exactly one background byte\n";
$map !~ /\bpoison_(?:score|pointers|row|delayed|workspace)\b/
   or die "poison component unexpectedly allocated other instance RAM\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_frame_timing_poison');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "poison timing harness build failed\n$out$err";
$out eq '' && $err eq '' or die "poison timing harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($harness,$bin,'50','--no-audio','--raw-lines','262');
$rc==0 && !$sig or die "poison timing failed\n$out$err";
$out =~ /vcs_frame_timing ok: 47 frames at 262 lines/
   or die "unexpected poison timing output: $out";
$err eq '' or die "poison timing stderr: $err";
print "vcs_poison_debug_score ok\n";
