#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: vcs_driving ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($f)=@_; local $/; return <$f> // ''; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c);close$i;my$so=slurp_fh($o);my$se=slurp_fh($e);waitpid($p,0);return($?>>8,$?&127,$so,$se); }
sub read_file { my($p)=@_;open(my$f,'<:raw',$p)or die"read $p: $!\n";local$/;my$d=<$f>;close$f;return$d//''; }
sub symbol_addr { my($m,$n)=@_; return hex($1) if $m =~ /\$([0-9A-Fa-f]{4})\s+\Q$n\E\b/; die "map missing $n\n"; }

my$repo=shift@ARGV//usage();my$tmp=shift@ARGV//usage();usage()if@ARGV;
$repo=abs_path($repo)//die"resolve repo\n";$tmp=abs_path($tmp)//die"resolve tmp\n";
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$vcs=File::Spec->catdir($repo,qw(libraries vcs));
my$example_dir=File::Spec->catdir($repo,qw(examples 03_controllers driving));
my$example=File::Spec->catfile($example_dir,'drive.c26');
my$component=File::Spec->catfile($vcs,'driving_controller.c26');
my$left_fixture=File::Spec->catfile($repo,qw(test fixtures driving_left driving_left.c26));
my$right_fixture=File::Spec->catfile($repo,qw(test fixtures driving_right driving_right.c26));

my$c=read_file($component);my$e=read_file($example);
$c =~ /parameter port := 0/ && $c =~ /TEMPLATE_step/ && $c =~ /TEMPLATE_delta/ &&
$c =~ /TEMPLATE_button/ && $c =~ /TEMPLATE_phase/ && $c =~ /TEMPLATE_direction/ &&
$c =~ /\(SWCHA >> 4\) & 0x03/ && $c =~ /TEMPLATE_next_phase := SWCHA & 0x03/ &&
$c =~ /INPT4/ && $c =~ /INPT5/ && $c =~ /SWACNT := SWACNT & 0x0f/ &&
$c =~ /SWACNT := SWACNT & 0xf0/
   or die "driving component API or port mapping missing\n";
$c =~ /11 -> 10 -> 00 -> 01 -> 11/ && $c =~ /per application frame/ &&
$c =~ /opposite/ && $c =~ /select Driving/
   or die "driving Gray-code, accumulation, skip, or Stella documentation missing\n";
$c =~ /0, 2, 1, 3,\s*1, 0, 3, 2,\s*2, 3, 0, 1,\s*3, 1, 2, 0/s
   or die "driving transition table changed\n";
$e =~ /instantiate "driving_controller\.c26" as left_drive \(port:=0\)/ &&
$e =~ /instantiate "driving_controller\.c26" as right_drive \(port:=1\)/ &&
$e =~ /fonts\/big_hex\.c26/ && $e =~ /left_value/ && $e =~ /right_value/ &&
$e =~ /& 0x0f/ && $e =~ /DRIVE_WHITE/ && $e =~ /DRIVE_RED/
   or die "public driving example lost two-port hex counter/color behavior\n";
$e =~ /const uint8_t drive_orbit_x\[16\]/ &&
$e =~ /38, 43, 46, 49,\s*50, 49, 46, 43,\s*38, 33, 30, 27,\s*26, 27, 30, 33/s &&
$e =~ /const uint8_t drive_orbit_y\[16\]/ &&
$e =~ /2,\s*4,\s*8, 14,\s*22, 30, 36, 40,\s*42, 40, 36, 30,\s*22, 14,\s*8,\s*4/s &&
$e =~ /NUSIZ0 := 0x20/ && $e =~ /NUSIZ1 := 0x20/ &&
$e =~ /drive_orbit_x\[left_value\] \+ 7/ &&
$e =~ /drive_orbit_x\[right_value\] \+ 87/ &&
$e =~ /left_missile_end := left_missile_start \+ 4/ &&
$e =~ /right_missile_end := right_missile_start \+ 4/ &&
$e =~ /left_missile_prepare_start := left_missile_start - 1/ &&
$e =~ /left_missile_prepare_end := left_missile_end - 1/ &&
$e =~ /right_missile_prepare_start := right_missile_start - 1/ &&
$e =~ /right_missile_prepare_end := right_missile_end - 1/ &&
$e =~ /asm sta WSYNC;\s*drive_apply_missiles\(\);/s
   or die "public driving example lost 16-position 4x4 missile orbits\n";
$e =~ /lda #42/ && $e =~ /lda #122/ && $e =~ /asm ldy #15/ &&
$e =~ /asm \@glyph_rows:;\s*asm sta WSYNC;\s*drive_apply_missiles\(\);\s*asm lda\.iy \(left_glyph_pointer\),y;\s*asm sta GRP0/s &&
$e =~ /drive_prepare_left_missile\(\)/ && $e =~ /drive_prepare_right_missile\(\)/ &&
$e =~ /vcs_ntsc_wait_component_scanlines\(71\)/ &&
$e =~ /vcs_ntsc_wait_visible_tail_scanlines\(72\)/ &&
$e =~ /asm cpx #48/
   or die "public driving example lost centered P0\/P1 glyph-and-orbit raster or one-line-ahead missile scheduling\n";

sub build_rom {
   my($src,$dir,$bin,$map)=@_;
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$dir,'-Map',$map,$src,'-o',$bin);
   $rc==0&&!$sig or die "driving build failed for $src\n$out$err";
   $err eq '' or die "driving build stderr for $src: $err";
}

my$left_bin=File::Spec->catfile($tmp,'driving_left.bin');my$left_map=File::Spec->catfile($tmp,'driving_left.map');
my$right_bin=File::Spec->catfile($tmp,'driving_right.bin');my$right_map=File::Spec->catfile($tmp,'driving_right.map');
my$example_bin=File::Spec->catfile($tmp,'drive.bin');my$example_map=File::Spec->catfile($tmp,'drive.map');
build_rom($left_fixture,File::Spec->catdir($repo,qw(test fixtures driving_left)),$left_bin,$left_map);
build_rom($right_fixture,File::Spec->catdir($repo,qw(test fixtures driving_right)),$right_bin,$right_map);
build_rom($example,$example_dir,$example_bin,$example_map);
-s$left_bin==2048 && -s$right_bin==2048 or die "driving port fixtures are not 2K ROMs\n";
-s$example_bin==4096 or die "public driving example is not a 4K ROM\n";

my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));my$mosobj=File::Spec->catfile($mos,'mos6502.o');my@mos=-f$mosobj?($mosobj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$oracle_src=File::Spec->catfile($repo,qw(test vcs_driving.cpp));my$oracle=File::Spec->catfile($tmp,'vcs_driving_oracle');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2','-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos,'-o',$oracle);
$rc==0&&!$sig or die "driving oracle build failed\n$out$err";

for my $case ([$left_bin,$left_map,0],[$right_bin,$right_map,1]) {
   my($bin,$mapfile,$side)=@$case;my$m=read_file($mapfile);
   my@a=map{sprintf('0x%04x',symbol_addr($m,$_))}qw(drive_step drive_delta drive_button drive_phase drive_direction);
   ($rc,$sig,$out,$err)=capture($oracle,'fixture',$bin,@a,$side);
   $rc==0&&!$sig or die "driving side-$side oracle failed\n$out$err";
   $out =~ /vcs_driving ok:/ or die "unexpected driving side-$side output: $out";
   $err eq '' or die "driving side-$side oracle stderr: $err";
}

my$m=read_file($example_map);
my@a=map{sprintf('0x%04x',symbol_addr($m,$_))}qw(left_value right_value left_missile_position right_missile_position left_missile_start right_missile_start);
($rc,$sig,$out,$err)=capture($oracle,'example',$example_bin,@a);
$rc==0&&!$sig or die "public driving example oracle failed\n$out$err";
$out =~ /vcs_driving ok:/ or die "unexpected public driving output: $out";
$err eq '' or die "public driving oracle stderr: $err";
print "vcs_driving ok\n";
