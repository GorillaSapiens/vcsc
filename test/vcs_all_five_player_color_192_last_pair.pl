#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 90
# expectstdout: vcs_all_five_player_color_192_last_pair ok
# expectexit: 0

# Independent preparation contract: both missile masks must include pair95.
# Check the CPU-produced packed byte, not another renderer or a decoded table.
use strict;
use warnings;
use Cwd qw(abs_path);
my($repo,$tmp,$old_limit)=@ARGV;
$repo=abs_path($repo);$tmp=abs_path($tmp);
sub slurp {open(my$f,'<',$_[0])or die$!;local$/;return<$f>;}
sub save {open(my$f,'>',$_[0])or die$!;print{$f}$_[1];close$f or die$!;}
sub run {system(@_)==0 or die "@_ failed\n";}
my$c=slurp("$repo/test/fixtures/all_five_player_color_192/smoke.c26");
for my$n(0,1){
   $c =~ s/game_missile${n}_y := \d+;/game_missile${n}_y := 95;/ or die 'missile Y';
   $c =~ s/game_missile${n}_height := \d+;/game_missile${n}_height := 3;/ or die 'missile height';
}
$c =~ s/void main\(void\)/void prepared(void) { asm nop; }\nvoid main(void)/ or die 'prepared function';
$c =~ s/(      game_vblank\(\);)/$1\n      prepared();/ or die 'prepared stop';
if($old_limit){
   my$component=slurp("$repo/libraries/vcs/renderers/all_five_player_color_192/all_five_player_color_192.c26");
   $component =~ s/(   \/\/ Missiles[^\n]*\n)   asm lda #96;/${1}   asm lda #95;/ or die 'old missile limit';
   save("$tmp/old_component.c26",$component);
   $c =~ s!"renderers/all_five_player_color_192/all_five_player_color_192.c26"!"$tmp/old_component.c26"! or die 'old component instance';
}
save("$tmp/probe.c26",$c);
run("$repo/driver/vcsc",'-I',"$repo/libraries/vcs","$tmp/probe.c26",'-o',"$tmp/probe.bin");
my$sym=slurp("$tmp/probe.sym");my%address;
for my$name(qw(prepared game_object_masks)){
   $sym =~ /^\Q$name\E\s+([0-9a-fA-F]{4})\s*$/m or die "missing $name";
   $address{$name}=hex$1;
}
my$mos="$repo/simulator/mos6502";my$obj=-f"$mos/mos6502.o"?"$mos/mos6502.o":"$mos/mos6502.cpp";
run($ENV{CXX}||'c++','-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,"$repo/test/vcs_frame_timing.cpp",$obj,'-o',"$tmp/timing");
# Row11 packed lane carries BL/M1/M0 in D1/D2/D3. Ball is far above it.
run("$tmp/timing","$tmp/probe.bin",'200','--no-audio','--released-inputs',
   '--stop-pc',$address{prepared},'--expect-memory',$address{game_object_masks}+47,0x0c);
print "vcs_all_five_player_color_192_last_pair ok\n";
