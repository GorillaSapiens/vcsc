#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_192 ok
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
sub write_file {
   my($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n";
   print {$f} $d; close($f) or die "close $p: $!\n";
}
sub without_usage {
   my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out;
}
sub require_re { my($s,$re,$why)=@_; $s =~ $re or die "$why\n"; }
sub bss_size {
   my($map,$name)=@_;
   $map =~ /^\s+BSS\.__vcsc_object\$\Q$name\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m
      or die "map is missing BSS object $name\n";
   return hex($1);
}
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing $name\n";
   my $value=hex($1);
   $value <= 0xff or die "$name is not zero page\n";
   return $value;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(renderers standard_4k_ntsc));
my $component=File::Spec->catfile($vcs,qw(renderers all_five all_five.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_192 smoke.c26));
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $bin=File::Spec->catfile($tmp,'all_five_192.bin');
my $mapfile=File::Spec->catfile($tmp,'all_five_192.map');
my $motion_source=File::Spec->catfile($repo,qw(test fixtures all_five_192 motion.c26));
my $motion_bin=File::Spec->catfile($tmp,'all_five_192_motion.bin');
my $motion_mapfile=File::Spec->catfile($tmp,'all_five_192_motion.map');

my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "all-five 192 build failed\n$out$err";
without_usage($out) eq '' && $err eq ''
   or die "all-five 192 build wrote output\n$out$err";
-s $bin == 4096 or die "all-five 192 cartridge is not exactly 4096 bytes\n";

($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$motion_mapfile,$motion_source,'-o',$motion_bin);
$rc==0 && !$sig or die "all-five 192 motion build failed\n$out$err";
without_usage($out) eq '' && $err eq ''
   or die "all-five 192 motion build wrote output\n$out$err";
-s $motion_bin == 4096
   or die "all-five 192 motion cartridge is not exactly 4096 bytes\n";

my $whole_module=read_file($component);
$whole_module =~ /#if TEMPLATE_lines == 192(.*?)#elif TEMPLATE_lines == 181/s
   or die "could not isolate 192-line branch of unified all-five renderer\n";
my $module=$1;
my $fixture=read_file($source);
my $map=read_file($mapfile);
require_re($module,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*TEMPLATE_lines/,
   'component does not publish 192 visible scanlines');
require_re($module,qr/TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*23/,
   'component public-RAM contract changed');
require_re($module,qr/TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*48/,
   'component private-RAM contract changed');
require_re($module,qr/TEMPLATE_MODULE_RAM_BYTES\s*:=\s*71/,
   'component total-RAM contract changed');
require_re($fixture,qr/instantiate\s+"renderers\/all_five\/all_five\.c26"\s+as\s+game\s*\(lines:=192\)/,
   'fixture does not instantiate the gameplay template');
require_re($fixture,qr/game_draw\(\);\s*vcs_ntsc_begin_overscan\(\);/s,
   'fixture no longer enters overscan immediately after the 192-line draw');
require_re($module,qr/asm \.align 256;/,
   'hot two-line loop lost its page anchor');
my $absolute_pf_loads=()=$module =~ /asm\s+(?:lda|ldy)\.ax\s+TEMPLATE_playfield(?:\s*[+]\s*[123])?,x;/g;
$absolute_pf_loads==30
   or die "component has $absolute_pf_loads forced-absolute playfield loads, expected 30\n";
require_re($module,qr/TEMPLATE_player0_color.*TEMPLATE_player1_color/s,
   'solid player-color controls are missing');
$module !~ /TEMPLATE_player[01]_colors/
   or die "all-five 192 unexpectedly retained per-row player-color tables
";

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
   game_missile0_y game_ball_height game_player0_nusiz game_player1_nusiz
   game_player0_color game_player1_color
);
my @private=qw(game_object_masks);
my $public=0; $public += bss_size($map,$_) for @public;
my $private=0; $private += bss_size($map,$_) for @private;
$public==23 or die "linked public gameplay RAM is $public bytes, expected 23\n";
$private==48 or die "linked private gameplay RAM is $private bytes, expected 48\n";
$public+$private==71 or die "linked gameplay RAM is not 71 bytes\n";
bss_size($map,'game_object_masks')==48 or die "object-mask storage is not 48 bytes\n";
$map !~ /BSS[.]__vcsc_object\$game_(?:workspace|playfield_position)\b/
   or die "all-five 192 unexpectedly retained separate workspace/playfield-position RAM\n";
require_re($module,qr/alias TEMPLATE_playfield_position TEMPLATE_object_masks\[47\]/,
   'playfield position is no longer overlaid on the dead mask lane');
$map =~ /^\s+RODATA\.__vcsc_object\$game_playfield\s+load=\$[0-9A-Fa-f]{4}\s+size=\$0030\s+page=hard\b/m
   or die "game playfield is not a page-contained 48-byte ROM object\n";
$map !~ /(?:score|font)/i or die "gameplay-only map retained score/font symbols\n";
$map !~ /RENDERER_RODATA/ or die "gameplay-only link retained predecessor score ROM segment\n";
$map =~ /region=ram\s+depth=1\s+bytes=\$0006\s+physical=\$00FA-\$00FF\s+extra=\$0004/
   or die "component map lost the inline-assembly helper stack allowance\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my @harnesses=(
   ['timing','vcs_frame_timing.cpp','50','--no-audio','--raw-lines','264',
      qr/^vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes
$/],
   ['phase','vcs_playfield_phase.cpp','12','12','40','all-five-192',
      qr/^vcs_playfield_raster ok: 12 rows x 16 lines x 160 pixels\n$/],
   ['objects','vcs_standard_objects.cpp','--hblank',
      qr/^vcs_standard_objects ok: P0=7 P1=7 M0=6 M1=8 BL=4
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

# Prove the scoreless renderer's actual VBLANK horizontal-positioning
# transactions and clipped endpoint pixels across 360 asynchronous frames.
my $motion_map=read_file($motion_mapfile);
my $endpoint_exe=File::Spec->catfile($tmp,'all_five_192_endpoints');
my $endpoint_src=File::Spec->catfile($repo,'test','vcs_all_five_composition.cpp');
($rc,$sig,$out,$err)=capture(
   $cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   $endpoint_src,@mos_input,'-o',$endpoint_exe);
$rc==0 && !$sig or die "endpoint harness build failed\n$out$err";
$out eq '' && $err eq '' or die "endpoint harness build wrote output\n$out$err";
($rc,$sig,$out,$err)=capture($endpoint_exe,$bin,'none','static');
$rc==0 && !$sig or die "static object-pixel raster failed
$out$err";
$out eq "vcs_all_five_composition static none ok
"
   or die "unexpected static object-pixel output: $out";
$err eq '' or die "static object-pixel stderr: $err";

# Pin the first packed-row boundary that exposed the stale delayed-Ball
# transfer.  Y=8,height=3 must render exactly eight scanlines (relative
# lines 12..19), with no duplicated pair at relative line 16.
my $edge_text=$fixture;
$edge_text =~ s/game_ball_y := 48;/game_ball_y := 8;/
   or die "could not set all-five 192 Ball row-edge fixture
";
my $edge_src=File::Spec->catfile($tmp,'all_five_192_ball_row_edge.c26');
my $edge_bin=File::Spec->catfile($tmp,'all_five_192_ball_row_edge.bin');
write_file($edge_src,$edge_text);
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,$edge_src,'-o',$edge_bin);
$rc==0 && !$sig or die "all-five 192 Ball row-edge build failed
$out$err";
without_usage($out) eq '' && $err eq '' or die "all-five 192 Ball row-edge build wrote output
$out$err";
($rc,$sig,$out,$err)=capture($endpoint_exe,$edge_bin,'none','ball-edge','12','8');
$rc==0 && !$sig or die "all-five 192 Ball row-edge raster failed
$out$err";
$out eq "vcs_all_five_composition ball-edge none ok
"
   or die "unexpected all-five 192 Ball row-edge output: $out";
$err eq '' or die "all-five 192 Ball row-edge stderr: $err";

my @endpoint_args=(
   map_symbol($motion_map,'game_object_x'),
   map_symbol($motion_map,'game_player0_y'),
   map_symbol($motion_map,'game_player1_y'),
   map_symbol($motion_map,'game_missile0_y'),
   map_symbol($motion_map,'game_missile1_y'),
   map_symbol($motion_map,'game_ball_y'),
   map_symbol($motion_map,'motion_frame'),
);
($rc,$sig,$out,$err)=capture(
   $endpoint_exe,$motion_bin,'none','motion',@endpoint_args);
$rc==0 && !$sig or die "endpoint harness failed\n$out$err";
$out eq "vcs_all_five_composition motion none ok\n"
   or die "unexpected endpoint output: $out";
$err eq '' or die "endpoint harness stderr: $err";

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
