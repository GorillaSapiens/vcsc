#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 30
# expectstdout: vcs_six_glyph_component ok
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
sub read_file {
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f); return defined($d)?$d:'';
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub symbol_addr {
   my($map,$name)=@_;
   return hex($1) if $map =~ /\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/;
   return hex($1) if $map =~ /\b\Q$name\E\b.*?run=\$([0-9A-Fa-f]{4})/;
   die "map is missing $name\n";
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $src=File::Spec->catfile($repo,qw(test fixtures six_glyph_component two_instances.c26));
my $reverse_src=File::Spec->catfile($repo,qw(test fixtures six_glyph_component two_instances_reversed.c26));
my $spaced_src=File::Spec->catfile($repo,qw(test fixtures six_glyph_component two_instances_spaced.c26));
my $poison_src=File::Spec->catfile($repo,qw(test fixtures six_glyph_component poison_then_centered.c26));
my $poison_color_src=File::Spec->catfile($repo,qw(test fixtures six_glyph_component poison_then_centered_color.c26));
my $component=File::Spec->catfile($vcs,'six_glyph_component.c26');
my $left_component=File::Spec->catfile($vcs,'six_glyph_left_component.c26');
my $right_component=File::Spec->catfile($vcs,'six_glyph_right_component.c26');
my $bin=File::Spec->catfile($tmp,'six_glyph_component.bin');
my $reverse_bin=File::Spec->catfile($tmp,'six_glyph_component_reversed.bin');
my $spaced_bin=File::Spec->catfile($tmp,'six_glyph_component_spaced.bin');
my $poison_bin=File::Spec->catfile($tmp,'six_glyph_component_poison.bin');
my $poison_color_bin=File::Spec->catfile($tmp,'six_glyph_component_poison_color.bin');
my $mapfile=File::Spec->catfile($tmp,'six_glyph_component.map');
my $asm=File::Spec->catfile($tmp,'six_glyph_component.s26');

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$src,'-o',$bin);
$rc==0 && !$sig or die "component build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "component build wrote output\n$out$err";
-s $bin == 4096 or die "component ROM is not 4096 bytes\n";
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-S',$src,'-o',$asm);
$rc==0 && !$sig or die "component compile failed\n$out$err";
$out eq '' && $err eq '' or die "component compile wrote output\n$out$err";

($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$reverse_src,'-o',$reverse_bin);
$rc==0 && !$sig or die "reversed component build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "reversed component build wrote output\n$out$err";
-s $reverse_bin == 4096 or die "reversed component ROM is not 4096 bytes\n";

for my $extra ([$spaced_src,$spaced_bin,'spaced'],[$poison_src,$poison_bin,'poison'],
                  [$poison_color_src,$poison_color_bin,'poison-color']) {
   my($src_path,$bin_path,$name)=@$extra;
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$src_path,'-o',$bin_path);
   $rc==0 && !$sig or die "$name component build failed\n$out$err";
   without_usage($out) eq '' && $err eq '' or die "$name component build wrote output\n$out$err";
   -s $bin_path == 4096 or die "$name component ROM is not 4096 bytes\n";
}

my $map=read_file($mapfile);
for my $suffix (qw(score pointers row delayed)) {
   my $upper=symbol_addr($map,"upper_$suffix");
   my $lower=symbol_addr($map,"lower_$suffix");
   $upper != $lower or die "upper_$suffix and lower_$suffix share storage\n";
}
my $source=read_file($component);
for my $variant ([$component,'centered'],[$left_component,'left'],[$right_component,'right']) {
   my ($path,$name)=@$variant;
   my $text=read_file($path);
   $text =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*11/
      or die "$name component visible scanline contract is not 11\n";
   for my $phase (qw(init vblank draw overscan)) {
      $text =~ /require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/
         or die "$name component is missing required TEMPLATE_$phase lifecycle declaration\n";
   }
   $text !~ /\b(?:VSYNC|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT)\b\s*:=/
      or die "$name component takes ownership of scheduler hardware\n";
   $text !~ /\b(?:lax|sax|dcp|isc|rla|rra|slo|sre)\b/i
      or die "$name component uses an unofficial opcode\n";
   $text =~ /asm sta REFP0;\s*asm sta REFP1;\s*asm nop;/s
      or die "$name component does not reset hostile reflection in the preserved eight-cycle slot\n";
}
my $left_source=read_file($left_component);
my $right_source=read_file($right_component);
my $pair_source=read_file($src);
my $pair_reverse_source=read_file($reverse_src);
for my $pair ([$pair_source,'normal'],[$pair_reverse_source,'reversed']) {
   my($text,$name)=@$pair;
   $text =~ /upper_score\s*:=\s*123456/ && $text =~ /lower_score\s*:=\s*654321/
      or die "$name pair lost distinct score values\n";
   $text =~ /vcs_ntsc_wait_component_scanlines\s*\(\s*85\s*\)/
      or die "$name pair does not calibrate its first component entry\n";
   $text =~ /_draw\(\);\s*vcs_ntsc_component_handoff\(\);\s*\w+_draw\(\);/s
      or die "$name pair lacks the measured three-cycle component handoff\n";
}
$left_source =~ /Position P0 at x=0 and P1 at x=8/
   or die "left component no longer documents its exact X range\n";
$right_source =~ /Position P0 at x=112 and P1 at x=120/
   or die "right component no longer documents its exact X range\n";

my $generated=read_file($asm);
for my $label (qw(upper lower)) {
   $generated =~ /\@inline_\d+_asm_\Q${label}_draw_loop\E:/
      or die "$label draw loop was not instantiated with a private label\n";
   $generated !~ /\bjsr\s+\Q${label}_\E(?:init|vblank|draw|overscan)\b/
      or die "$label lifecycle failed to inline\n";
}

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $hsrc=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $harness=File::Spec->catfile($tmp,'vcs_frame_timing_component');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$hsrc,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "timing harness build failed\n$out$err";
$out eq '' && $err eq '' or die "timing harness build wrote output\n$out$err";
for my $case ([normal => $bin], [reversed => $reverse_bin]) {
   my($name,$rom)=@$case;
   ($rc,$sig,$out,$err)=capture($harness,$rom,'50','--no-audio','--raw-lines','262');
   $rc==0 && !$sig or die "$name two-instance timing failed\n$out$err";
   $out =~ /vcs_frame_timing ok: 47 frames at 262 lines/
      or die "unexpected $name timing output: $out";
   $err eq '' or die "$name timing harness stderr: $err";
}

my $entry_src=File::Spec->catfile($repo,qw(test vcs_six_glyph_standalone_entry.cpp));
my $entry_exe=File::Spec->catfile($tmp,'vcs_six_glyph_pair_entry');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$entry_src,@mos_input,'-o',$entry_exe);
$rc==0 && !$sig or die "pair-entry harness build failed\n$out$err";
$out eq '' && $err eq '' or die "pair-entry harness build wrote output\n$out$err";
for my $case ([normal => $bin], [reversed => $reverse_bin]) {
   my($name,$rom)=@$case;
   ($rc,$sig,$out,$err)=capture($entry_exe,$rom,'125','136');
   $rc==0 && !$sig or die "$name pair-entry contract failed\n$out$err";
   $out eq "vcs_six_glyph_standalone_entry ok: calibrated lines 125 and 136 entries and 262-line frames\n"
      or die "unexpected $name pair-entry output: $out";
   $err eq '' or die "$name pair-entry stderr: $err";
}

my $raster_src=File::Spec->catfile($repo,qw(test vcs_six_glyph_raster.cpp));
my $raster_exe=File::Spec->catfile($tmp,'vcs_six_glyph_raster');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-DILLEGAL_OPCODES','-I',$mos,$raster_src,@mos_input,'-o',$raster_exe);
$rc==0 && !$sig or die "score-raster harness build failed\n$out$err";
$out eq '' && $err eq '' or die "score-raster harness build wrote output\n$out$err";
my @raster_cases=(
   ['normal',$bin,'125','123456','136','654321',2],
   ['reversed',$reverse_bin,'125','654321','136','123456',2],
   ['spaced',$spaced_bin,'70','135790','180','246801',2],
   ['poison',$poison_bin,'111','908172',1],
   ['poison-color',$poison_color_bin,'111','314159',1],
);
for my $case (@raster_cases) {
   my($name,$rom,@args)=@$case;
   my $count=pop @args;
   ($rc,$sig,$out,$err)=capture($raster_exe,$rom,@args);
   $rc==0 && !$sig or die "$name exact score raster failed\n$out$err";
   $out eq "vcs_six_glyph_raster ok: $count exact 48x8 score rasters, hostile reflection reset, and 262-line frames\n"
      or die "unexpected $name score-raster output: $out";
   $err eq '' or die "$name score-raster stderr: $err";
}

# Every lifecycle function is a component contract, not merely a convention.
# Omit each one in turn and require the component-specific link diagnostic.
for my $omit (qw(init vblank draw overscan)) {
   my $missing=File::Spec->catfile($tmp,"six_glyph_missing_$omit.c26");
   open(my $fh,'>:raw',$missing) or die "write $missing: $!\n";
   print {$fh} qq{include "vcs.c26"\n};
   print {$fh} qq{include "fonts/default_decimal.c26"\n};
   print {$fh} qq{template "six_glyph_component.c26" as one\n};
   print {$fh} "void main(void) {\n";
   for my $phase (qw(init vblank draw overscan)) {
      next if $phase eq $omit;
      print {$fh} "   one_${phase}();\n";
   }
   print {$fh} "}\n";
   close($fh) or die "close $missing: $!\n";
   my $missing_bin=File::Spec->catfile($tmp,"six_glyph_missing_$omit.bin");
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$missing,'-o',$missing_bin);
   $rc != 0 && !$sig or die "missing $omit lifecycle unexpectedly linked\n$out$err";
   my $diag=$out.$err;
   $diag =~ /required function 'one_\Q$omit\E' not used/
      or die "missing $omit lifecycle produced wrong diagnostic:\n$diag";
}

print "vcs_six_glyph_component ok\n";
