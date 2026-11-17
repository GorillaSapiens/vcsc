#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 45
# expectstdout: vcs_cinder_run ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
my($repo,$tmp)=@ARGV;
$repo=abs_path($repo); make_path($tmp); $tmp=abs_path($tmp);
sub run {
   open my$f,'-|',@_ or die "$!";
   local$/; my$out=<$f>//'';
   close$f or die "@_ failed\n$out";
   return$out;
}
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Map',"$tmp/game.map",
   "$repo/examples/06_games/cinder_run/cinder_run.c26",'-o',"$tmp/game.bin");
-s "$tmp/game.bin"==8192 or die "expected 8K F8 ROM\n";
# Exercise every declared mutable-playfield profile, not just this game's 181.
for my$lines(170,181,192,228) {
   my$bytes=$lines==170 ? 40 : $lines==181 ? 44 : $lines==192 ? 48 : 60;
   open my$f,'>',"$tmp/profile$lines.c26" or die$!;
   print{$f} "include \"4K/mapper.c26\"\n";
   print{$f} "instantiate \"renderers/player_color/player_color.c26\" as game (lines:=$lines, mutable_playfield:=1)\n";
   print{$f} "uint8_t game_playfield[$bytes];\n";
   print{$f} "page const uint8_t game_player0_colors[8] := {0,0,0,0,0,0,0,0};\n";
   print{$f} "page const uint8_t game_player1_colors[8] := {0,0,0,0,0,0,0,0};\n";
   print{$f} "void main(void) { game_init(); game_vblank(); game_draw(); game_overscan(); }\n";
   close$f;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Map',"$tmp/profile$lines.map",
      "$tmp/profile$lines.c26",'-o',"$tmp/profile$lines.bin");
   open my$m,'<',"$tmp/profile$lines.map" or die$!; local$/; my$map=<$m>; close$m;
   $map=~/^\s*\$([0-9a-f]{4})\s+game_playfield\b/im or die "missing RAM playfield\n";
   hex($1)>=0x80 && hex($1)+$bytes<=0x100 or die "mutable playfield crossed RIOT RAM page\n";
}
my$mos="$repo/simulator/mos6502";
run($ENV{CXX}||'c++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-O2',
   '-DILLEGAL_OPCODES','-I',$mos,"$repo/test/vcs_cinder_run.cpp",
   (-f "$mos/mos6502.o" ? "$mos/mos6502.o" : "$mos/mos6502.cpp"),'-o',"$tmp/oracle");
run("$tmp/oracle","$tmp/game.bin","$tmp/game.map") eq "cinder_run CPU ok\n" or die "unexpected oracle output\n";
print "vcs_cinder_run ok\n";
