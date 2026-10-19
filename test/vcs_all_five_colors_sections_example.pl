#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: combined-colour interactive preview ok
# expectexit: 0
use strict;
use warnings;
use IPC::Open3;
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
sub slurp { open(my$f,'<',$_[0]) or die$!;local$/;return <$f>; }
sub run {
   my$err=gensym;my$p=open3(my$i,my$o,$err,@_);close$i;
   local$/;my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   $?==0 or die "@_ failed\n$out$e";
   return$out;
}
my$fixture="$repo/test/fixtures/all_five_colors_sections_preview";
my$source="$fixture/interactive.c26";
my$bin="$tmp/preview.bin";
my$out=run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",$source,'-o',$bin);
-s$bin==8192 or die 'preview must be ordinary 8K F8';
my$sym=slurp("$tmp/preview.sym");
sub address { my$n=shift;$sym =~ /^\Q$n\E\s+([0-9a-fA-F]{4})\s*$/m or die "missing $n";return hex$1; }
my$mos="$repo/simulator/mos6502";
my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
for my$pair(['timing','vcs_frame_timing.cpp'],['controls','vcs_all_five_interactive_example_matrix.cpp']) {
   run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
      "$repo/test/$pair->[1]",$obj,'-o',"$tmp/$pair->[0]");
}
run("$tmp/timing",$bin,'420','--no-audio','--released-inputs','--raw-lines','264');
run("$tmp/controls",$bin,'all5_colors_sections_preview',address('game_object_x'),
   (map{address($_)}qw(game_player0_y game_player1_y game_missile0_y game_missile1_y game_ball_y selected_object select_switch_ready)),
   ('none')x4);
my@runtime=('--randomize-zp',address('game_object_x'),5,160,733,
   '--randomize-zp',address('game_player0_nusiz'),2,256,911);
for my$n(qw(game_player0_y game_player1_y game_missile0_y game_missile1_y game_ball_y)) {
   push@runtime,'--randomize-zp',address($n),1,256,955+scalar@runtime;
}
for my$n(qw(game_player0_height game_player1_height game_missile0_height game_missile1_height game_ball_height)) {
   push@runtime,'--randomize-zp',address($n),1,8,955+scalar@runtime;
}
run("$tmp/timing",$bin,'420','--no-audio','--released-inputs','--raw-lines','264',@runtime);
my$flat=slurp($source);
$flat =~ s#"(component|sprites).c26"#"$fixture/$1.c26"#g;
$flat =~ s/(section[1-8]_colu(?:pf|bk):=)0x[0-9a-f]+/${1}0x0e/g;
open(my$flat_file,'>',"$tmp/flat.c26") or die$!;print{$flat_file}$flat;close$flat_file;
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/flat.c26",'-o',"$tmp/flat.bin");
run("$tmp/timing","$tmp/flat.bin",'420','--no-audio','--released-inputs','--raw-lines','264');
# Independently pin all four raw frames: SPRITE_GLYPH reverses its arguments,
# whereas these ROM arrays are already bottom-to-top. Prevent a shared reversal
# or blank eighth row from masquerading as a good renderer comparison.
open(my$f,'<:raw',$bin) or die$!;local$/;my$rom=<$f>;close$f;
my@art=(
   ['p0_animation',[0x42,0xa5,0xbd,0xff,0xdb,0x7e,0x3c,0x66,
      0x24,0x5a,0xbd,0xff,0xdb,0x7e,0x5a,0x99,
      0x42,0xa5,0xbd,0xff,0xdb,0x7e,0x5a,0x81,
      0x81,0x5a,0xbd,0xff,0xdb,0x7e,0x3c,0x24]],
   ['p1_animation',[0xa5,0x5a,0x24,0xff,0xdb,0xff,0x66,0x3c,
      0x54,0x3c,0x42,0xff,0xdb,0xff,0x66,0x3c,
      0x24,0x5a,0x81,0xff,0xdb,0xff,0x66,0x3c,
      0x2a,0x3c,0x42,0xff,0xdb,0xff,0x66,0x3c]]);
for my$entry(@art) {
   substr($rom,4096+(address($entry->[0])&4095),32) eq pack('C*',@{$entry->[1]})
      or die "$entry->[0] artwork differs from the standard eight-row frames";
}
print "combined-colour interactive preview ok\n";
