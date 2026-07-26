#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
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
sub without_usage { my($s)=@_; $s =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+//; return $s; }

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $oracle_dir=File::Spec->catdir($repo,qw(test oracles pristine_basic_v1.9_playercolors));
my $oracle_src=File::Spec->catfile($oracle_dir,'faithful_legacy_playercolors.bas');
my $oracle_bin=File::Spec->catfile($oracle_dir,'faithful_legacy_playercolors.bin');
my $source=read_file($oracle_src);
my $rom=read_file($oracle_bin);
length($rom)==4096 or die "pristine upstream BASIC oracle is not exactly 4096 bytes\n";
sha256_hex($source) eq '8daaeb4eb35131a5beb2c93d2e2e4732f09c86c97d83763b627d6be7c4c130d3'
   or die "pristine upstream BASIC source hash changed\n";
sha256_hex($rom) eq '573cc86c7ba12c0626fb73678480721e043e3468795151635beaae8f7f3e0b6a'
   or die "pristine upstream BASIC ROM hash changed\n";
$source =~ /^\s*const\s+playercolors\s*=\s*1\s*$/m
   or die "oracle source no longer selects playercolors\n";
$source =~ /^\s*const\s+player1colors\s*=\s*1\s*$/m
   or die "oracle source no longer selects player1colors\n";
$source !~ /^\s*set\s+kernel_options\s+playercolors\s*$/m
   or die "oracle source uses the upstream compiler's rejected setter combination\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(kernels faithful_legacy_playercolors));
my $cfg=File::Spec->catfile($profile,'faithful_legacy_playercolors.cfg');
my $reference_asm=File::Spec->catfile($profile,'faithful_legacy_playercolors_reference.s26');
my $reference_src=File::Spec->catfile($repo,qw(test fixtures faithful_legacy_playercolors reference_static.c26));
my $reference_bin=File::Spec->catfile($tmp,'retained_audit_reference.bin');
my $reference_map=File::Spec->catfile($tmp,'retained_audit_reference.map');
my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-I',$profile,'-Wa,--illegals','-T',$cfg,'-Map',$reference_map,
   $reference_src,$reference_asm,'-o',$reference_bin);
$rc==0 && !$sig or die "retained audit reference build failed\n$out$err";
without_usage($out) eq '' && $err eq ''
   or die "retained audit reference build wrote output\n$out$err";
length(read_file($reference_bin))==4096
   or die "retained audit reference is not exactly 4096 bytes\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_faithful_legacy_compare.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_pristine_basic_compare');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "oracle comparator build failed\n$out$err";
$out eq '' && $err eq '' or die "oracle comparator build wrote output\n$out$err";

# First lock the independently measured frame-period gap.  Stock upstream BASIC
# reaches a stable 264 raw lines while the retained-source VCSC audit reaches 265.
($rc,$sig,$out,$err)=capture($harness,$oracle_bin,$reference_bin,'265','265');
$rc==1 && !$sig or die "expected pristine upstream BASIC frame-period gap was not reproduced\n$out$err";
$out eq '' or die "unexpected frame-gap stdout: $out";
$err =~ /old frame 3 has 20064 cycles \(264 raw lines\), expected 20140 cycles \(265 raw lines\)/
   or die "unexpected frame-gap diagnostic: $err";

# Compare each ROM against its actual stable period to expose the first visible
# semantic mismatch.  Address $22 is HMM0.  Upstream BASIC writes $60 because
# its player0colorstore byte aliases missile0x; the VCSC audit writes $70.
($rc,$sig,$out,$err)=capture($harness,$oracle_bin,$reference_bin,'264','265');
$rc==1 && !$sig or die "expected pristine upstream BASIC HMM0 gap was not reproduced\n$out$err";
$out eq '' or die "unexpected HMM0-gap stdout: $out";
$err =~ /event 7 differs: old 9:46 22=60, new 9:46 22=70/
   or die "unexpected HMM0-gap diagnostic: $err";

print "vcs_pristine_basic_oracle ok: stock upstream BASIC ROM locked; 264-line/HMM0 gaps reproduced\n";
