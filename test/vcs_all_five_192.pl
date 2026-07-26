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
sub write_file {
   my($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n";
   print {$f} $d; close($f) or die "close $p: $!\n";
}
sub without_usage {
   my($out)=@_; $out =~ s/\ACARTRIDGE ROM USAGE\n(?:  [^\n]+\n)+//; return $out;
}
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
my $profile=File::Spec->catdir($vcs,qw(kernels standard_4k_ntsc));
my $component=File::Spec->catfile($vcs,qw(kernels all_five_192 all_five_192.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_192 smoke.c26));
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $bin=File::Spec->catfile($tmp,'all_five_192.bin');
my $mapfile=File::Spec->catfile($tmp,'all_five_192.map');

my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "all-five 192 build failed\n$out$err";
without_usage($out) eq '' && $err eq ''
   or die "all-five 192 build wrote output\n$out$err";
-s $bin == 4096 or die "all-five 192 cartridge is not exactly 4096 bytes\n";

my $module=read_file($component);
my $fixture=read_file($source);
my $map=read_file($mapfile);
require_re($module,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*192/,
   'component does not publish 192 visible scanlines');
require_re($module,qr/TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*19/,
   'component public-RAM contract changed');
require_re($module,qr/TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*51/,
   'component private-RAM contract changed');
require_re($module,qr/TEMPLATE_MODULE_RAM_BYTES\s*:=\s*70/,
   'component total-RAM contract changed');
require_re($fixture,qr/template\s+"kernels\/all_five_192\/all_five_192\.c26"\s+as\s+game/,
   'fixture does not instantiate the gameplay template');
require_re($fixture,qr/game_draw\(\);\s*vcs_ntsc_begin_overscan\(\);/s,
   'fixture no longer enters overscan immediately after the 192-line draw');
require_re($module,qr/asm \.align 256;/,
   'hot two-line loop lost its page anchor');
my $absolute_pf_loads=()=$module =~ /asm\s+(?:lda|ldy)\.ax\s+TEMPLATE_playfield(?:\s*[+]\s*[123])?,x;/g;
$absolute_pf_loads==8
   or die "component has $absolute_pf_loads forced-absolute playfield loads, expected 8\n";
my $final_pf_loads=()=$module =~ /asm\s+ldy\.a\s+TEMPLATE_playfield[+]4[4576];/g;
$final_pf_loads==8
   or die "component has $final_pf_loads full-height final-row loads, expected 8\n";
require_re($module,qr/asm bit\.z CXM0P;/,
   'official three-cycle delay no longer has an explicit zero-page mode');
require_re($module,qr/lda\.z TEMPLATE_missile0_y;\s*asm clc;\s*asm adc #89;/s,
   'M0 application Y is no longer restored from the full-height 89-line bias');

my $code=$module;
$code =~ s{//[^\n]*}{}g;
$code =~ s{/\*.*?\*/}{}gs;
$code !~ /\b(?:score|font)\b/i
   or die "gameplay component retained score/font code or state\n";
$code !~ /\b(?:VSYNC|VBLANK|TIM1T|TIM8T|TIM64T|T1024T|INTIM|TIMINT)\b/
   or die "gameplay component touches scheduler-owned frame/timer state\n";
$code !~ /\b(?:lax|dcp|sax|isc|isb|rla|rra|slo|sre|anc|alr|arr|axs|xaa|ahx|shx|shy|tas|las)\b/i
   or die "official component contains an unofficial mnemonic\n";
$code !~ /\bop[0-9A-Fa-f]{2}\b/
   or die "official component contains a raw opcode escape\n";

my @public=qw(
   game_object_x game_player0_y game_player1_y game_missile1_height
   game_missile1_y game_ball_y game_player0_graphics game_player1_graphics
   game_player0_height game_player1_height game_missile0_height
   game_missile0_y game_ball_height
);
my @private=qw(game_workspace game_playfield_position game_object_masks);
my $public=0; $public += bss_size($map,$_) for @public;
my $private=0; $private += bss_size($map,$_) for @private;
$public==19 or die "linked public gameplay RAM is $public bytes, expected 19\n";
$private==51 or die "linked private gameplay RAM is $private bytes, expected 51\n";
$public+$private==70 or die "linked gameplay RAM is not 70 bytes\n";
bss_size($map,'game_workspace')==6 or die "workspace is not six bytes\n";
bss_size($map,'game_object_masks')==44 or die "object-mask storage is not 44 bytes\n";
$map =~ /^\s+RODATA\.__vcsc_object\$game_playfield\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0030\s+page=hard\b/m
   or die "game playfield is not a page-contained 48-byte ROM object\n";
$map !~ /(?:score|font)/i or die "gameplay-only map retained score/font symbols\n";
$map !~ /KERNEL_RODATA/ or die "gameplay-only link retained predecessor score ROM segment\n";
$map =~ /region=RAM\s+depth=2\s+bytes=\$0008\s+physical=\$00F8-\$00FF\s+extra=\$0004/
   or die "component map lost the inline-assembly helper stack allowance\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my @harnesses=(
   ['timing','vcs_frame_timing.cpp','50','--no-audio','--raw-lines','262',
      qr/^vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes
$/],
   ['phase','vcs_playfield_phase.cpp','11','12',
      qr/^vcs_playfield_raster ok: 11 rows x 16 lines x 160 pixels\n$/],
   ['objects','vcs_standard_objects.cpp',
      qr/^vcs_standard_objects ok: P0=7 P1=8 M0=6 M1=8 BL=5
$/],
);for my $h (@harnesses) {
   my($name,$srcname,@rest)=@$h;
   my $expect=pop @rest;
   my $exe=File::Spec->catfile($tmp,"all_five_192_$name");
   my $src=File::Spec->catfile($repo,'test',$srcname);
   ($rc,$sig,$out,$err)=capture(
      $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mos_input,'-o',$exe);
   $rc==0 && !$sig or die "$name harness build failed\n$out$err";
   $out eq '' && $err eq '' or die "$name harness build wrote output\n$out$err";
   ($rc,$sig,$out,$err)=capture($exe,$bin,@rest);
   $rc==0 && !$sig or die "$name harness failed\n$out$err";
   $out =~ $expect or die "unexpected $name output: $out";
   $err eq '' or die "$name harness stderr: $err";
}

# The template's four lifecycle phases remain mandatory. Omit each call from an
# otherwise valid cartridge and require the component-specific link diagnostic.
for my $phase (qw(init vblank draw overscan)) {
   my $bad=$fixture;
   my $removed=($bad =~ s/^\s*game_\Q$phase\E\(\);\s*$//m);
   $removed==1 or die "could not remove game_$phase from negative fixture\n";
   my $badsrc=File::Spec->catfile($tmp,"all_five_192_missing_$phase.c26");
   my $badbin=File::Spec->catfile($tmp,"all_five_192_missing_$phase.bin");
   write_file($badsrc,$bad);
   ($rc,$sig,$out,$err)=capture(
      $driver,'-I',$vcs,'-T',$cfg,$badsrc,'-o',$badbin);
   $rc!=0 && !$sig or die "missing $phase lifecycle unexpectedly linked\n$out$err";
   ($out.$err) =~ /required function 'game_\Q$phase\E' not used/
      or die "missing $phase produced the wrong diagnostic\n$out$err";
}

print "vcs_all_five_192 ok\n";
