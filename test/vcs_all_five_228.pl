#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: vcs_all_five_228 ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my$err=gensym; my$pid=open3(my$in,my$out,$err,@cmd); close $in;
   my$so=slurp_fh($out); my$se=slurp_fh($err); waitpid($pid,0);
   return($?>>8,$?&127,$so,$se);
}
sub read_file {
   my($p)=@_; open(my$f,'<:raw',$p) or die "read $p: $!\n";
   local$/; my$d=<$f>; close$f; return defined($d)?$d:'';
}
sub write_file {
   my($p,$d)=@_; open(my$f,'>:raw',$p) or die "write $p: $!\n";
   print{$f}$d; close$f or die "close $p: $!\n";
}
sub without_usage { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub require_re { my($s,$re,$why)=@_; $s =~ $re or die "$why\n"; }

my$repo=shift@ARGV//usage(); my$tmp=shift@ARGV//usage(); usage() if @ARGV;
$repo=abs_path($repo)//die"repo\n"; make_path($tmp); $tmp=abs_path($tmp);
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$renderer=read_file(File::Spec->catfile($vcs,qw(renderers all_five all_five.c26)));

require_re($renderer,qr/#if\s+TEMPLATE_lines\s*==\s*192\s*\|\|\s*TEMPLATE_lines\s*==\s*228/,
   'all-five renderer does not expose 228 through its visible-line parameter');
require_re($renderer,qr/#if\s+TEMPLATE_lines\s*==\s*228.*?TEMPLATE_PLAYFIELD_BYTES\s*:=\s*60.*?TEMPLATE_PLAYFIELD_ROWS\s*:=\s*15/s,
   '228-line renderer geometry is not 60 bytes / 15 playfield rows');
require_re($renderer,qr/#if\s+TEMPLATE_lines\s*==\s*228.*?TEMPLATE_PRIVATE_RAM_BYTES\s*:=\s*60.*?TEMPLATE_MODULE_RAM_BYTES\s*:=\s*83/s,
   '228-line renderer RAM contract changed');
require_re($renderer,qr/#if\s+TEMPLATE_lines\s*==\s*228\s*\n\s*asm\s+lda\s+#2;/,
   '228-line renderer no longer uses its two-pair first row');
require_re($renderer,qr/#if\s+TEMPLATE_lines\s*==\s*228\s*\n\s*asm\s+cpx\s+#56;/,
   '228-line renderer terminal row changed');
$renderer !~ /border_handoff|hide_border/
   or die "obsolete visible-border workaround remains in all-five renderer\n";

my$cxx=$ENV{CXX}||'c++';
my$mos=File::Spec->catdir($repo,qw(simulator mos6502));
my$obj=File::Spec->catfile($mos,'mos6502.o');
my@mi=-f$obj?($obj):(File::Spec->catfile($mos,'mos6502.cpp'));
my@harness_specs=(
   ['frame','vcs_frame_50hz_interactive.cpp'],
   ['phase','vcs_playfield_phase.cpp'],
   ['objects','vcs_standard_objects.cpp'],
);
my%exe;
for my$h(@harness_specs) {
   my($name,$srcname)=@$h;
   my$e=File::Spec->catfile($tmp,"all_five_228_$name");
   my$src=File::Spec->catfile($repo,'test',$srcname);
   my($r,$s,$o,$er)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$src,@mi,'-o',$e);
   $r==0&&!$s or die "$name harness build failed\n$o$er";
   $o eq '' && $er eq '' or die "$name harness build wrote output\n$o$er";
   $exe{$name}=$e;
}

for my$standard(qw(pal secam)) {
   my$source=File::Spec->catfile($repo,qw(examples 17_video_standards),$standard,
      '01_all_five',"${standard}_all_five_228_interactive.c26");
   my$text=read_file($source);
   require_re($text,qr/game_playfield\[60\]/,"$standard all-five playfield is not 60 bytes");
   require_re($text,qr/lines:=228/,"$standard all-five does not instantiate 228 visible lines");
   require_re($text,qr/alias\s+OBJECT_MAX_Y\s+113/,"$standard all-five Y range is not 0..113 pairs");
   require_re($text,qr/vcs_${standard}_end_vblank\(\);\s*game_draw\(\);\s*vcs_${standard}_component_to_overscan_handoff\(\);\s*vcs_${standard}_begin_overscan\(\);/s,
      "$standard all-five does not render the complete 228-line visible field directly");
   $text !~ /wait_component_scanlines|wait_visible_tail_scanlines|border_handoff|hide_border/
      or die "$standard all-five still contains a synthetic visible border\n";

   my$rom=File::Spec->catfile($tmp,"$standard-all-five-228.bin");
   my($r,$s,$o,$er)=capture($driver,'-I',$vcs,$source,'-o',$rom);
   $r==0&&!$s or die "$standard 228 build failed\n$o$er";
   without_usage($o) eq '' && $er eq '' or die "$standard 228 build wrote output\n$o$er";
   -s$rom==4096 or die "$standard 228 ROM is not 4K\n";

   ($r,$s,$o,$er)=capture($exe{frame},$rom);
   $r==0&&!$s && $o eq "vcs_frame_50hz_interactive ok\n" && $er eq ''
      or die "$standard 228 frame contract failed\n$o$er";
   ($r,$s,$o,$er)=capture($exe{phase},$rom,'15','15','48','all-five-phase-228');
   $r==0&&!$s && $o eq "vcs_playfield_all_five_phase_228 ok: 228 lines (4 + 14x16) with proven PF phases\n" && $er eq ''
      or die "$standard 228 playfield phase failed\n$o$er";
   ($r,$s,$o,$er)=capture($exe{objects},$rom,'--hblank');
   $r==0&&!$s && $o =~ /^vcs_standard_objects ok:/ && $er eq ''
      or die "$standard 228 object activity failed\n$o$er";

   # Exercise the vertical endpoints that exposed the old 192+border leakage.
   my$edge=$text;
   $edge =~ s/game_player0_y := 18;/game_player0_y := 113;/ or die "set P0 edge\n";
   $edge =~ s/game_player1_y := 78;/game_player1_y := 7;/ or die "set P1 edge\n";
   $edge =~ s/game_missile0_y := 34;/game_missile0_y := 113;/ or die "set M0 edge\n";
   $edge =~ s/game_missile1_y := 62;/game_missile1_y := 7;/ or die "set M1 edge\n";
   $edge =~ s/game_ball_y := 48;/game_ball_y := 112;/ or die "set Ball edge\n";
   my$edge_src=File::Spec->catfile($tmp,"$standard-all-five-228-edge.c26");
   my$edge_rom=File::Spec->catfile($tmp,"$standard-all-five-228-edge.bin");
   write_file($edge_src,$edge);
   ($r,$s,$o,$er)=capture($driver,'-I',$vcs,$edge_src,'-o',$edge_rom);
   $r==0&&!$s or die "$standard 228 edge build failed\n$o$er";
   ($r,$s,$o,$er)=capture($exe{frame},$edge_rom);
   $r==0&&!$s && $o eq "vcs_frame_50hz_interactive ok\n" && $er eq ''
      or die "$standard 228 edge frame failed\n$o$er";
   ($r,$s,$o,$er)=capture($exe{objects},$edge_rom,'--hblank');
   $r==0&&!$s && $o =~ /^vcs_standard_objects ok:/ && $er eq ''
      or die "$standard 228 edge object activity failed\n$o$er";
}

print "vcs_all_five_228 ok\n";
