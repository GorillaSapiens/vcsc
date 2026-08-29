#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_blank_noasm ok: timer-owned blanking and X-backed visible countdown preserve exact 262-line frames
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh) or die "could not close $path: $!\n";
   return defined($d)?$d:'';
}
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($?>>8,$?&127,$stdout,$stderr);
}
sub without_cartridge_usage {
   my ($out)=@_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $source=File::Spec->catfile($repo,qw(examples 01_basic 02_blank_noasm blank_noasm.c26));
my $bin=File::Spec->catfile($tmp,'blank_noasm.bin');
my $asm=File::Spec->catfile($tmp,'blank_noasm.s26');
my $timing_source=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $timing_exe=File::Spec->catfile($tmp,'vcs_frame_timing_blank_noasm');
my $mos_dir=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');

my $text=read_file($source);
for my $count (192) {
   $text =~ /for\s*\(\s*uint8_t\s+i\s*:=\s*$count\s*;\s*i\s*;\s*i--\s*\)\s*\{\s*WSYNC\s*:=\s*_\s*;/s
      or die "blank_noasm no longer uses the X-backed $count-line source countdown\n";
}
$text !~ /for\s*\(\s*uint8_t\s+i\s*:=\s*(?:37|30)\s*;/
   or die "blank_noasm regressed to WSYNC-counted blanking\n";
$text =~ /WSYNC\s*:=\s*_\s*;\s*VSYNC\s*:=\s*2\s*;\s*WSYNC\s*:=\s*_\s*;\s*WSYNC\s*:=\s*_\s*;\s*WSYNC\s*:=\s*_\s*;\s*VSYNC\s*:=\s*0\s*;/s
   or die "blank_noasm lost exact same-phase VSYNC sequence\n";
$text =~ /TIM64T\s*:=\s*42\s*;/ && $text =~ /TIM64T\s*:=\s*34\s*;/
   or die "blank_noasm lost calibrated VBLANK/overscan TIM64T deadlines\n";
$text =~ /TIM64T\s*:=\s*42\s*;.*?while\s*\(\s*!\s*\(\s*TIMINT\s*&\s*0x80\s*\)\s*\).*?WSYNC\s*:=\s*_\s*;\s*VBLANK\s*:=\s*0\s*;/s
   or die "blank_noasm lost timer-owned VBLANK deadline/alignment\n";
$text =~ /TIM64T\s*:=\s*34\s*;.*?while\s*\(\s*!\s*\(\s*TIMINT\s*&\s*0x80\s*\)\s*\).*?WSYNC\s*:=\s*_\s*;.*?WSYNC\s*:=\s*_\s*;/s
   or die "blank_noasm lost Stella-calibrated timer-owned overscan tail\n";
my @timer_waits=($text =~ /while\s*\(\s*!\s*\(\s*TIMINT\s*&\s*0x80\s*\)\s*\)/g);
@timer_waits == 2 or die "blank_noasm must wait on TIMINT in both blanking phases\n";
$text !~ /\basm\b/
   or die "blank_noasm contains inline assembly\n";

my ($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,$source,'-o',$bin);
die "blank_noasm build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
$out =~ /\brom\s+used=(\d+)\s+bytes/ or die "blank_noasm build did not report ROM usage\n$out";
my $rom_used=$1;
$rom_used <= 520 or die "blank_noasm uses $rom_used ROM bytes; timer-demo budget is 520\n";
$out =~ /\bram\s+used=(\d+)\s+bytes/ or die "blank_noasm build did not report RAM usage\n$out";
$1 == 11 or die "blank_noasm uses $1 RAM bytes; expected 11 with compact startup and one real call slot\n";
die "blank_noasm build wrote unexpected output\nstdout:\n$out\nstderr:\n$err"
   if without_cartridge_usage($out) ne '' || $err ne '';

($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-S',$source,'-o',$asm);
die "blank_noasm compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "blank_noasm compile wrote output\nstdout:\n$out\nstderr:\n$err" if $out ne '' || $err ne '';
my $asm_text=read_file($asm);
my @counts=($asm_text =~ /\bldx #\$([0-9a-fA-F]{2})\s+\@for_start_\d+:\s+sta\s+\$02\s+\@for_step_\d+:\s+dex\s+bne \@for_start_\d+/sg);
@counts == 1 && join(',',map { lc($_) } @counts) eq 'c0'
   or die "blank_noasm visible countdown did not lower to the expected X loop\n";
$asm_text =~ /lda #\$2a\s+sta\s+\$0296.*?lda\s+\$0285\s+and #\$80\s+beq/s
   or die "blank_noasm VBLANK timer did not lower to TIM64T/TIMINT polling\n";
$asm_text =~ /lda #\$22\s+sta\s+\$0296.*?lda\s+\$0285\s+and #\$80\s+beq/s
   or die "blank_noasm overscan timer did not lower to TIM64T/TIMINT polling\n";
$asm_text !~ /\bmain\$i\b/
   or die "blank_noasm materialized the X-backed loop index in RAM\n";

($exit,$sig,$out,$err)=run_capture(
   'g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-DILLEGAL_OPCODES',
   '-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing_exe);
die "timing harness compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "timing harness compile wrote output\nstdout:\n$out\nstderr:\n$err" if $out ne '' || $err ne '';

($exit,$sig,$out,$err)=run_capture($timing_exe,$bin,'45','--no-audio','--raw-lines','264');
die "timing harness exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
$out eq "vcs_frame_timing ok: 42 frames at 262 lines, 1 AUDV0 writes\n"
   or die "blank_noasm lost exact frame timing: $out";
$err eq '' or die "timing harness stderr: $err";

print "vcs_blank_noasm ok: timer-owned blanking and X-backed visible countdown preserve exact 262-line frames\n";
