#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
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
-s "$tmp/game.bin"==16384 or die "expected 16K F6SC ROM\n";
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
$source=~s{\.\./\.\./_common/(\w+\.c26)}{$repo/examples/_common/$1}g;
for my$mode(qw(no_kill thick_ceiling bad_inverse forgotten_treasure chasing_monster red_monsters no_music superchip_dummy same_speed wrong_target no_respawn_delay facing_spawns treasure_gunfire resurrected_cache camera_respawn)) {
   my$broken=$source;
   if($mode eq 'no_kill') {
      $broken=~s/run_kill := CXM0P & 0x80;/run_kill := 0;/ or die 'kill boundary';
   }
   elsif($mode eq 'thick_ceiling') {
       $broken=~s/asm adc #10;/asm adc #16;/ or die 'ceiling boundary';
   }
   elsif($mode eq 'bad_inverse') {
      $broken=~s/asm eor #\$b4;/asm eor #\$b5;/ or die 'inverse boundary';
   }
   elsif($mode eq 'forgotten_treasure') {
       $broken=~s/asm ora.ax treasure_taken,x;/asm lda #0;/ or die 'treasure boundary';
   }
   elsif($mode eq 'red_monsters') {
      $broken=~s/asm lda.ax hazard_colors,x;/asm lda #\$46;/ or die 'monster color boundary';
   }
    elsif($mode eq 'no_music') {
      $broken=~s/AUDV1 := 2;/AUDV1 := 0;/ or die 'music boundary';
    }
    elsif($mode eq 'superchip_dummy') {
       open my$k,'<',"$repo/examples/_common/cinder_run_wide.c26" or die$!;
       my$kernel=do {local$/;<$k>};close$k;
       $kernel=~s/asm tya;\n   asm and #\$0f;\n   asm tay;\n   asm lda.ay game_reposition_table,y;/asm lda game_reposition_table + 16 - 256,y;/ or die 'Superchip lookup boundary';
       open my$kout,'>',"$tmp/unsafe_wide.c26" or die$!;print{$kout}$kernel;close$kout;
       $broken=~s{\Q$repo/examples/_common/cinder_run_wide.c26\E}{$tmp/unsafe_wide.c26} or die 'Superchip kernel relocation';
    }
    elsif($mode eq 'same_speed') {
       $broken=~s/(hazard_tick_mask\[8\]\s*:=\s*)\{[^}]+\}/${1}{1,1,1,1,1,1,1,1}/ or die 'monster speed boundary';
    }
    elsif($mode eq 'wrong_target') {
       $broken=~s/(if \(run_shot_y > (?:29|45|61)\) \{ enemy_index := )[123];/${1}0;/g or die 'target slot boundary';
    }
    elsif($mode eq 'no_respawn_delay') {
       $broken=~s/asm adc #48;/asm lda #1;/ or die 'respawn delay boundary';
    }
    elsif($mode eq 'facing_spawns') {
       $broken=~s/asm bcc.same \@spawn;/asm bit.a run_facing;\n   asm bpl.same \@spawn;/ or die 'random spawn side boundary';
    }
    elsif($mode eq 'treasure_gunfire') {
       $broken=~s/run_sound := 0x8c;/run_sound := 0x26;/ or die 'treasure chime boundary';
    }
    elsif($mode eq 'resurrected_cache') {
       $broken=~s/asm lda.ax enemy_delay,x;\n   asm beq.same \@active_art;/asm lda #0;\n   asm beq.same \@active_art;/ or die 'waiting artwork boundary';
    }
    elsif($mode eq 'camera_respawn') {
       $broken=~s/asm lda.ax enemy_delay,x;\n   asm bne.same \@camera_left_next;/asm lda #0;\n   asm bne.same \@camera_left_next;/ or die 'waiting camera boundary';
    }
   else {
       $broken=~s/asm lda.ax enemy_direction,x;/asm lda #1;/ or die 'monster boundary';
   }
   open my$f,'>',"$tmp/$mode.c26" or die$!; print{$f}$broken; close$f;
   run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs",'-Map',"$tmp/$mode.map",
      "$tmp/$mode.c26",'-o',"$tmp/$mode.bin");
   my$p=fork(); defined$p or die$!;
   if(!$p) {
      open STDOUT,'>',"$tmp/$mode.log" or die$!;
      open STDERR,'>&STDOUT' or die$!;
        my%scenario=(no_kill=>0,thick_ceiling=>0,bad_inverse=>1,forgotten_treasure=>3,chasing_monster=>4,red_monsters=>4,no_music=>1,superchip_dummy=>0,same_speed=>4,wrong_target=>5,no_respawn_delay=>5,facing_spawns=>5,treasure_gunfire=>0,resurrected_cache=>5,camera_respawn=>6);
       exec("$tmp/oracle","$tmp/$mode.bin","$tmp/$mode.map",$scenario{$mode}); die$!;
   }
   waitpid($p,0); $?!=0 or die "$mode negative control passed\n";
   open my$l,'<',"$tmp/$mode.log" or die$!; my$log=do { local$/; <$l> }; close$l;
   my%reason=(no_kill=>'M0 kill did not remove shot',thick_ceiling=>'solid underside',bad_inverse=>'LFSR forward/inverse',
       forgotten_treasure=>'collected treasure flag',chasing_monster=>'monster stopped or turned',
        red_monsters=>'monster type did not select its tint',no_music=>'music volume envelope',
        superchip_dummy=>'indexed dummy read hits Superchip write port',same_speed=>'independent monster speed/direction',
        wrong_target=>'shot reset wrong enemy slot',no_respawn_delay=>'targeted shot did not enter respawn delay',
        facing_spawns=>'random spawn side depends on facing',treasure_gunfire=>'treasure did not use its own chime voice',
        resurrected_cache=>'defeated monster reappeared during delay',camera_respawn=>'camera respawned waiting enemy');
   my$reason=$reason{$mode};
   index($log,$reason)>=0 or die "$mode failed for the wrong reason: $log\n";
}
print "vcs_cinder_run ok\n";
