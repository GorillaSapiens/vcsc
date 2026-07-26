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
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(kernels faithful_legacy_playercolors));
my $cfg=File::Spec->catfile($profile,'faithful_legacy_playercolors.cfg');
my $reference_asm=File::Spec->catfile($profile,'faithful_legacy_playercolors_reference.s26');
my $reference_src=File::Spec->catfile($repo,qw(test fixtures faithful_legacy_playercolors reference_static.c26));
my $template_src=File::Spec->catfile($repo,qw(examples 05_faithful_legacy_static_test faithful_legacy_static_test.c26));
my $reference_bin=File::Spec->catfile($tmp,'faithful_reference.bin');
my $template_bin=File::Spec->catfile($tmp,'faithful_template.bin');
my $reference_map=File::Spec->catfile($tmp,'faithful_reference.map');
my $template_map=File::Spec->catfile($tmp,'faithful_template.map');

# The audit source records the retained inputs it was selected from. Refuse to
# trust the retained audit if any source input changes without refreshing it.
my $reference_text=read_file($reference_asm);
for my $rel (
   'legacy-basic-kernels/common/macro.h',
   'legacy-basic-kernels/common/2600basic.h',
   'legacy-basic-kernels/standard/std_overscan.asm',
   'legacy-basic-kernels/standard/std_kernel.asm',
   'legacy-basic-kernels/common/score_graphics.asm',
) {
   my $path=File::Spec->catfile($vcs,split('/', $rel));
   my $hash=sha256_hex(read_file($path));
   $reference_text =~ /\Q$hash\E\s+\Q$rel\E/
      or die "faithful reference does not match retained input $rel\n";
}
for my $mnemonic (qw(dcp lax sbx asr)) {
   $reference_text =~ /^\s*\Q$mnemonic\E\b/im
      or die "faithful reference lost unofficial mnemonic $mnemonic\n";
}
my $template_text=read_file(File::Spec->catfile($profile,'faithful_legacy_playercolors.c26'));
for my $mnemonic (qw(dcp lax sbx asr)) {
   $template_text =~ /^\s*asm\s+\Q$mnemonic\E\b/im
      or die "template port lost unofficial mnemonic $mnemonic\n";
}
$template_text =~ /require void TEMPLATE_drawscreen\(void\)/
   or die "faithful port is not exposed through the template instance\n";
$template_text =~ /alias TEMPLATE_player0_color_latch TEMPLATE_object_x\[2\]/
   or die "faithful port lost player0colorstore/missile0x alias\n";
$template_text =~ /union TEMPLATE_player0_color_alias/ &&
$template_text =~ /union TEMPLATE_player1_color_alias/
   or die "faithful port lost missile/color-pointer overlays\n";
$template_text =~ /extern uint8_t TEMPLATE_playfield\[48\]/
   or die "faithful port playfield is not RAM-backed\n";
$template_text =~ /asm \.(?:align) 256, \$83, \$ea;/
   or die "faithful port lost stock loop page placement\n";
my $zx_count=()=$template_text =~ /asm (?:lda|ldy)\.zx TEMPLATE_playfield[^;]+,x;/g;
$zx_count==8 or die "faithful port must use eight zero-page-indexed dynamic playfield loads\n";

my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-I',$profile,'-Wa,--illegals','-T',$cfg,'-Map',$reference_map,
   $reference_src,$reference_asm,'-o',$reference_bin);
$rc==0 && !$sig or die "faithful reference build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "faithful reference build wrote output\n$out$err";

($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-Wa,--illegals','-T',$cfg,'-Map',$template_map,
   $template_src,'-o',$template_bin);
$rc==0 && !$sig or die "faithful template build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "faithful template build wrote output\n$out$err";
for my $bin ($reference_bin,$template_bin) {
   length(read_file($bin))==4096 or die "$bin is not exactly 4096 bytes\n";
}
my $tmap=read_file($template_map);
$tmap =~ /\blegacy_drawscreen\b/ or die "template map lacks instance-prefixed drawscreen\n";
$tmap =~ /\blegacy_object_x\b/ or die "template map lacks instance-prefixed state\n";
$tmap !~ /\bvcs_standard_kernel_drawscreen\b/
   or die "template cartridge leaked fixed predecessor drawscreen symbol\n";
my @crossing=($tmap =~ /^\s+\$[0-9A-F]+ -> \$[0-9A-F]+ BMI opcode=\$30 taken-page=crossing$/mg);
@crossing==1 or die "template map must retain exactly one intentional BMI page crossing\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_faithful_legacy_compare.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_faithful_legacy_compare');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "faithful comparator build failed\n$out$err";
$out eq '' && $err eq '' or die "faithful comparator build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($harness,$reference_bin,$template_bin,'264','264');
$rc==0 && !$sig or die "faithful template differs from retained-source audit\n$out$err";
$out =~ /^vcs_faithful_legacy_compare ok: \d+ events and 42 stable frames per ROM\n$/
   or die "unexpected faithful comparator output: $out";
$err eq '' or die "faithful comparator stderr: $err";

print "vcs_faithful_legacy_playercolors ok: template matches repaired 264-line retained-source audit\n";
