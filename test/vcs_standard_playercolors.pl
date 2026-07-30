#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: vcs_standard_playercolors ok
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
sub without_cartridge_usage {
   my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out;
}
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map is missing $name\n";
   return hex($1);
}
sub map_zp {
   my($map,$name)=@_; my $v=map_symbol($map,$name); $v<=0xff or die "$name is not in zero page\n"; return $v;
}
sub require_re { my($text,$re,$why)=@_; $text =~ $re or die "$why\n"; }
sub build_profile {
   my($driver,$vcs,$cfg,$source,$renderer,$bin,$map)=@_;
   my($rc,$sig,$out,$err)=capture(
      $driver,'-I',$vcs,'-T',$cfg,'-Map',$map,$source,$renderer,'-o',$bin);
   $rc==0 && !$sig or die "player-color cartridge build failed\nstdout:\n$out\nstderr:\n$err";
   without_cartridge_usage($out) eq '' or die "player-color build wrote unexpected stdout:\n$out";
   $err eq '' or die "player-color build wrote stderr:\n$err";
   length(read_file($bin))==4096 or die "player-color cartridge is not 4096 bytes\n";
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $assembler=File::Spec->catfile($repo,'assembler','vcsc-as');
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(renderers standard_4k_ntsc_playercolors));
my $contract=File::Spec->catfile($profile,'standard_4k_ntsc_playercolors.c26');
my $renderer=File::Spec->catfile($profile,'standard_4k_ntsc_playercolors_renderer.s26');
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc_playercolors.cfg');
my $normalizer=File::Spec->catfile($profile,'normalize.pl');
my $static_source=File::Spec->catfile($repo,qw(test fixtures vcs_examples 07_playercolor_static golden.c26));
my $motion_source=File::Spec->catfile($repo,qw(test fixtures vcs_examples 08_playercolor_motion golden.c26));
my $static_bin=File::Spec->catfile($tmp,'playercolor_static_test.bin');
my $static_map=File::Spec->catfile($tmp,'playercolor_static_test.map');
my $motion_bin=File::Spec->catfile($tmp,'playercolor_motion_test.bin');
my $motion_map=File::Spec->catfile($tmp,'playercolor_motion_test.map');

my($rc,$sig,$out,$err)=capture($^X,$normalizer,'--check');
$rc==0 && !$sig or die "player-color normalization check failed\n$out$err";
$out eq "standard_4k_ntsc_playercolors normalization current\n"
   or die "unexpected normalizer output: $out";
$err eq '' or die "normalizer wrote stderr: $err";

# The standalone renderer must assemble with only the official opcode table.
my $renderer_object=File::Spec->catfile($tmp,'standard_4k_ntsc_playercolors_renderer.o26');
($rc,$sig,$out,$err)=capture($assembler,'-I',$profile,'-o',$renderer_object,$renderer);
$rc==0 && !$sig or die "plain player-color renderer assembly failed\n$out$err";
without_cartridge_usage($out) eq '' && $err eq ''
   or die "plain player-color renderer assembly wrote output\n$out$err";

build_profile($driver,$vcs,$cfg,$static_source,$renderer,$static_bin,$static_map);
build_profile($driver,$vcs,$cfg,$motion_source,$renderer,$motion_bin,$motion_map);
my $smap=read_file($static_map);
my $mmap=read_file($motion_map);

for my $map ($smap,$mmap) {
   require_re($map,qr/^\s*RENDERER_CODE\s+load=\$[0-9A-Fa-f]{2}00\s+size=\$0300\b/m,
      'player-color renderer code is not page aligned in a 0x300-byte window');
   require_re($map,qr/^\s*RENDERER_RODATA\s+load=\$[0-9A-Fa-f]{2}00\s+size=\$0058\b/m,
      'player-color score table is not page aligned');
}
require_re($smap,qr/region=RAM\s+depth=3\s+bytes=\$000A\s+physical=\$00F6-\$00FF\s+extra=\$0004/,
   'static player-color stack accounting changed');
require_re($mmap,qr/region=RAM\s+depth=4\s+bytes=\$000C\s+physical=\$00F4-\$00FF\s+extra=\$0004/,
   'motion player-color stack accounting changed');

for my $map ($smap,$mmap) {
   for my $name (qw(vcs_standard_color_playfield vcs_standard_color_player0_colors
                    vcs_standard_color_player1_colors player0_graphics player1_graphics)) {
      my $addr=map_symbol($map,$name);
      my $size=$name eq 'vcs_standard_color_playfield' ? 48 : 8;
      (($addr & 0xff)+$size-1)<=0xff or die "$name crosses a page boundary\n";
   }
   for my $forbidden (qw(vcs_standard_color_missile0_y vcs_standard_color_missile1_y
                         vcs_standard_color_missile0_height vcs_standard_color_missile1_height)) {
      $map !~ /\b\Q$forbidden\E\b/ or die "missile state leaked into player-color profile: $forbidden\n";
   }
}

my $contract_text=read_file($contract);
require_re($contract_text,qr/VCS_STANDARD_COLOR_APPLICATION_DISPLAY_RAM_BYTES\s+17\b/,
   'player-color public RAM cost changed');
require_re($contract_text,qr/VCS_STANDARD_COLOR_PRIVATE_RAM_BYTES\s+60\b/,
   'player-color private RAM cost changed');
require_re($contract_text,qr/VCS_STANDARD_COLOR_MODULE_RAM_BYTES\s+77\b/,
   'player-color total module RAM cost changed');
$contract_text !~ /MISSILE0|MISSILE1|missile0|missile1/
   or die "public player-color contract advertises missile state\n";
my $renderer_text=read_file($renderer);
$renderer_text !~ /^\s*(?:dcp|lax|sax|sbx|asr|anc|arr|isc|isb|rla|rra|slo|sre)\b/im
   or die "player-color renderer contains an unofficial mnemonic\n";
$renderer_text !~ /^\s*op[0-9A-Fa-f]{2}\b/im
   or die "player-color renderer contains a raw opcode escape\n";
require_re($renderer_text,qr/^\s*lda\s+#38\+128\s*$/m,
   'player-color VBLANK timer no longer preserves the standard frame period');
require_re($renderer_text,qr/lda\.ay\s+vcs_standard_color_player0_colors,y.*sta\s+vcs_standard_color_player0_latch/s,
   'P0 row-color stage is missing');
require_re($renderer_text,qr/lda\.ay\s+vcs_standard_color_player1_colors,y.*sta\s+COLUP1/s,
   'P1 row-color write is missing');

# Compile one reusable CPU/TIA-write harness, then lock both private fixtures.
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $harness_source=File::Spec->catfile($repo,'test','vcs_standard_playercolors.cpp');
my $harness=File::Spec->catfile($tmp,'vcs_standard_playercolors');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   $harness_source,@mos_input,'-o',$harness);
$rc==0 && !$sig or die "player-color harness build failed\n$out$err";
without_cartridge_usage($out) eq '' && $err eq ''
   or die "player-color harness build wrote output\n$out$err";

my @static_zp=map { sprintf('0x%02x',map_zp($smap,$_)) } qw(
   vcs_standard_color_object_x vcs_standard_color_player0_y
   vcs_standard_color_player1_y vcs_standard_color_ball_y);
($rc,$sig,$out,$err)=capture($harness,'static',$static_bin,@static_zp);
$rc==0 && !$sig or die "static player-color harness failed\n$out$err";
$out eq "vcs_standard_playercolors static ok: exact P0/P1 row colors, BL raster, no missiles\n"
   or die "unexpected static player-color output: $out";
$err eq '' or die "static player-color harness stderr: $err";

my @motion_zp=map { sprintf('0x%02x',map_zp($mmap,$_)) } qw(
   vcs_standard_color_object_x vcs_standard_color_player0_y
   vcs_standard_color_player1_y vcs_standard_color_ball_y motion_directions);
($rc,$sig,$out,$err)=capture($harness,'motion',$motion_bin,@motion_zp);
$rc==0 && !$sig or die "motion player-color harness failed\n$out$err";
$out eq "vcs_standard_playercolors motion ok: 320 frames, full-range P0/P1/BL motion, exact row colors\n"
   or die "unexpected motion player-color output: $out";
$err eq '' or die "motion player-color harness stderr: $err";

print "vcs_standard_playercolors ok\n";
