#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: vcs_all_five_sections_component ok
# expectexit: 0
use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
defined$tmp or die "usage: $0 REPO TMP\n";
my$driver="$repo/driver/vcsc";
my$fixture="$repo/test/fixtures/all_five_player_color_192/all_five_match.c26";
open(my$f,'<',$fixture) or die$!; local$/; my$source=<$f>; close$f;
my$args=join(',', 'section1_lines:=6','section2_lines:=2','section3_lines:=6',
   'section4_lines:=2','section5_lines:=2','section6_lines:=10',
   'section7_lines:=34','section8_lines:=130','section8_colubk:=0x64');
$source =~ s#instantiate "renderers/all_five_player_color_192/all_five_player_color_192.c26" as game#instantiate "renderers/all_five_sections_192/all_five_sections_192.c26" as game ($args)#
   or die "fixture configuration missing\n";
sub run {
   my$err=gensym; my$p=open3(my$i,my$o,$err,@_); close$i;
   my$out=<$o>//''; my$e=<$err>//''; waitpid($p,0);
   return($?,$out,$e);
}
sub build {
   my($name,$s,$valid)=@_;
   my$file="$tmp/$name.c26"; open(my$w,'>',$file) or die$!; print{$w}$s; close$w;
   my($rc,$o,$e)=run($driver,'-I',"$repo/libraries/vcs",$file,'-o',"$tmp/$name.bin");
   if($valid) { !$rc or die "$name failed: $o$e"; -s"$tmp/$name.bin"==4096 or die "$name not 4K\n"; }
   else { $rc&&$e =~ /Section heights|section_colours_must_be_bytes|requires an integer literal/i or die "$name was not rejected by configuration validation: $o$e"; }
}
build('lifecycle',$source,1);
my$default=$source; $default =~ s/(as game) \(.*?\)/$1/s or die "example configuration missing\n";
build('default',$default,1);
my$two=$source; $two =~ s/(as game) \(.*?\)/$1 (section1_lines:=30,section2_lines:=162)/s;
build('two',$two,1);
for my$case(['odd', 'section1_lines:=6','section1_lines:=5'],
            ['total','section8_lines:=130','section8_lines:=128'],
            ['colour','section8_colubk:=0x64','section8_colubk:=256'],
            ['negative','section2_lines:=2','section2_lines:=-2'],
            ['empty_first','section1_lines:=6','section1_lines:=0']) {
   my($name,$from,$to)=@$case; my$s=$source; $s =~ s/\Q$from\E/$to/ or die "missing $from\n";
   build($name,$s,0);
}
my$mos="$repo/simulator/mos6502";
my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
my($rc,$o,$e)=run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   "$repo/test/vcs_frame_timing.cpp",$obj,'-o',"$tmp/timing");
!$rc or die "timing build: $o$e";
($rc,$o,$e)=run("$tmp/timing","$tmp/lifecycle.bin",'420','--no-audio','--raw-lines','264');
!$rc or die "example timing: $o$e";
print "vcs_all_five_sections_component ok\n";
