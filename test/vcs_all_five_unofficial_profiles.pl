#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_all_five_unofficial_profiles ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
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
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return $d // ''; }
sub used_rom { my($out)=@_; $out =~ /^  rom\s+used=(\d+) bytes\b/mi or die "missing ROM usage:\n$out"; return 0+$1; }
sub bss_size {
   my($map,$name)=@_;
   $map =~ /^\s+BSS\.__vcsc_object\$\Q$name\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m
      or die "map is missing BSS object $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $module=File::Spec->catfile($vcs,qw(renderers all_five_unofficial all_five_unofficial.c26));
my $module_text=read_file($module);
$module_text =~ /^parameter\s+lines;/m or die "unofficial all-five renderer lacks required lines parameter\n";
for my $lines (192,181,170) {
   $module_text =~ /TEMPLATE_lines\s*==\s*$lines/ or die "unofficial renderer lacks lines:=$lines profile\n";
}
my $module_nops=()=$module_text =~ /^\s*asm\s+nop[.]z\s+\$00;/gmi;
$module_nops==3 or die "parameterized unofficial renderer has $module_nops reviewed NOP sites, expected 3\n";

my %mask_bytes=(192=>48,181=>44,170=>44);
my %built;
for my $lines (192,181,170) {
   for my $kind (qw(official unofficial)) {
      my $fixture=File::Spec->catfile($repo,'test','fixtures',"all_five_${lines}" . ($kind eq 'unofficial' ? '_unofficial' : ''),'smoke.c26');
      my $bin=File::Spec->catfile($tmp,"all_five_${lines}_${kind}.bin");
      my $mapfile=File::Spec->catfile($tmp,"all_five_${lines}_${kind}.map");
      my @extra=$kind eq 'unofficial' ? ('-Wa,--illegals') : ();
      my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,@extra,'-Map',$mapfile,$fixture,'-o',$bin);
      $rc==0 && !$sig or die "$lines $kind build failed\n$out$err";
      $err eq '' or die "$lines $kind build stderr: $err";
      -s $bin==4096 or die "$lines $kind image is not 4K\n";
      my $map=read_file($mapfile);
      bss_size($map,'game_object_masks')==$mask_bytes{$lines}
         or die "$lines $kind object-mask storage changed\n";
      $built{$lines}{$kind}=[$bin,$map,used_rom($out)];
   }
   $built{$lines}{official}[2]==$built{$lines}{unofficial}[2]
      or die "$lines official/unofficial ROM use differs: $built{$lines}{official}[2] vs $built{$lines}{unofficial}[2]\n";

   my $asm=File::Spec->catfile($tmp,"all_five_${lines}_unofficial.s26");
   my $src=File::Spec->catfile($repo,'test','fixtures',"all_five_${lines}_unofficial",'smoke.c26');
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Wa,--illegals','-S',$src,'-o',$asm);
   $rc==0 && !$sig or die "$lines unofficial assembly generation failed\n$out$err";
   $out eq '' && $err eq '' or die "$lines unofficial assembly generation wrote output\n$out$err";
   my $text=read_file($asm);
   my $nopzp=()=$text =~ /^\s*nop[.]z\s+\$00\s*$/gmi;
   $nopzp==1 or die "$lines generated assembly has $nopzp reviewed NOP sites, expected 1\n";
   my $other=$text;
   $other =~ s/^\s*nop[.]z\s+\$00\s*$//gmi;
   $other !~ /^\s*(?:dcp|lax|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|axs|xaa|ahx|shx|shy|tas|las)\b/im
      or die "$lines generated assembly contains an unreviewed unofficial mnemonic\n";
}

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my $compare=File::Spec->catfile($tmp,'all_five_unofficial_profile_compare');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_visible_trace_compare.cpp)),@mos_input,'-o',$compare);
$rc==0 && !$sig or die "visible comparator build failed\n$out$err";
for my $lines (192,181,170) {
   ($rc,$sig,$out,$err)=capture($compare,$built{$lines}{official}[0],$built{$lines}{unofficial}[0],'264','264');
   $rc==0 && !$sig or die "$lines visible comparison failed\n$out$err";
   $out =~ /^vcs_visible_trace_compare ok: \d+ events and 42 stable frames per ROM\n$/
      or die "unexpected $lines visible comparison output: $out";
   $err eq '' or die "$lines visible comparison stderr: $err";
}

my $timing=File::Spec->catfile($tmp,'all_five_unofficial_profile_timing');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp)),@mos_input,'-o',$timing);
$rc==0 && !$sig or die "timing harness build failed\n$out$err";
for my $lines (192,181,170) {
   ($rc,$sig,$out,$err)=capture($timing,$built{$lines}{unofficial}[0],50,'--no-audio','--raw-lines',264);
   $rc==0 && !$sig or die "$lines timing harness failed\n$out$err";
   $out eq "vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n"
      or die "unexpected $lines timing output: $out";
   $err eq '' or die "$lines timing stderr: $err";
}

print "vcs_all_five_unofficial_profiles ok\n";
