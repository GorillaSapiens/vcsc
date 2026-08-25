#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_ode_to_joy_cartridge ok
# expectexit: 0


use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub read_file {
   my ($path)=@_;
   open(my $fh, '<:raw', $path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh) or die "could not close $path: $!\n";
   return defined($d)?$d:'';
}
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($?>>8,$?&127,$stdout,$stderr);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs_dir=File::Spec->catfile($repo,'libraries','vcs');
my $sound=File::Spec->catfile($vcs_dir,'sound_ntsc.c26');
my $source=File::Spec->catfile($repo,'examples','01_basic','03_ode_to_joy','ode_to_joy.c26');
my $binary=File::Spec->catfile($tmp,'ode_to_joy.bin');
my $map=File::Spec->catfile($tmp,'ode_to_joy.map');
my $timing_source=File::Spec->catfile($repo,'test','vcs_frame_timing.cpp');
my $timing_exe=File::Spec->catfile($tmp,'vcs_frame_timing');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');

-x $driver or die "compiler driver is not executable: $driver\n";
-f $source or die "example source is missing: $source\n";
-f $sound or die "sound alias library is missing: $sound\n";
-f $timing_source or die "timing harness source is missing: $timing_source\n";
-f $mos_source or die "6502 emulator source is missing: $mos_source\n";

my ($exit,$signal,$stdout,$stderr)=run_capture(
   $driver,'-I',$vcs_dir,'-Map',$map,$source,'-o',$binary,
);
die "cartridge build exited $exit signal $signal\nstdout:\n$stdout\nstderr:\n$stderr"
   if $exit != 0 || $signal != 0;
die "cartridge build wrote unexpected stdout:\n$stdout" if without_cartridge_usage($stdout) ne '';
die "cartridge build wrote unexpected stderr:\n$stderr" if $stderr ne '';

my $rom=read_file($binary);
length($rom)==4096 or die "raw cartridge size is ".length($rom).", expected 4096\n";
my ($nmi,$reset,$irq)=unpack('v3',substr($rom,0x0ffa,6));
for my $entry ([NMI=>$nmi],[RESET=>$reset],[IRQ=>$irq]) {
   my ($name,$address)=@$entry;
   $address>=0xf000 && $address<=0xffff
      or die sprintf("%s vector %04x is outside cartridge ROM\n",$name,$address);
}


# Fourteen quarter notes, one half note, and one eighth-note rest. Every step
# is followed by a two-frame silent step so repeated notes remain articulated.
my @quarter_pitches=(15,15,14,12,12,14,15,17,19,19,17,15,15,17);
my @notes;
for my $pitch (@quarter_pitches) {
   push @notes,[8,$pitch,12,29],[0,19,12,1];
}
push @notes,[8,17,12,59],[0,19,12,1];
push @notes,[0,19,12,14],[0,19,12,1];
@notes==32 or die "internal expected-score construction error\n";
my $score=pack('C*',map {@$_} @notes);
length($score)==128 or die "internal expected score is not 128 bytes\n";
index($rom,$score)>=0 or die "ROM does not contain the expected 128-byte score table\n";

my $map_text=read_file($map);
$map_text =~ /^\s+\$([0-9A-Fa-f]{4})\s+__reset\s+/m or die "map is missing __reset\n";
hex($1)==$reset or die sprintf("RESET vector %04x disagrees with map __reset %04x\n",$reset,hex($1));
$map_text =~ /ram\s+start=\$0080\s+size=\$007A\s+type=rw/
   or die "map does not expose the call-graph-sized RIOT RAM arena\n";
$map_text =~ /region=ram\s+depth=2\s+bytes=\$0006\s+physical=\$00FA-\$00FF/
   or die "map does not report the expected two-source-call plus full-startup hardware-stack reserve\n";
$map_text =~ /__stack_top\s+\$00F9/
   or die "map does not stop ordinary allocation below the computed stack reserve\n";
$map_text =~ /BSS\.__vcsc_object\$music_index\s+run=\$0084\s+size=\$0001/
   or die "zero-initialized music_index is not the first one-byte player-state object after startup workspace\n";
$map_text =~ /DATA\.__vcsc_object\$music_counter\s+load=\$[0-9A-F]+\s+run=\$0085\s+size=\$0001/
   or die "music_counter is not the second one-byte player-state object after startup workspace\n";
$map_text =~ /\bmusic\b/ or die "map is missing ROM score symbol music\n";
$map_text =~ /\bmusic_index\b/ or die "map is missing music_index\n";
$map_text !~ /\bmusic_current\b/ or die "map still contains obsolete music_current\n";
$map_text !~ /\bmusic_steps_left\b/ or die "map still contains obsolete music_steps_left\n";
$map_text =~ /\bmusic_counter\b/ or die "map is missing music_counter\n";
$map_text =~ /\bmusic_tick\b/ or die "map is missing music_tick\n";
$map_text =~ /\bmusic_apply_current\b/ or die "map is missing music_apply_current\n";
$map_text =~ /RODATA\.__vcsc_object\$music\s+load=\$[0-9A-F]+\s+size=\$0080/
   or die "score is not a distinct 128-byte RODATA object\n";

my $source_text=read_file($source);
$source_text =~ /alias\s+MUSIC_STEP_COUNT\s+32/
   or die "source does not declare 32 score steps\n";
my $gap_uses=()=$source_text =~ /MUSIC_TIME_GAP/g;
$gap_uses==16 or die "source has $gap_uses gap steps, expected 16\n";
$source_text !~ /\basm\b/
   or die "Ode to Joy contains inline assembly\n";
$source_text =~ /TIM64T\s*:=\s*42\s*;/ && $source_text =~ /TIM64T\s*:=\s*35\s*;/
   or die "Ode to Joy lost the calibrated timer-owned blanking deadlines\n";
$source_text =~ /WSYNC\s*:=\s*2\s*;\s*VSYNC\s*:=\s*2\s*;\s*WSYNC\s*:=\s*0\s*;\s*WSYNC\s*:=\s*0\s*;\s*WSYNC\s*:=\s*0\s*;\s*VSYNC\s*:=\s*0\s*;/s
   or die "Ode to Joy lost exact same-phase VSYNC sequence\n";
my @timer_waits=($source_text =~ /while\s*\(\s*!\s*\(\s*TIMINT\s*&\s*0x80\s*\)\s*\)/g);
@timer_waits == 2 or die "Ode to Joy must wait on TIMINT in both blanking phases\n";
$source_text =~ /TIM64T\s*:=\s*42\s*;.*?while\s*\(\s*!\s*\(\s*TIMINT\s*&\s*0x80\s*\)\s*\).*?WSYNC\s*:=\s*_\s*;\s*VBLANK\s*:=\s*0\s*;/s
   or die "Ode to Joy lost timer-owned VBLANK deadline/alignment\n";
$source_text =~ /TIM64T\s*:=\s*35\s*;\s*music_tick\(\);.*?WSYNC\s*:=\s*_\s*;\s*while\s*\(\s*!\s*\(\s*TIMINT\s*&\s*0x80\s*\)\s*\).*?WSYNC\s*:=\s*_\s*;/s
   or die "music_tick is not enclosed by the calibrated phase-normalized overscan tail\n";
$source_text =~ /uint8_t\s+music_index\s*:=\s*0\s*;/
   or die "source does not retain the current score index\n";
$source_text =~ /uint8_t\s+music_counter\s*:=\s*0xff\s*;/
   or die "source does not use the pre-first-note counter sentinel\n";
$source_text =~ /AUDV0\s*:=\s*0\s*;/
   or die "source does not explicitly silence channel 0 before the first frame\n";
$source_text !~ /AUDV1\s*:=\s*0\s*;\s*music_apply_current\(\)\s*;/s
   or die "first note is still applied before frame synchronization\n";
$source_text =~ /void\s+music_tick\s*\(void\)\s*\{.*music_counter\s*==\s*0xff.*music_counter\s*:=\s*0.*music_apply_current\(\).*return.*music_counter\+\+.*music\[music_index\]\.timing.*music_index\+\+.*music_index\s*==\s*MUSIC_STEP_COUNT.*music_apply_current\(\)/s
   or die "music_tick does not synchronize the first note before direct indexed playback\n";
$source_text =~ /void\s+music_apply_current\s*\(void\)\s*\{.*AUDV0\s*:=\s*0\s*;.*AUDC0\s*:=\s*music\[music_index\]\.control.*AUDF0\s*:=\s*music\[music_index\]\.frequency.*AUDV0\s*:=\s*music\[music_index\]\.volume/s
   or die "source does not mute before retuning and enable channel-0 volume last\n";
-f File::Spec->catfile($repo,'examples','01_basic','03_ode_to_joy','music_player.s26')
   and die "obsolete companion assembly player still exists\n";

my $cxx=$ENV{CXX} || 'c++';
($exit,$signal,$stdout,$stderr)=run_capture(
   $cxx,'-std=c++17','-O2','-I',$mos_dir,$timing_source,$mos_source,'-o',$timing_exe,
);
die "timing harness build exited $exit signal $signal\nstdout:\n$stdout\nstderr:\n$stderr"
   if $exit != 0 || $signal != 0;
die "timing harness build wrote unexpected stdout:\n$stdout" if without_cartridge_usage($stdout) ne '';

($exit,$signal,$stdout,$stderr)=run_capture($timing_exe,$binary,'1500','--audio-start-synced','--audio-retune-muted','--raw-lines','264');
die "timing verification exited $exit signal $signal\nstdout:\n$stdout\nstderr:\n$stderr"
   if $exit != 0 || $signal != 0;
$stdout =~ /^vcs_frame_timing ok: 1497 frames at 262 lines, \d+ AUDV0 writes\n$/
   or die "unexpected timing-verifier output:\n$stdout";
die "timing verifier wrote unexpected stderr:\n$stderr" if $stderr ne '';

print "vcs_ode_to_joy_cartridge ok\n";
