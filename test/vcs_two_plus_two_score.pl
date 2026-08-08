#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 30
# expectstdout: vcs_two_plus_two_score ok
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
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $text=<$fh>; close($fh); return defined($text)?$text:'';
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub symbol_addr {
   my($map,$name)=@_;
   return hex($1) if $map =~ /\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/;
   return hex($1) if $map =~ /\b\Q$name\E\b.*?run=\$([0-9A-Fa-f]{4})/;
   die "map is missing $name\n";
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $component=File::Spec->catfile($vcs,'two_plus_two_score_component.c26');
my $support=File::Spec->catfile($vcs,'two_plus_two_score_support.c26');
my $fixture=File::Spec->catfile($repo,qw(test fixtures two_plus_two_score two_instances_motion.c26));
my $bin=File::Spec->catfile($tmp,'two_plus_two_score.bin');
my $mapfile=File::Spec->catfile($tmp,'two_plus_two_score.map');

my $source=read_file($component);
my $tables=read_file($support);
my $example=read_file($fixture);
for my $field (
   [VISIBLE_SCANLINES=>11],[DRAW_ENTRY_CYCLE=>3],[DRAW_RETURN_CYCLE=>0],
   [DRAW_COMPLETE_SCANLINES=>11],[DRAW_PARTIAL_ENTRY_CYCLES=>0],
   [DRAW_PARTIAL_EXIT_CYCLES=>0],[DRAW_TERMINAL_WSYNC=>1],
   [DRAW_HMOVE_COUNT=>1],[DRAW_SUCCESSOR_ON_RETURN_LINE=>1],
   [LEFT_X_MIN=>0],[LEFT_X_MAX=>64],[RIGHT_X_MIN=>32],[RIGHT_X_MAX=>144],
) {
   my($name,$value)=@$field;
   $source =~ /\bTEMPLATE_\Q$name\E\s*:=\s*\Q$value\E\b/
      or die "component has no TEMPLATE_$name := $value contract\n";
}
for my $phase (qw(init vblank draw overscan)) {
   $source =~ /require\s+inline\s+void\s+TEMPLATE_\Q$phase\E\s*\(/
      or die "component is missing required TEMPLATE_$phase lifecycle declaration\n";
}
$source !~ /\b(?:VSYNC|VBLANK|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT|AUDC0|AUDC1|AUDF0|AUDF1|AUDV0|AUDV1)\b\s*:=/
   or die "component takes ownership of scheduler or audio hardware\n";
$source !~ /\b(?:lax|sax|dcp|isc|rla|rra|slo|sre)\b/i
   or die "component uses an unofficial opcode\n";
$source =~ /asm sta REFP0;\s*asm sta REFP1;\s*asm sta HMM0;\s*asm sta HMM1;\s*asm sta HMBL;/s
   or die "component does not clear hostile reflection and preserved-object motion\n";
$source =~ /asm sta GRP0;\s*asm sta GRP1;\s*asm sta GRP0;\s*asm sta VDELP0;\s*asm sta VDELP1;/s
   or die "component does not flush both hostile player pipelines before drawing\n";
$source =~ /asm sta GRP0;\s*(?:asm bit\.z CXM0P;\s*){5}asm sta GRP1;\s*asm sta WSYNC;\s*\}/s
   or die "component does not own right-edge final-row latching and terminal cleanup\n";

for my $decl (
   'page const uint8_t vcs_two_plus_two_font_high[80]',
   'page const uint8_t vcs_two_plus_two_font_low[80]',
   'page const uint8_t vcs_two_plus_two_position_table[160]',
) {
   index($tables,$decl)>=0 or die "support module is missing '$decl'\n";
}
$example =~ /top_left_x\s*:=\s*32/ && $example =~ /top_right_x\s*:=\s*96/
   or die "fixture lost fixed top score positions\n";
$example =~ /bottom_left_x\+\+/ && $example =~ /bottom_right_x\+\+;\s*bottom_right_x\+\+/s
   or die "fixture does not move bottom score fields from their own position variables\n";
$example !~ /(?:player|gameplay)[01]?_x/i
   or die "fixture appears to inherit gameplay player positions\n";
$example =~ /HMM0\s*:=\s*0x70/ && $example =~ /HMM1\s*:=\s*0x80/ && $example =~ /HMBL\s*:=\s*0x90/
   or die "fixture no longer enters from hostile preserved-object motion state\n";

my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-Map',$mapfile,$fixture,'-o',$bin);
$rc==0 && !$sig or die "two-plus-two fixture build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "fixture build wrote output\n$out$err";
-s $bin == 4096 or die "two-plus-two ROM is not 4096 bytes\n";
my $map=read_file($mapfile);

my @suffixes=qw(left_score right_score left_color right_color left_x right_x pointers position_controls);
my %seen;
for my $suffix (@suffixes) {
   my $top=symbol_addr($map,"top_$suffix");
   my $bottom=symbol_addr($map,"bottom_$suffix");
   $top!=$bottom or die "top_$suffix and bottom_$suffix share storage\n";
   die "top_$suffix overlaps another instance field\n" if $seen{$top}++;
   die "bottom_$suffix overlaps another instance field\n" if $seen{$bottom}++;
}
for my $shared (qw(vcs_two_plus_two_font_high vcs_two_plus_two_font_low vcs_two_plus_two_position_table)) {
   my $count=()=$map =~ /^\s*\$[0-9A-Fa-f]{4}\s+\Q$shared\E\b/mg;
   $count==1 or die "$shared was not linked exactly once\n";
}

my @symbols=qw(
   top_left_score top_right_score top_left_color top_right_color top_left_x top_right_x
   bottom_left_score bottom_right_score bottom_left_color bottom_right_color bottom_left_x bottom_right_x
);
my @addresses=map { sprintf('0x%02x',symbol_addr($map,$_)) } @symbols;
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $oracle_src=File::Spec->catfile($repo,qw(test vcs_two_plus_two_score.cpp));
my $oracle=File::Spec->catfile($tmp,'vcs_two_plus_two_score_oracle');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos_input,'-o',$oracle);
$rc==0 && !$sig or die "two-plus-two oracle build failed\n$out$err";
$out eq '' && $err eq '' or die "two-plus-two oracle build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($oracle,$bin,@addresses);
$rc==0 && !$sig or die "two-plus-two exact raster failed\n$out$err";
$out eq "vcs_two_plus_two_score ok: exact 2x2 digits, colors, independent motion, hostile-state ownership, and 262-line frames\n"
   or die "unexpected two-plus-two oracle output: $out";
$err eq '' or die "two-plus-two oracle stderr: $err";

# Lifecycle entry points are mandatory for every instantiated component.
for my $omit (qw(init vblank draw overscan)) {
   my $missing=File::Spec->catfile($tmp,"two_plus_two_missing_$omit.c26");
   open(my $fh,'>:raw',$missing) or die "write $missing: $!\n";
   print {$fh} qq{include "vcs.c26"\n};
   print {$fh} qq{include "two_plus_two_score_support.c26"\n};
   print {$fh} qq{instantiate "two_plus_two_score_component.c26" as one\n};
   print {$fh} "void main(void) {\n";
   for my $phase (qw(init vblank draw overscan)) {
      next if $phase eq $omit;
      print {$fh} "   one_${phase}();\n";
   }
   print {$fh} "}\n";
   close($fh) or die "close $missing: $!\n";
   my $missing_bin=File::Spec->catfile($tmp,"two_plus_two_missing_$omit.bin");
   ($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,$missing,'-o',$missing_bin);
   $rc!=0 && !$sig or die "missing $omit lifecycle unexpectedly linked\n$out$err";
   my $diag=$out.$err;
   $diag =~ /required function 'one_\Q$omit\E' not used/
      or die "missing $omit lifecycle produced wrong diagnostic:\n$diag";
}

print "vcs_two_plus_two_score ok\n";
