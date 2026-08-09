#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 20
# expectstdout: vcs_blank_noasm ok: source-only postfix countdown preserves exact 262-line frames
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
$text =~ /while\s*\(\s*i--\s*\)\s*\{\s*WSYNC\s*:=\s*_\s*;/s
   or die "blank_noasm no longer exercises the postfix visible countdown\n";
$text !~ /\basm\b/
   or die "blank_noasm contains inline assembly\n";

my ($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,$source,'-o',$bin);
die "blank_noasm build exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "blank_noasm build wrote unexpected output\nstdout:\n$out\nstderr:\n$err"
   if without_cartridge_usage($out) ne '' || $err ne '';

($exit,$sig,$out,$err)=run_capture($driver,'-I',$vcs,'-S',$source,'-o',$asm);
die "blank_noasm compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "blank_noasm compile wrote output\nstdout:\n$out\nstderr:\n$err" if $out ne '' || $err ne '';
my $asm_text=read_file($asm);
$asm_text =~ /\@while_start_\d+:\s+lda main\$i\s+dec main\$i\s+cmp #0\s+beq \@while_end_\d+\s+sta\s+\$02/s
   or die "postfix visible countdown did not use compact direct condition lowering\n";

($exit,$sig,$out,$err)=run_capture(
   'g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-DILLEGAL_OPCODES',
   '-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing_exe);
die "timing harness compile exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
die "timing harness compile wrote output\nstdout:\n$out\nstderr:\n$err" if $out ne '' || $err ne '';

($exit,$sig,$out,$err)=run_capture($timing_exe,$bin,'45','--no-audio','--raw-lines','262');
die "timing harness exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err" if $exit || $sig;
$out eq "vcs_frame_timing ok: 42 frames at 262 lines, 0 AUDV0 writes\n"
   or die "blank_noasm lost exact frame timing: $out";
$err eq '' or die "timing harness stderr: $err";

print "vcs_blank_noasm ok: source-only postfix countdown preserves exact 262-line frames\n";
