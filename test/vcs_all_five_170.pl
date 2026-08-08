#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: vcs_all_five_170 ok
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
sub without_usage { my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out; }
sub require_re { my($s,$re,$why)=@_; $s =~ $re or die "$why\n"; }
sub bss_size {
   my($map,$name)=@_;
   $map =~ /^\s+BSS\.__vcsc_object\$\Q$name\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m
      or die "map is missing BSS object $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc vcs_standard_4k_ntsc.cfg));
my $component=File::Spec->catfile($vcs,qw(renderers all_five all_five.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_170 smoke.c26));
my $bin=File::Spec->catfile($tmp,'all_five_170.bin');
my $mapfile=File::Spec->catfile($tmp,'all_five_170.map');
my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "all-five 170 build failed\n$out$err";
without_usage($out) eq '' && $err eq '' or die "all-five 170 build wrote output\n$out$err";
-s $bin == 4096 or die "all-five 170 cartridge is not exactly 4096 bytes\n";
my $module=read_file($component);
my $fixture=read_file($source);
my $map=read_file($mapfile);
require_re($module,qr/^parameter\s+lines;/m,'unified all-five renderer lacks required lines parameter');
require_re($module,qr/TEMPLATE_lines\s*==\s*170/,'unified all-five renderer lacks a 170-line profile');
require_re($fixture,qr/instantiate\s+"renderers\/all_five\/all_five\.c26"\s+as\s+game\s*\(lines:=170\)/,
   '170 fixture does not instantiate unified all-five renderer with lines:=170');
require_re($fixture,qr/game_draw\(\);\s*vcs_ntsc_wait_scanlines\(22\);/s,
   '170 fixture no longer reserves 22 lines for two score regions');
bss_size($map,'game_object_masks')==44 or die "170 object-mask storage is not 44 bytes\n";
$map =~ /^\s+RODATA\.__vcsc_object\$game_playfield\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0028\s+page=hard\b/m
   or die "170 playfield is not a page-contained 40-byte ROM object\n";
my $code=$module; $code =~ s{//[^\n]*}{}g; $code =~ s{/\*.*?\*/}{}gs;
$code !~ /\b(?:lax|dcp|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|axs|xaa|ahx|shx|shy|tas|las)\b/i
   or die "official unified all-five renderer contains an unofficial mnemonic\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
for my $h (
   ['timing','vcs_frame_timing.cpp',[50,'--no-audio','--raw-lines',264],qr/^vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n$/],
   ['phase','vcs_playfield_phase.cpp',[10,10,44,'all-five-181-official'],qr/^vcs_playfield_raster ok: 10 rows x 16 lines x 160 pixels\n$/],
   ['objects','vcs_standard_objects.cpp',['--hblank'],qr/^vcs_standard_objects ok: P0=7 P1=7 M0=6 M1=8 BL=4\n$/],
) {
   my($name,$srcname,$args,$expect)=@$h;
   my $exe=File::Spec->catfile($tmp,"all_five_170_$name");
   my $src=File::Spec->catfile($repo,'test',$srcname);
   ($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
   $rc==0 && !$sig or die "$name harness build failed\n$out$err";
   $out eq '' && $err eq '' or die "$name harness build wrote output\n$out$err";
   ($rc,$sig,$out,$err)=capture($exe,$bin,@$args);
   $rc==0 && !$sig or die "$name harness failed\n$out$err";
   $out =~ $expect or die "unexpected $name output: $out";
   $err eq '' or die "$name harness stderr: $err";
}
print "vcs_all_five_170 ok\n";
