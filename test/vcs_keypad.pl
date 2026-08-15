#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: vcs_keypad ok
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
my$example_dir=File::Spec->catdir($repo,qw(examples 01_basic 11_keypad));
my$example=File::Spec->catfile($example_dir,'keypad.c26');
my$component=File::Spec->catfile($vcs,'keypad_controller.c26');
my$left_fixture=File::Spec->catfile($repo,qw(test fixtures keypad_left keypad_left.c26));
my$right_fixture=File::Spec->catfile($repo,qw(test fixtures keypad_right keypad_right.c26));

my$c=read_file($component);my$e=read_file($example);
$c =~ /parameter port := 0/ && $c =~ /TEMPLATE_keys/ && $c =~ /TEMPLATE_pressed/ &&
$c =~ /TEMPLATE_released/ && $c =~ /TEMPLATE_KEY_HASH := 12/ &&
$c =~ /SWACNT := SWACNT \| 0xf0/ && $c =~ /SWACNT := SWACNT \| 0x0f/ &&
$c =~ /INPT0/ && $c =~ /INPT1/ && $c =~ /INPT4/ && $c =~ /INPT2/ && $c =~ /INPT3/ && $c =~ /INPT5/
   or die "keypad component API or port mapping missing\n";
$c =~ /other controller port's nibble/ && $c =~ /400 microseconds/
   or die "keypad electrical/timing ownership documentation missing\n";
$c =~ /asm bit\.z INPT0/ && $c =~ /asm bit\.z INPT1/ && $c =~ /asm bit\.z INPT4/ &&
$c =~ /asm bit\.z INPT2/ && $c =~ /asm bit\.z INPT3/ && $c =~ /asm bit\.z INPT5/ &&
$c =~ /pressed key on the selected LOW row clears bit 7/
   or die "keypad active-low matrix scan regressed\n";
$e =~ /instantiate "keypad_controller\.c26" as left_keypad \(port:=0\)/ &&
$e =~ /instantiate "keypad_controller\.c26" as right_keypad \(port:=1\)/
   or die "public keypad example lost left\/right instances\n";
$e =~ /keypad_font\[130\]/ && $e !~ /fonts\/big_ascii\.c26/ &&
$e =~ /alias VCS_FONT_GLYPH\(a,b,c,d,e,f,g,h,i,j\)/ &&
$e =~ /asm ldy #9/ &&
$e =~ /vcs_ntsc_wait_component_scanlines\(90\)/ &&
$e =~ /vcs_ntsc_wait_visible_tail_scanlines\(92\)/
   or die "keypad example must use the trimmed 13-glyph 8x10 Big subset\n";
$e =~ /lda #36/ && $e =~ /lda #116/ && $e =~ /COLUBK := KEYPAD_BLUE/ &&
$e =~ /COLUP0 := KEYPAD_WHITE/ && $e =~ /COLUP1 := KEYPAD_WHITE/
   or die "keypad example lost centered P0\/P1 blue\/white display\n";
$e =~ /vcs_ntsc_begin_vblank\(\);\s*vcs_ntsc_end_vblank\(\);/s &&
$e =~ /vcs_ntsc_begin_overscan\(\);.*vcs_ntsc_wait_scanlines\(7\).*vcs_ntsc_end_overscan\(\);/s &&
$e =~ /keypad_scan_row == 3/ &&
$e =~ /left_keypad_read_row\(keypad_scan_row\)/ &&
$e =~ /right_keypad_read_row\(keypad_scan_row\)/
   or die "keypad example lost overscan four-frame matrix scan or >=400us settling\n";

sub build_rom {
   my($src,$dir,$bin,$map)=@_;
   my($rc,$sig,$out,$err)=capture($driver,'-I',$vcs,'-I',$dir,'-T',File::Spec->catfile($vcs,'vcs.cfg'),'-Map',$map,$src,'-o',$bin);
   $rc==0&&!$sig or die "keypad build failed for $src\n$out$err";
   $err eq '' or die "keypad build stderr for $src: $err";
}

my$left_bin=File::Spec->catfile($tmp,'keypad_left.bin');my$left_map=File::Spec->catfile($tmp,'keypad_left.map');
my$right_bin=File::Spec->catfile($tmp,'keypad_right.bin');my$right_map=File::Spec->catfile($tmp,'keypad_right.map');
my$example_bin=File::Spec->catfile($tmp,'keypad.bin');my$example_map=File::Spec->catfile($tmp,'keypad.map');
build_rom($left_fixture,File::Spec->catdir($repo,qw(test fixtures keypad_left)),$left_bin,$left_map);
build_rom($right_fixture,File::Spec->catdir($repo,qw(test fixtures keypad_right)),$right_bin,$right_map);
build_rom($example,$example_dir,$example_bin,$example_map);
-s$left_bin==2048 && -s$right_bin==2048 or die "keypad port fixtures are not 2K ROMs\n";
-s$example_bin==4096 or die "public keypad example is not a 4K ROM\n";

# Reproduce the relevant part of Stella's controller auto-detection contract.
# Keyboard needs BIT/branch access to both keypad input pairs (plus INPT4/5,
# which also establishes button use). But Stella deliberately upgrades a ROM
# that also contains one of its recognized SWCHA direction-read signatures to
# Joy2BPlus. Pin both halves: the public cartridge must look like Keyboard, not
# merely contain some Keyboard-looking bytes while still being classified as a
# different controller.
my $rom = read_file($example_bin);
my @stella_keyboard_signatures = (
   pack('C*',0x24,0x38,0x30), pack('C*',0x24,0x39,0x30), pack('C*',0x24,0x3c,0x30),
   pack('C*',0x24,0x3a,0x30), pack('C*',0x24,0x3b,0x30), pack('C*',0x24,0x3d,0x30),
);
index($rom,$_) >= 0 or die "public keypad ROM lost Stella Keyboard auto-detect signature\n"
   for @stella_keyboard_signatures;

my @stella_joystick_direction_signatures = (
   pack('C*',0xad,0x80,0x02), # lda SWCHA
   pack('C*',0xae,0x80,0x02), # ldx SWCHA
   pack('C*',0xac,0x80,0x02), # ldy SWCHA
   pack('C*',0x2c,0x80,0x02), # bit SWCHA
   pack('C*',0x0d,0x80,0x02), # ora SWCHA
   pack('C*',0x2d,0x80,0x02), # and SWCHA
   pack('C*',0x4d,0x80,0x02), # eor SWCHA
   pack('C*',0xad,0x88,0x02), # lda SWCHA|8
);
index($rom,$_) < 0 or die "public keypad ROM would Stella-classify as Joy2BPlus, not Keyboard\n"
   for @stella_joystick_direction_signatures;
index($rom,pack('C*',0xbd,0x80,0x02)) >= 0
   or die "keypad ROM lost detector-safe indexed SWCHA preservation read\n";

my$cxx=$ENV{CXX}||'c++';my$mos=File::Spec->catdir($repo,qw(simulator mos6502));my$mosobj=File::Spec->catfile($mos,'mos6502.o');my@mos=-f$mosobj?($mosobj):(File::Spec->catfile($mos,'mos6502.cpp'));
my$oracle_src=File::Spec->catfile($repo,qw(test vcs_keypad.cpp));my$oracle=File::Spec->catfile($tmp,'vcs_keypad_oracle');
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2','-DILLEGAL_OPCODES','-I',$mos,$oracle_src,@mos,'-o',$oracle);
$rc==0&&!$sig or die "keypad oracle build failed\n$out$err";

for my $case (
   [$left_bin,$left_map,0],
   [$right_bin,$right_map,1],
) {
   my($bin,$mapfile,$side)=@$case;my$m=read_file($mapfile);
   my@a=map{sprintf('0x%04x',symbol_addr($m,$_))}qw(keypad_keys keypad_pressed keypad_released keypad_key);
   ($rc,$sig,$out,$err)=capture($oracle,'fixture',$bin,@a,$side);
   $rc==0&&!$sig or die "keypad side-$side oracle failed\n$out$err";
   $out =~ /vcs_keypad ok:/ or die "unexpected keypad side-$side output: $out";
   $err eq '' or die "keypad side-$side oracle stderr: $err";
}

my$m=read_file($example_map);
my@a=map{sprintf('0x%04x',symbol_addr($m,$_))}qw(
   left_keypad_keys left_keypad_pressed left_keypad_released left_keypad_key
   right_keypad_keys right_keypad_pressed right_keypad_released right_keypad_key
);
($rc,$sig,$out,$err)=capture($oracle,'example',$example_bin,@a);
$rc==0&&!$sig or die "public keypad example oracle failed\n$out$err";
$out =~ /vcs_keypad ok:/ or die "unexpected public keypad output: $out";
$err eq '' or die "public keypad oracle stderr: $err";
print "vcs_keypad ok\n";
