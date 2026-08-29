#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_generated_font_subsets ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $d=<$fh>; close($fh) or die "close $path: $!\n";
   return defined($d)?$d:'';
}
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   local $/;
   my $stdout=<$out> // '';
   my $stderr=<$err> // '';
   waitpid($pid,0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my @cases=(
   [qw(03_fa_ram_plus fa_ram_plus_diagnostic.c26)],
   [qw(04_4ksc 4ksc_diagnostic.c26)],
   [qw(05_omni omni_diagnostic.c26)],
   [qw(06_cv cv_diagnostic.c26)],
   [qw(07_jane jane_diagnostic.c26)],
   [qw(08_0840 econobanking_diagnostic.c26)],
   [qw(10_0fa0 fotomania_diagnostic.c26)],
   [qw(11_e0 e0_diagnostic.c26)],
   [qw(12_3f 3f_diagnostic.c26)],
   [qw(13_3e 3e_diagnostic.c26)],
);

for my $case (@cases) {
   my ($dir,$source)=@$case;
   my $srcdir=File::Spec->catdir($repo,'examples','09_bankswitching',$dir);
   my $outdir=File::Spec->catdir($tmp,$dir);
   make_path($outdir);
   my ($exit,$sig,$out,$err)=run_capture('make','-s','-C',$srcdir,'fonts',"FONT_SUBSET_DIR=$outdir");
   die "$dir make fonts exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
      if $exit || $sig;
   for my $file (qw(status_font.c26 cart_type_font.c26)) {
      my $got=File::Spec->catfile($outdir,$file);
      my $want=File::Spec->catfile($srcdir,$file);
      -f $want or die "$dir does not check in $file\n";
      slurp($got) eq slurp($want)
         or die "$dir/$file is stale; run make fonts in that example\n";
   }
   my ($dry_exit,$dry_sig,$dry_out,$dry_err)=run_capture(
      'make','-n','-C',$srcdir,'all','PERL=/definitely/missing/perl');
   die "$dir ordinary make dry-run failed: $dry_err" if $dry_exit || $dry_sig;
   index($dry_out,'/definitely/missing/perl') < 0
      or die "$dir ordinary build unexpectedly requires Perl\n";

   my $text=slurp(File::Spec->catfile($srcdir,$source));
   $text !~ /Exact glyph subsets copied from the canonical ASCII fonts/
      or die "$dir/$source still contains hand-copied canonical glyphs\n";
   index($text,'include "status_font.c26"') >= 0 &&
   index($text,'include "cart_type_font.c26"') >= 0
      or die "$dir/$source does not consume its generated font subsets\n";
}

# UA/UASW wrappers include their local generated tables directly; the shared
# common body deliberately stays independent of wrapper-relative include paths.
{
   my $dir=File::Spec->catdir($repo,'examples','09_bankswitching','09_ua');
   my $outdir=File::Spec->catdir($tmp,'09_ua');
   make_path($outdir);
   my ($exit,$sig,$out,$err)=run_capture('make','-s','-C',$dir,'fonts',"FONT_SUBSET_DIR=$outdir");
   die "09_ua make fonts exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
      if $exit || $sig;
   for my $file (qw(ua_status_font.c26 ua_cart_type_font.c26)) {
      my $got=File::Spec->catfile($outdir,$file);
      my $want=File::Spec->catfile($dir,$file);
      -f $want or die "09_ua does not check in $file\n";
      slurp($got) eq slurp($want)
         or die "09_ua/$file is stale; run make fonts in 09_ua\n";
   }
   my ($dry_exit,$dry_sig,$dry_out,$dry_err)=run_capture(
      'make','-n','-C',$dir,'all','PERL=/definitely/missing/perl');
   die "09_ua ordinary make dry-run failed: $dry_err" if $dry_exit || $dry_sig;
   index($dry_out,'/definitely/missing/perl') < 0
      or die "09_ua ordinary build unexpectedly requires Perl\n";

   my $common=slurp(File::Spec->catfile($repo,'examples','common','ua_diagnostic_common.c26'));
   $common !~ /Exact glyph subsets copied from the canonical ASCII fonts/
      or die "UA common body still contains hand-copied canonical glyphs\n";
   for my $wrapper (qw(ua_diagnostic.c26 uasw_diagnostic.c26)) {
      my $text=slurp(File::Spec->catfile($dir,$wrapper));
      index($text,'include "ua_status_font.c26"') >= 0 &&
      index($text,'include "ua_cart_type_font.c26"') >= 0
         or die "09_ua/$wrapper does not consume its generated font subsets\n";
   }
}

# Directly lock the canonical slashed zero into one mapper subset. All other
# copies are protected by the deterministic regeneration comparisons above.
my $eco=slurp(File::Spec->catfile($repo,'examples','09_bankswitching','08_0840','cart_type_font.c26'));
$eco =~ m{// 0x30 0\s+\w+\(\s*0b\.\.XXXXX\.}s
   or die "EconoBanking generated subset does not contain the canonical slashed zero\n";

print "vcs_generated_font_subsets ok\n";
