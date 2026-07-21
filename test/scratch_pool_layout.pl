#!/usr/bin/env perl
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
   open(my $fh,'<',$path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>',$path) or die "could not write $path: $!\n";
   print {$fh} $text; close($fh) or die "could not close $path: $!\n";
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

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temporary directory\n";
my $source=File::Spec->catfile($tmp,'scratch_pool_layout.c26');
my $asm=File::Spec->catfile($tmp,'scratch_pool_layout.s');
my $vcsc_cc1=File::Spec->catfile($repo,'compiler','vcsc-cc1');
my $inc=File::Spec->catdir($repo,'test');

write_file($source, <<'SRC');
include "machine_6502.c26"
uint8_t source;
uint16_t a;
uint16_t b;
uint16_t c;
uint16_t helper(uint16_t x) {
   uint16_t y := x + 1;
   return y;
}
void main(void) {
   a := source;
   b := source;
   c := helper(a + b);
}
SRC

my ($exit,$sig,$stdout,$stderr)=run_capture($vcsc_cc1,'-quiet','-I',$inc,$source,'-o',$asm);
die "compiler exited $exit signal $sig\nstdout:\n$stdout\nstderr:\n$stderr"
   if $exit || $sig;
die "compiler wrote unexpected stdout:\n$stdout" if $stdout ne '';
die "compiler wrote unexpected stderr:\n$stderr" if $stderr ne '';
my $text=read_file($asm);
my @decls=($text =~ /^(__vcsc_scratch_\d+):\n\s*\.res\s+(\d+)/mg);
my @ids=($text =~ /^__vcsc_scratch_(\d+):/mg);
join(',',@ids) eq '0,1,2,3,4'
   or die "scratch declarations are not exactly 0..4: ".join(',',@ids)."\n";
my %size=($text =~ /^(__vcsc_scratch_\d+):\n\s*\.res\s+(\d+)/mg);
$size{'__vcsc_scratch_0'}==2 && $size{'__vcsc_scratch_1'}==6 &&
$size{'__vcsc_scratch_2'}==2 && $size{'__vcsc_scratch_3'}==2 &&
$size{'__vcsc_scratch_4'}==6
   or die "unexpected pooled scratch sizes\n";
my ($helper)=$text =~ /\.proc helper\n(.*?)\.endproc/s;
my ($main)=$text =~ /\.proc main\n(.*?)\.endproc/s;
defined($helper) && defined($main) or die "could not isolate helper/main procedures\n";
$helper =~ /__vcsc_scratch_0/ && $helper =~ /__vcsc_scratch_1/
   or die "helper does not use its two nested scratch levels\n";
$helper !~ /__vcsc_scratch_[234]/
   or die "helper incorrectly shares caller scratch storage\n";
$main =~ /__vcsc_scratch_2/ && $main =~ /__vcsc_scratch_3/ && $main =~ /__vcsc_scratch_4/
   or die "main does not use its expected nested scratch levels\n";
$main !~ /__vcsc_scratch_[01]/
   or die "main incorrectly shares callee scratch storage\n";
my $sequential_uses=()=$main =~ /(?:lda|sta) __vcsc_scratch_2,y/g;
$sequential_uses >= 3
   or die "sequential main expressions did not reuse scratch level 0\n";
$text !~ /__vcsc_(?:calltmp|truthtmp|comparetmp|discardtmp|assigntmp|addtmp|binarytmp|casttmp|indextmp|incdectmp)_/
   or die "obsolete per-site scratch prefix remains in generated assembly\n";
$text !~ /__vcsc_scratch_5/
   or die "sequential expressions allocated an unnecessary sixth slot\n";
print "scratch pool layout ok\n";
