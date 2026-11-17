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
# Negative controls must fail on the behavior being tested, not build errors.
open my$s,'<',"$repo/examples/06_games/cinder_run/cinder_run.c26" or die$!;
my$source=do { local$/; <$s> }; close$s;
$source=~s{\.\./\.\./_common/cinder_run_raster\.c26}{$repo/examples/_common/cinder_run_raster.c26}g;
for my$mode(qw(no_kill thick_ceiling same_sound late_missile)) {
   my$broken=$source;
   if($mode eq 'no_kill') {
      $broken=~s/run_kill := CXM0P & 0x80;/run_kill := 0;/ or die 'kill boundary';
   }
   elsif($mode eq 'thick_ceiling') {
      $broken=~s/physics_top \+= 10;/physics_top += 16;/ or die 'ceiling boundary';
   }
   elsif($mode eq 'same_sound') {
      $broken=~s/run_sound := 0x26;/run_sound := 0x1a;/g or die 'sound boundary';
   }
   else {
      open my$r,'<',"$repo/examples/_common/cinder_run_raster.c26" or die$!;
      my$raster=do { local$/; <$r> }; close$r;
      $raster=~s/(asm adc #0;\n   )asm sta\.z game_workspace \+ 4;/${1}asm sta.z \$1b + TEMPLATE_object;/ or die 'enable boundary';
      open my$f,'>',"$tmp/late_raster.c26" or die$!; print{$f}$raster; close$f;
      $broken=~s{\Q$repo/examples/_common/cinder_run_raster.c26\E}{$tmp/late_raster.c26}g;
   }
   open my$f,'>',"$tmp/$mode.c26" or die$!; print{$f}$broken; close$f;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Map',"$tmp/$mode.map",
      "$tmp/$mode.c26",'-o',"$tmp/$mode.bin");
   my$p=fork(); defined$p or die$!;
   if(!$p) {
      open STDOUT,'>',"$tmp/$mode.log" or die$!;
      open STDERR,'>&STDOUT' or die$!;
      exec("$tmp/oracle","$tmp/$mode.bin","$tmp/$mode.map"); die$!;
   }
   waitpid($p,0); $?!=0 or die "$mode negative control passed\n";
   open my$l,'<',"$tmp/$mode.log" or die$!; my$log=do { local$/; <$l> }; close$l;
   my%reason=(no_kill=>'M0 kill did not remove shot',thick_ceiling=>'solid underside',
      same_sound=>'collection chime',late_missile=>'missile enable');
   my$reason=$reason{$mode};
   index($log,$reason)>=0 or die "$mode failed for the wrong reason: $log\n";
}
print "vcs_cinder_run ok\n";
