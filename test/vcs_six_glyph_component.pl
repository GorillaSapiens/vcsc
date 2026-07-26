#!/usr/bin/perl
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
sub without_usage { my($s)=@_; $s =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+RAM USAGE\n(?:  [^\n]+\n)+//; return $s; }
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
my $component=File::Spec->catfile($vcs,'six_glyph_component.c26');
my $bin=File::Spec->catfile($tmp,'six_glyph_component.bin');
my $reverse_bin=File::Spec->catfile($tmp,'six_glyph_component_reversed.bin');
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

my $map=read_file($mapfile);
for my $suffix (qw(score pointers row delayed)) {
   my $upper=symbol_addr($map,"upper_$suffix");
   my $lower=symbol_addr($map,"lower_$suffix");
   $upper != $lower or die "upper_$suffix and lower_$suffix share storage\n";
}
my $source=read_file($component);
$source =~ /TEMPLATE_VISIBLE_SCANLINES\s*:=\s*11/
   or die "component visible scanline contract is not 11\n";
for my $phase (qw(init vblank draw overscan)) {
   $source =~ /require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/
      or die "component is missing required TEMPLATE_$phase lifecycle declaration\n";
}
$source !~ /\b(?:VSYNC|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT)\b\s*:=/
   or die "component takes ownership of scheduler hardware\n";

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
