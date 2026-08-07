#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: frame phase overlay ok: disjoint VBLANK/draw and overscan storage shares RAM while overlapping and unscoped lifetimes stay separate
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return($out,$err);
}
sub write_file {
   my($path,$text)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $text; close($fh) or die "close $path: $!\n";
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh> // ''; close($fh); return $text;
}
sub parse_layout_addr {
   my($map,$name)=@_;
   $map =~ /^\s+BSS\.__vcsc_object\$\Q$name\E\s+run=\$([0-9A-Fa-f]{4})\s+size=\$([0-9A-Fa-f]{4})/m
      or die "map missing $name object layout\n";
   return (hex($1),hex($2));
}
sub parse_symbol {
   my($text,$name)=@_; $text =~ /^\Q$name\E\s+([0-9A-Fa-f]{4})\s*$/m
      or die "symbol file missing $name\n"; return hex($1);
}
sub parse_dump {
   my($text)=@_; my @mem=(0)x65536;
   for my $line (split /\n/,$text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($count,$addr,$bytes)=(hex($1),hex($2),$3);
      length($bytes)==$count*2 or die "bad Intel HEX record\n";
      for my $i (0..$count-1) { $mem[$addr+$i]=hex(substr($bytes,$i*2,2)); }
   }
   return \@mem;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $cc1=File::Spec->catfile($repo,qw(compiler vcsc-cc1));
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));
my $inc=File::Spec->catdir($repo,'test');
my $cfg=File::Spec->catfile($repo,qw(test generic_6502.cfg));
my $src=File::Spec->catfile($tmp,'phase_overlay.c26');
my $component=File::Spec->catfile($tmp,'phase_component.c26');
my $asm=File::Spec->catfile($tmp,'phase_overlay.s26');
my $hex=File::Spec->catfile($tmp,'phase_overlay.hex');
my $mapfile=File::Spec->catfile($tmp,'phase_overlay.map');
my $sym=File::Spec->catfile($tmp,'phase_overlay.sym');

write_file($component,<<'COMPONENT');
require inline void TEMPLATE_init(void) {
   // Access-phase metadata alone is not enough: these objects explicitly
   // promise that prior-frame contents are disposable outside their inferred
   // phase intervals. Compiler-owned scratch gets this eligibility marker
   // automatically.
   asm __phaseworkspace$V1$prep = 0;
   asm .export __phaseworkspace$V1$prep;
   asm __phaseworkspace$V1$after_draw = 0;
   asm .export __phaseworkspace$V1$after_draw;
   asm __phaseworkspace$V1$overlap = 0;
   asm .export __phaseworkspace$V1$overlap;
   asm __phaseworkspace$V1$spanning = 0;
   asm .export __phaseworkspace$V1$spanning;
   asm __phaseworkspace$V1$middle = 0;
   asm .export __phaseworkspace$V1$middle;
}
require inline void TEMPLATE_vblank(void) {
   // Inline assembly references must contribute to the same phase proof as
   // high-level reads and writes.
   asm lda #$11;
   asm sta prep;
   asm lda #$12;
   asm sta prep+1;
   overlap[0] := 0x21;
}
require inline void TEMPLATE_draw(void) {
   asm lda prep;
   asm cmp #$11;
   asm bne @bad;
   asm lda prep+1;
   asm cmp #$12;
   asm beq @ok;
   asm @bad:;
   status := 1;
   asm @ok:;
   overlap[1] := 0x22;
   middle[0] := 0x77;
}
require inline void TEMPLATE_overscan(void) {
   after_draw[0] := 0x31;
   after_draw[1] := 0x32;
   overlap[2] := 0x23;
   unmarked_phase[0] := 0x66;
   spanning[1] := 0x88;
   if (after_draw[0] != 0x31 || after_draw[1] != 0x32 || unmarked_phase[0] != 0x66) { status := 2; }
}
COMPONENT

write_file($src,<<'SRC');
include "machine_6502.c26"
// Deliberately declare the smaller after-draw object first. The linker must
// prove lifetime compatibility rather than depending on declaration order.
uint8_t after_draw[4];
uint8_t overlap[4];
uint8_t prep[8];
uint8_t always_live[4];
uint8_t fake_draw_only[4];
uint8_t unmarked_phase[4];
uint8_t spanning[4];
uint8_t middle[4];
uint8_t status;

template "phase_component.c26" as game

void vcs_ntsc_vsync(void) {
   spanning[0] := 0x99;
}

void unrelated_draw(void) {
   // A suffix alone is not a lifetime contract. This ordinary function must
   // remain unscoped despite ending in _draw.
   fake_draw_only[0] := 0x55;
}
void simulator_done(void) { while (1) {} }
void main(void) {
   status := 0;
   always_live[0] := 0x44;
   unrelated_draw();
   vcs_ntsc_vsync();
   game_init();
   game_vblank();
   game_draw();
   game_overscan();
   if (status == 0) { status := 0xaa; }
   asm jmp simulator_done;
}
SRC

require_ok('compile phase metadata',$cc1,'-quiet','-I',$inc,'-I',$tmp,$src,'-o',$asm);
my $assembly=read_file($asm);
for my $expected (
   '__phaseuse$V1$M02$prep',
   '__phaseuse$V1$M04$prep',
   '__phaseuse$V1$M04$overlap',
   '__phaseuse$V1$M08$overlap',
   '__phaseuse$V1$M08$after_draw',
   '__phaseuse$V1$M00$always_live',
   '__phaseuse$V1$M00$fake_draw_only',
   '__phaseuse$V1$M08$unmarked_phase',
   '__phaseuse$V1$M01$spanning',
   '__phaseuse$V1$M08$spanning',
   '__phaseuse$V1$M04$middle',
   '__phaseworkspace$V1$prep',
   '__phaseworkspace$V1$after_draw',
   '__phaseworkspace$V1$overlap',
   '__phaseworkspace$V1$spanning',
   '__phaseworkspace$V1$middle') {
   index($assembly,$expected)>=0 or die "compiler phase metadata missing $expected\n";
}

require_ok('link phase overlay',$driver,'-I',$inc,'-I',$tmp,'-T',$cfg,'-Map',$mapfile,'-Sym',$sym,$src,'-o',$hex);
my $map=read_file($mapfile);
my($prep,$prep_size)=parse_layout_addr($map,'prep');
my($overlap,$overlap_size)=parse_layout_addr($map,'overlap');
my($after,$after_size)=parse_layout_addr($map,'after_draw');
my($always,$always_size)=parse_layout_addr($map,'always_live');
my($unmarked,$unmarked_size)=parse_layout_addr($map,'unmarked_phase');
my($spanning,$spanning_size)=parse_layout_addr($map,'spanning');
my($middle,$middle_size)=parse_layout_addr($map,'middle');
$prep_size==8 && $overlap_size==4 && $after_size==4 && $always_size==4 &&
   $unmarked_size==4 && $spanning_size==4 && $middle_size==4
   or die "phase fixture object sizes changed\n";
$after==$prep or die sprintf("disjoint overscan storage did not overlay prep: %04X vs %04X\n",$after,$prep);
$overlap!=$prep or die "draw+overscan object incorrectly overlaid VBLANK+draw object\n";
$always!=$prep && $always!=$overlap
   or die "unscoped main-lifetime object incorrectly phase-overlaid\n";
$unmarked!=$prep && $unmarked!=$after
   or die "phase-confined object without workspace eligibility incorrectly overlaid\n";
$spanning!=$middle
   or die "noncontiguous VSYNC+overscan uses were not conservatively closed across the frame\n";
$map =~ /^\s+BSS\.__vcsc_object\$spanning\s+[^\n]*\bphase=\$0F\b/m
   or die "VSYNC+overscan phase interval did not close to the full frame\n";

my $symbols=read_file($sym);
my $done=parse_symbol($symbols,'simulator_done');
my $status=parse_symbol($symbols,'status');
my($dump,$simerr)=require_ok('simulate phase overlay',$sim,'-T',$cfg,
   sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$hex);
$simerr eq '' or die "simulator wrote stderr:\n$simerr";
my $mem=parse_dump($dump);
$mem->[$status]==0xaa
   or die sprintf("phase overlay runtime status is %02X, expected AA\n",$mem->[$status]);

print "frame phase overlay ok: disjoint VBLANK/draw and overscan storage shares RAM while overlapping and unscoped lifetimes stay separate\n";
