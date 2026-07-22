#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out); my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($? >> 8,$? & 127,$stdout,$stderr);
}
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not read $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub require_re {
   my ($text,$re,$why)=@_;
   $text =~ $re or die "$why\n";
}
sub map_symbol {
   my ($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $profile=File::Spec->catdir($vcs,'kernels','standard_4k_ntsc');
my $example=File::Spec->catdir($repo,'examples','05_static_kernel_test');
my $source=File::Spec->catfile($example,'static_kernel_test.c26');
my $kernel=File::Spec->catfile($profile,'standard_4k_ntsc_kernel.s');
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $bin=File::Spec->catfile($tmp,'static_kernel_test.bin');
my $mapfile=File::Spec->catfile($tmp,'static_kernel_test.map');
my $phase_source=File::Spec->catfile($repo,'test','vcs_playfield_phase.cpp');
my $phase_exe=File::Spec->catfile($tmp,'vcs_playfield_phase');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');

my ($exit,$sig,$out,$err)=run_capture(
   $driver,'-I',$vcs,'-Wa,--illegals','-T',$cfg,'-Map',$mapfile,
   $source,$kernel,'-o',$bin);
$exit == 0 && !$sig
   or die "static-kernel build failed: exit=$exit signal=$sig\nstdout:\n$out\nstderr:\n$err";
$out eq '' or die "static-kernel build wrote stdout:\n$out";
$err eq '' or die "static-kernel build wrote stderr:\n$err";

my $rom=read_file($bin);
length($rom)==4096 or die "static-kernel cartridge is not 4096 bytes\n";
my ($nmi,$reset,$irq)=unpack('v3',substr($rom,0x0ffa,6));
$reset==0xf000 or die sprintf("RESET vector is %04X, expected F000\n",$reset);
for my $v ($nmi,$irq) {
   $v>=0xf000 && $v<=0xffff or die sprintf("vector %04X lies outside cartridge ROM\n",$v);
}

my $map=read_file($mapfile);
require_re($map,qr/^\s*KERNEL_CODE\s+load=\$F300\s+size=\$0300\b/m,
   'kernel code is not fixed at the page-aligned F300..F5FF window');
require_re($map,qr/^\s*KERNEL_RODATA\s+load=\$F600\s+size=\$0058\b/m,
   'score table is not fixed at the page-aligned F600 window');
require_re($map,qr/region=RAM\s+depth=2\s+bytes=\$0006\s+physical=\$00FA-\$00FF\s+extra=\$0002/,
   'map lost the standard kernel hidden-stack allowance');
map_symbol($map,'vcs_standard_kernel_drawscreen')==0xf300
   or die "standard kernel entry moved from F300\n";
map_symbol($map,'vcs_standard_score_table')==0xf600
   or die "score table moved from F600\n";
my $playfield=map_symbol($map,'vcs_standard_playfield');
$playfield==0xf154
   or die sprintf("ROM playfield landed at %04X instead of deliberate timing-safe F154\n",$playfield);
($playfield & 0xff)>=0x54 && ($playfield & 0xff)<=0xd0
   or die "ROM playfield lies outside the retained timing-safe low-byte window\n";

my $src=read_file($source);
require_re($src,qr/const\s+uint8_t\s+vcs_standard_playfield\s*\[48\]/,
   'test playfield is no longer immutable cartridge data');
require_re($src,qr/vcs_standard_score\s*:=\s*123456\s*;/,
   'static score is no longer 123456');
require_re($src,qr/COLUBK\s*:=\s*0x84\s*;/,
   'static scene lost its medium-blue background');
require_re($src,qr/COLUPF\s*:=\s*0x2e\s*;/,
   'static scene lost its gold playfield');
require_re($src,qr/CTRLPF\s*:=\s*1\s*;/,
   'static scene no longer selects the reflected asymmetric-playfield timing mode');
require_re($src,qr/vcs_standard_score_color\s*:=\s*0x0e\s*;/,
   'static scene lost its white score');
for my $name (qw(PLAYER0 PLAYER1 MISSILE0 MISSILE1 BALL)) {
   require_re($src,qr/VCS_STANDARD_\Q$name\E_X\s*:=/,
      "static scene no longer positions $name");
}
require_re($src,qr/while\s*\(1\)\s*\{\s*vcs_standard_kernel_drawscreen\(\);\s*\}/s,
   'static scene is no longer a deterministic kernel-only loop');

# Lock the imported zero-page addends used by the six-digit score pipeline.
my $kernel_bytes=substr($rom,0x300,0x300);
for my $pattern (
   "\xB1\x9F", "\xB3\xA1", "\xB3\xA3",
   "\xB1\xA5", "\xB1\xA7", "\xB1\xA9") {
   index($kernel_bytes,$pattern)>=0
      or die sprintf("kernel is missing score-pointer opcode bytes %s\n",unpack('H*',$pattern));
}
index($kernel_bytes,"\xAB")>=0 or die "kernel lost retained LAX immediate opcode\n";
index($kernel_bytes,"\x4B")>=0 or die "kernel lost retained ASR opcode\n";
index($kernel_bytes,"\xCB")>=0 or die "kernel lost retained SBX opcode\n";

my $kernel_text=read_file($kernel);
require_re($kernel_text,qr/^\s*lda\s+#37\+128\s*$/m,
   'kernel no longer contains the Stella-verified 262-line timer value');
require_re($kernel_text,qr/\.align 256\s+\@kerloop:/s,
   'hot playfield loop is not pinned to a page boundary');

my $cxx=$ENV{CXX} || 'c++';
($exit,$sig,$out,$err)=run_capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos_dir,$phase_source,$mos_source,'-o',$phase_exe);
$exit == 0 && !$sig
   or die "playfield-phase harness build failed: exit=$exit signal=$sig\nstdout:\n$out\nstderr:\n$err";
$out eq '' or die "playfield-phase harness build wrote stdout:\n$out";
($exit,$sig,$out,$err)=run_capture($phase_exe,$bin);
$exit == 0 && !$sig
   or die "playfield-phase verification failed: exit=$exit signal=$sig\nstdout:\n$out\nstderr:\n$err";
$out =~ /^vcs_playfield_phase ok: \d+ scanlines at cycles 24,31,38,45\n$/
   or die "unexpected playfield-phase output:\n$out";
$err eq '' or die "playfield-phase verifier wrote stderr:\n$err";

print "vcs_static_kernel_test ok\n";
