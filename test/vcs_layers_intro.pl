#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: vcs_layers_intro ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use IPC::Open3;
use POSIX qw(:sys_wait_h setpgid);
use Symbol qw(gensym);
my($repo,$tmp)=@ARGV;
$repo=abs_path($repo); make_path($tmp); $tmp=abs_path($tmp);
require "$repo/test/stella_test_lib.pl";
my @children;
sub stop {
   my($pid)=@_; return unless $pid;
   kill 'TERM',-$pid;
   for(1..20){ my$r=waitpid($pid,WNOHANG);return if$r==$pid||$r==-1;select undef,undef,undef,.05; }
   kill 'KILL',-$pid; waitpid($pid,0);
}
END { my$status=$?;stop($_) for reverse @children;$?=$status; }
sub spawn {
   my($log,@cmd)=@_; my$p=fork(); defined$p or die "fork: $!";
   if(!$p){setpgid(0,0);open STDOUT,'>:raw',$log or die$!;open STDERR,'>&STDOUT' or die$!;exec @cmd;die "exec @cmd: $!";}
   eval{setpgid($p,$p)}; push @children,$p; return$p;
}
sub run {
   my(@cmd)=@_;my$err=gensym;my$p=open3(my$i,my$o,$err,@cmd);close$i;
   local$/;my$out=<$o>//'';my$e=<$err>//'';waitpid($p,0);
   $?==0 or die "@cmd\n$out$e";return$out;
}
sub readfile { open my$f,'<:raw',$_[0] or die "$!: $_[0]";local$/;return <$f>; }
sub save { open my$f,'>:raw',$_[0] or die "$!: $_[0]";print $f $_[1]; }
sub findexe {
   my($n)=@_;return abs_path($n) if -x$n;
   for(split /:/,$ENV{PATH}//''){return abs_path("$_/$n") if -x"$_/$n";}
   die "required executable: $n";
}
my$stella=findexe($ENV{VCSC_STELLA}||$ENV{STELLA}||'stella');
my$xvfb=findexe($ENV{VCSC_XVFB}||$ENV{XVFB}||'Xvfb');
my(undef,$display)=vcsc_reserve_x_display(270,20);
my$xp=spawn("$tmp/xvfb.log",$xvfb,$display,'-ac','-screen','0','1024x768x24');
vcsc_xvfb_assert_ready($display,$xp);
local$ENV{DISPLAY}=$display;local$ENV{XAUTHORITY}='/dev/null';local$ENV{SDL_AUDIODRIVER}='dummy';
sub snapshot {
   my($name)=@_;my$snap="$tmp/snap_$name";my$user="$tmp/user_$name";make_path($snap,$user);
   my$p=spawn("$tmp/stella_$name.log",$stella,vcsc_stella_palette_args($repo,$user),
      '-plr.bankrandom','0','-plr.ramrandom','0','-plr.tiarandom','0',
      '-dev.bankrandom','0','-dev.ramrandom','0','-dev.cpurandom','0','-dev.tiarandom','0',
      '-dev.hsrandom','0','-dev.tiadriven','0','-video','software','-turbo','1',
      '-audio.enabled','0','-bs','4K','-framesnap','200','-snapsavedir',$snap,
      '-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0',
      '-userdir',$user,"$tmp/$name.bin");
   my@png=vcsc_stella_wait_snapshots("$snap/*.png",1);stop($p);
   @children=grep{$_!=$p}@children;
   @png==1 or die "$name missing snapshot";
   return run($^X,"$repo/test/stella_png_rgb_digest.pl",$png[0]);
}
my$ancestor=readfile("$repo/libraries/vcs/renderers/all_five_player_color_192/all_five_player_color_192.c26");
# Replace horizontal positioning ONLY. The old vertical preparation/priming and
# visible drawing remain independent witnesses that the intro changes no state.
my$candidate=$ancestor;
$candidate=~s!   // Position all five objects during VBLANK.*?(?=   asm lda #1;\n   asm sta VDELBL;)!   intro_establish();\n!s or die 'position extraction marker';
for my$name(qw(object_x player0_nusiz player1_nusiz)){
   $candidate=~s/\bTEMPLATE_$name\b/layers_$name/g;
}
save("$tmp/vertical_and_draw.c26",$candidate);
my$objects=$candidate;
# This adapter is ONLY a witness: the shared owner has no PF cache or draw().
# Feed its outputs into the independent ancestor's unchanged visible pipeline.
$objects=~s!// Public state retains independent NUSIZ values\..*?(?=require inline void TEMPLATE_init)!uint8_t TEMPLATE_row_cache[14];\n\n!s or die 'remove legacy state';
my@shared=qw(object_x player0_y player1_y missile1_height missile1_y ball_y
   player0_graphics player1_graphics player0_height player1_height missile0_height
   missile0_y ball_height player0_nusiz player1_nusiz object_masks);
for my$n(@shared){$objects=~s/\bTEMPLATE_$n\b/layers_$n/g;}
my$bridge=<<'C26';
   layers_prepare_vertical();
   asm lda.a TEMPLATE_playfield;
   asm sta.z TEMPLATE_row_cache;
   asm lda.a TEMPLATE_playfield + 1;
   asm sta.z TEMPLATE_row_cache + 1;
   asm lda.a TEMPLATE_playfield + 2;
   asm sta.z TEMPLATE_row_cache + 2;
   asm lda.a TEMPLATE_playfield + 3;
   asm sta.z TEMPLATE_row_cache + 3;
   asm lda.z layers_ball_bits;
   asm sta.z TEMPLATE_row_cache + 4;
   asm lda.z layers_missile1_bits;
   asm sta.z TEMPLATE_row_cache + 5;
   asm lda.z layers_missile0_bits;
   asm sta.z TEMPLATE_row_cache + 6;
   asm lda #0;
   asm sta.z layers_object_masks + 2;
C26
$objects=~s!(require inline void TEMPLATE_vblank\(void\) \{).*?   intro_establish\(\);!$1\n$bridge   intro_establish();!s or die 'vertical extraction';
for my$p(0..1){
   $objects=~s/asm cpy.z layers_player${p}_height;/asm cpy.z layers_player${p}_limit;/g;
   $objects=~s/   asm dec.z layers_player${p}_height;\n// or die 'remove legacy height restore';
   # Use the shared counters throughout drawing, not a one-time copy into the
   # ancestor's dead mask lanes. Counter stepping now exercises the actual
   # shared state consumer, at the ancestor's independently certified phases.
   $objects=~s/\blayers_object_masks \+ $p;/layers_player${p}_counter;/g;
   my$steps=($objects=~s/   asm ldy.z layers_player${p}_counter;\n   asm dey;\n   asm sty.z layers_player${p}_counter;\n   asm cpy.z layers_player${p}_limit;/   layers_step_player$p();/g);
   $steps>=10 or die "missing P$p shared drawing steps";
}
save("$tmp/shared_vertical_and_draw.c26",$objects);
my$source=readfile("$repo/test/fixtures/all_five_player_color_192/all_five_match.c26");
my$mos="$repo/simulator/mos6502";
my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,
   "$repo/test/vcs_frame_timing.cpp",$obj,'-o',"$tmp/timing");
my$bindings=<<'C26';
instantiate "layers/all_five_intro.c26" as intro
C26
for my$case(0..3){
   my$s=$source;
   my@x=$case?(16,150,157,159,0):(0,13,14,15,159);
   my@name=qw(PLAYER0 PLAYER1 MISSILE0 MISSILE1 BALL);
    for my$i(0..4){$s=~s/(game_$name[$i]_X := )\d+;/$1$x[$i];/ or die "X $i";}
    if($case>=2){
       my@ys=$case==2?(4,4,4,4,4):(95,96,95,96,94);
       my@heights=$case==2?(3,1,2,4,3):(7,7,5,7,3);
       my@objects=qw(player0 player1 missile0 missile1 ball);
       for my$i(0..4){
          $s=~s/(game_$objects[$i]_y := )\d+;/$1$ys[$i];/ or die 'vertical pose';
          $s=~s/(game_$objects[$i]_height := )\d+;/$1$heights[$i];/ or die 'runtime height';
       }
       $s=~s/(game_PLAYER0_NUSIZ := )0x20;/${1}0x26;/ or die 'P0 copies';
       $s=~s/(game_PLAYER1_NUSIZ := )0x20;/${1}0x35;/ or die 'P1 copies';
       $s=~s/(game_player0_colors\[8\] := \{).*?\};/${1}0x0e,0x2e,0x4e,0x6e,0x8e,0xae,0xce,0xee };/s or die 'P0 row colours';
       $s=~s/(game_player1_colors\[8\] := \{).*?\};/${1}0xee,0xce,0xae,0x8e,0x6e,0x4e,0x2e,0x0e };/s or die 'P1 row colours';
       $s=~s/game_player0_graphics := p0_graphics;/game_player0_graphics := p1_graphics;/ or die 'P0 runtime pointer';
       $s=~s/game_player1_graphics := p1_graphics;/game_player1_graphics := p0_graphics;/ or die 'P1 runtime pointer';
    }
   my$gold_ram;
   for my$kind(qw(gold intro objects)){
      my$c=$s;
      if($kind eq'intro'){
         $c=~s!instantiate "renderers/all_five_player_color_192/all_five_player_color_192.c26" as game!$bindings\ninstantiate "$tmp/vertical_and_draw.c26" as game! or die 'component marker';
      }
      if($kind eq'objects'){
         $c=~s!instantiate "renderers/all_five_player_color_192/all_five_player_color_192.c26" as game!include "layers/all_five_objects.c26"\n$bindings\ninstantiate "$tmp/shared_vertical_and_draw.c26" as game! or die 'shared component marker';
         for my$n(@shared){$c=~s/\bgame_$n\b/layers_$n/g;}
      }
      my$n="${kind}_$case";save("$tmp/$n.c26",$c);
      my$build=run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/$n.c26",'-o',"$tmp/$n.bin");
      $build=~/ram\s+used=(\d+) bytes/ or die 'missing RAM budget';
      if($kind eq'gold'){$gold_ram=$1;}
      elsif($kind eq'intro'){$1==$gold_ram or die 'intro adds private RAM';}
       else{
          $1==$gold_ram+7&&$1<=128 or die 'shared-state witness budget';
          my$sym=readfile("$tmp/$n.sym");my@progress;
          for my$p(0..1){
             $c=~/layers_player${p}_y := (\d+);/ or die 'shared input Y';my$y=$1;
             $sym=~/^layers_player${p}_counter\s+([0-9a-fA-F]{4})\s*$/m or die 'shared counter symbol';
             push@progress,'--expect-memory',hex($1),($y+$p-96)&255;
          }
          run("$tmp/timing","$tmp/$n.bin",'420','--no-audio','--released-inputs','--raw-lines','264',@progress);
       }
   }
   my$gold=snapshot("gold_$case");
   $gold eq snapshot("intro_$case") or die "intro raster differs: case $case";
   $gold eq snapshot("objects_$case") or die "shared preparation raster differs: case $case";
   if(!$case){
      my$bad=$candidate;
      $bad=~s/   intro_establish\(\);/   asm nop;/ or die 'intro mutation marker';
      save("$tmp/no_position.c26",$bad);
      my$c=$s;
      $c=~s!instantiate "renderers/all_five_player_color_192/all_five_player_color_192.c26" as game!instantiate "$tmp/no_position.c26" as game! or die 'mutation component';
      save("$tmp/no_position_driver.c26",$c);
      run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/no_position_driver.c26",'-o',"$tmp/no_position.bin");
      $gold ne snapshot('no_position') or die 'missing intro is not detected';
   }
}
print "vcs_layers_intro ok\n";
