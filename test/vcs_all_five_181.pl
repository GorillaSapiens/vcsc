#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 15
# expectstdout: vcs_all_five_181 ok
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

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catdir($vcs,qw(renderers standard_4k_ntsc));
my $component=File::Spec->catfile($vcs,qw(renderers all_five_181 all_five_181.c26));
my $source=File::Spec->catfile($repo,qw(test fixtures all_five_181 smoke.c26));
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $bin=File::Spec->catfile($tmp,'all_five_181.bin');
my $mapfile=File::Spec->catfile($tmp,'all_five_181.map');

my($rc,$sig,$out,$err)=capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$mapfile,$source,'-o',$bin);
$rc==0 && !$sig or die "all-five 181 build failed\n$out$err";
without_usage($out) eq '' && $err eq ''
   or die "all-five 181 build wrote output\n$out$err";
-s $bin == 4096 or die "all-five 181 cartridge is not exactly 4096 bytes\n";

my $module=read_file($component);
my $fixture=read_file($source);
my $map=read_file($mapfile);
require_re($module,qr/TEMPLATE_VISIBLE_SCANLINES\s*:=\s*181/,
   'component does not publish 181 visible scanlines');
require_re($module,qr/TEMPLATE_PUBLIC_RAM_BYTES\s*:=\s*23/,
   'component public-RAM contract changed');
require_re($module,qr/TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*44/,
   'component private-RAM contract changed');
require_re($module,qr/TEMPLATE_MODULE_RAM_BYTES\s*:=\s*67/,
   'component total-RAM contract changed');
require_re($fixture,qr/instantiate\s+"renderers\/all_five_181\/all_five_181\.c26"\s+as\s+game/,
   'fixture does not instantiate the gameplay template');
require_re($fixture,qr/game_draw\(\);\s*vcs_ntsc_wait_scanlines\(11\);/s,
   'fixture no longer accounts for 181 gameplay plus 11 score-reserved lines');
require_re($module,qr/asm \.align 256;/,
   'hot two-line loop lost its page anchor');
for my $branch (
   [bcs=>'TEMPLATE_first_player1_zero'], [bcc=>'first_drawP0'],
   [bcs=>'skipP1'], [bcc=>'drawP0'], [bne=>'continuerenderer'],
   [bcc=>'transition_activeP1'], [bcc=>'transition_activeP0'],
   [bcc=>'transition_first_activeP1'], [bcs=>'transition_first_doneP1'],
   [bcc=>'transition_follow_activeP0'],
) {
   require_re($module,qr/asm \Q$branch->[0]\E[.]same \@\Q$branch->[1]\E;/,
      "visible branch to $branch->[1] is not constrained to the same ROM page");
}
my $absolute_pf_loads=()=$module =~ /asm\s+(?:lda|ldy)\.ax\s+TEMPLATE_playfield(?:\s*[+]\s*[123])?,x;/g;
$absolute_pf_loads==30
   or die "component has $absolute_pf_loads forced-absolute playfield loads, expected 30\n";
require_re($module,qr/asm bit\.z CXM0P;/,
   'official three-cycle delay no longer has an explicit zero-page mode');
$module !~ /asm sta[.]z TEMPLATE_missile[01]_y;/
   or die "all-five 181 unexpectedly mutates public missile Y state during rendering\n";
require_re($module,qr/TEMPLATE_player0_color.*TEMPLATE_player1_color/s,
   'solid player-color controls are missing');
$module !~ /TEMPLATE_player[01]_colors/
   or die "all-five 181 unexpectedly retained per-row player-color tables\n";

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
$private==44 or die "linked private gameplay RAM is $private bytes, expected 44\n";
$public+$private==67 or die "linked gameplay RAM is not 67 bytes\n";
bss_size($map,'game_object_masks')==44 or die "object-mask storage is not 44 bytes\n";
$map !~ /BSS[.]__vcsc_object\$game_(?:workspace|playfield_position)\b/
   or die "all-five 181 unexpectedly retained separate workspace/playfield-position RAM\n";
require_re($module,qr/alias TEMPLATE_playfield_position TEMPLATE_object_masks\[43\]/,
   'playfield position is no longer overlaid on the final mask lane');
$map =~ /^\s+RODATA\.__vcsc_object\$game_playfield\s+load=\$[0-9A-Fa-f]{4}\s+size=\$002C\s+page=hard\b/m
   or die "game playfield is not a page-contained 44-byte ROM object\n";
$map !~ /(?:score|font)/i or die "gameplay-only map retained score/font symbols\n";
$map !~ /RENDERER_RODATA/ or die "gameplay-only link retained predecessor score ROM segment\n";
$map =~ /region=ram\s+depth=2\s+bytes=\$0008\s+physical=\$00F8-\$00FF\s+extra=\$0004/
   or die "component map lost the inline-assembly helper stack allowance\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my @harnesses=(
   ['scheduler','vcs_frame_ntsc_scheduler.cpp','normal','none',
      qr/^vcs_frame_ntsc_scheduler normal ok\n$/],
   ['phase','vcs_playfield_phase.cpp','11','11','44','all-five-181-official',
      qr/^vcs_playfield_raster ok: 11 rows x 16 lines x 160 pixels\n$/],
   ['objects','vcs_standard_objects.cpp','--hblank',
      qr/^vcs_standard_objects ok: P0=7 P1=7 M0=6 M1=8 BL=4\n$/],
);
for my $h (@harnesses) {
   my($name,$srcname,@rest)=@$h;
   my $expect=pop @rest;
   my $exe=File::Spec->catfile($tmp,"all_five_181_$name");
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

# Pin the first packed-row boundary with the independent object-pixel oracle.
# In the 181-line score-above composition Y=8,height=3 occupies relative
# gameplay lines 14..21: exactly eight scanlines across the row transition.
my $edge_fixture=read_file(File::Spec->catfile($repo,qw(test fixtures all_five_181 static_score_above.c26)));
$edge_fixture =~ s/game_ball_y := 48;/game_ball_y := 8;/
   or die "could not set all-five 181 Ball row-edge fixture
";
my $edge_src=File::Spec->catfile($tmp,'all_five_181_ball_row_edge.c26');
my $edge_bin=File::Spec->catfile($tmp,'all_five_181_ball_row_edge.bin');
write_file($edge_src,$edge_fixture);
($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-T',$cfg,$edge_src,'-o',$edge_bin);
$rc==0 && !$sig or die "all-five 181 Ball row-edge build failed
$out$err";
without_usage($out) eq '' && $err eq '' or die "all-five 181 Ball row-edge build wrote output
$out$err";
my $edge_exe=File::Spec->catfile($tmp,'all_five_181_ball_row_edge');
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   File::Spec->catfile($repo,qw(test vcs_all_five_composition.cpp)),@mos_input,'-o',$edge_exe);
$rc==0 && !$sig or die "all-five 181 Ball row-edge harness build failed
$out$err";
$out eq '' && $err eq '' or die "all-five 181 Ball row-edge harness build wrote output
$out$err";
($rc,$sig,$out,$err)=capture($edge_exe,$edge_bin,'above','ball-edge','12','8');
$rc==0 && !$sig or die "all-five 181 Ball row-edge raster failed
$out$err";
$out eq "vcs_all_five_composition ball-edge above ok
"
   or die "unexpected all-five 181 Ball row-edge output: $out";
$err eq '' or die "all-five 181 Ball row-edge stderr: $err";

# The template's four lifecycle phases remain mandatory. Omit each call from an
# otherwise valid cartridge and require the component-specific link diagnostic.
for my $phase (qw(init vblank draw overscan)) {
   my $bad=$fixture;
   my $removed=($bad =~ s/^\s*game_\Q$phase\E\(\);\s*$//m);
   $removed==1 or die "could not remove game_$phase from negative fixture\n";
   my $badsrc=File::Spec->catfile($tmp,"all_five_181_missing_$phase.c26");
   my $badbin=File::Spec->catfile($tmp,"all_five_181_missing_$phase.bin");
   write_file($badsrc,$bad);
   ($rc,$sig,$out,$err)=capture(
      $driver,'-I',$vcs,'-T',$cfg,$badsrc,'-o',$badbin);
   $rc!=0 && !$sig or die "missing $phase lifecycle unexpectedly linked\n$out$err";
   ($out.$err) =~ /required function 'game_\Q$phase\E' not used/
      or die "missing $phase produced the wrong diagnostic\n$out$err";
}

print "vcs_all_five_181 ok\n";
