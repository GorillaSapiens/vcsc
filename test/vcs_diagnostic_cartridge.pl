#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: diagnostic cartridge passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub run_capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=run_capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
}
sub read_file {
   my($p)=@_; open(my $fh,'<',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub map_symbol_addr {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map missing $name\n";
   return hex($1);
}
sub parse_dump {
   my($text)=@_; my @mem=(0) x 65536;
   for my $line (split /\n/,$text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($count,$addr,$bytes)=(hex($1),hex($2),$3);
      length($bytes)==$count*2 or die "bad Intel HEX dump record\n";
      for my $i (0..$count-1) { $mem[$addr+$i]=hex(substr($bytes,$i*2,2)); }
   }
   return \@mem;
}
sub switch_sequence {
   my($length,$down,@starts)=@_;
   my @values=(0xff) x $length;
   for my $start (@starts) {
      for my $i ($start..$start+7) { $values[$i]=$down; }
   }
   return join(',',map { sprintf('0x%02x',$_) } @values);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $example=File::Spec->catdir($repo,qw(examples 19_diagnostic 01_diagnostic));
my $source=File::Spec->catfile($example,'vcsc_diagnostic.c26');
my $boot=File::Spec->catfile($example,'diagnostic_boot.s26');
my $indices=File::Spec->catfile($example,'diagnostic_pair_indices.c26');
my $pairs=File::Spec->catfile($example,'pairs_message.txt');
my $pair_font=File::Spec->catfile($example,'diagnostic_pairs.c26');
my $half_font=File::Spec->catfile($vcs,qw(fonts half_ascii.c26));
my $pair_helper=File::Spec->catfile($vcs,qw(fonts make_pair_font.pl));
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');

my $src=read_file($source);
my $idx=read_file($indices);
my $msg=read_file($pairs);
my $pair_text=read_file($pair_font);
my $half_text=read_file($half_font);

# The diagnostic pair table is checked in because rendering must be cheap on
# the 2600, but it is generated from Half.  Compare the actual row bytes with
# a fresh make_pair_font.pl --score run so Half readability fixes cannot leave
# stale pre-cooked diagnostic glyphs behind.
$pair_text =~ /^\/\/ Message: "([^"]*)"$/m
   or die "diagnostic pair font lost its source message\n";
my $pair_message=$1;
my($pair_rc,$pair_sig,$pair_out,$pair_err)=run_capture($pair_helper,'--score',$half_font,$pair_message);
$pair_rc==0 && !$pair_sig or die "regenerate diagnostic pair font failed\n$pair_out$pair_err";
$pair_err eq '' or die "regenerate diagnostic pair font wrote stderr:\n$pair_err";
my @checked_rows=$pair_text =~ /0b([.X]{8})/g;
my @generated_rows=$pair_out =~ /0b([.X]{8})/g;
@checked_rows==936 && @generated_rows==936
   or die "diagnostic pair font row count changed\n";
join('',@checked_rows) eq join('',@generated_rows)
   or die "diagnostic_pairs.c26 is stale relative to half_ascii.c26\n";
$src =~ /DIAG_PAIR_CO.*DIAG_PAIR_LR/s &&
$src =~ /DIAG_PAIR_BAMP.*DIAG_PAIR_W_SPACE/s &&
$idx =~ /DIAG_PAIR_LR\s*:=\s*36,\s*\/\/ 'LR'/ &&
$idx =~ /DIAG_PAIR_BAMP\s*:=\s*37,\s*\/\/ 'B&'/ &&
$idx =~ /DIAG_PAIR_W_SPACE\s*:=\s*105,\s*\/\/ 'W '/ &&
$msg =~ /COLRB&/ && $msg =~ /W A SSFAIL/
   or die "diagnostic COLOR/B&W labels are not pre-cooked as COLR and B&W\n";

$src =~ /bank4 void diagnostic_driving_vblank\(void\).*?diagnostic_left_drive_begin_frame\(\);.*?diagnostic_right_drive_begin_frame\(\);.*?diagnostic_left_drive_sample\(\);.*?diagnostic_right_drive_sample\(\);.*?diagnostic_drive_position0.*?diagnostic_drive_position1/s
   or die "diagnostic driving mode lost its once-per-frame VBLANK sample\n";
$src !~ /diagnostic_driving_overscan/
   or die "diagnostic driving mode must not sample again in overscan\n";

$src =~ /bank0 void diagnostic_draw_tia_panel\(void\).*?PF0 := 0xf0;.*?GRP0 := 0xff;.*?GRP1 := 0x81;.*?ENAM0 := 2;.*?ENAM1 := 2;.*?ENABL := 2;.*?RESMP0 := 2;.*?RESMP1 := 2;.*?RESMP0 := 0;.*?RESMP1 := 0;.*?PF0 := 0xff; PF1 := 0xff; PF2 := 0xff;.*?asm lda CXM0P;.*?asm and CXM1P;.*?asm and #\$40;.*?asm asl;.*?asm and CXBLPF;/s
   or die "diagnostic TIA panel lost an object, forced collision geometry, or collision self-test\n";
$src =~ /bank0 const uint8_t diagnostic_audio0\[64\].*?6,6,6,6/s &&
$src =~ /bank0 const uint8_t diagnostic_audio1\[64\].*?6,6,6,6/s &&
$src =~ /bank0 void diagnostic_audio_tick\(void\).*?asm ldx diagnostic_audio_phase;.*?asm lda diagnostic_audio0,x;.*?asm sta AUDV0;.*?asm lda diagnostic_audio1,x;.*?asm sta AUDV1;.*?asm sta diagnostic_audio_phase;/s &&
$src =~ /cartram uint8_t diagnostic_tia_collision_pass;/ &&
$src =~ /AUDC0 := 4; AUDC1 := 4;.*?AUDF0 := 10; AUDF1 := 4;/s
   or die "diagnostic dual-channel audio cadence or cartridge-RAM TIA state is incomplete\n";
$idx =~ /DIAG_PAIR_A_SPACE\s*:=\s*106/ && $idx =~ /DIAG_PAIR_SS\s*:=\s*107/ &&
$idx =~ /DIAG_PAIR_FA\s*:=\s*108/ && $idx =~ /DIAG_PAIR_IL\s*:=\s*109/
   or die "diagnostic TIA PASS/FAIL labels are not pre-cooked\n";

my $boot_text=read_file($boot);
$boot_text =~ /lda \$80,x.*?cmp #\$6c.*?lda \$81,x.*?cmp #\$fc.*?lda \$82,x.*?cmp #\$ff.*?lda \$83,x.*?cmp #\$ea.*?cpx #\$7d/s &&
$boot_text =~ /\@clear_riot:.*?sta \$80,x.*?\@clear_superchip:.*?sta \$f000,x.*?\@clear_tia:.*?sta \$00,x.*?tya.*?sta \$f000/s
   or die "diagnostic boot shim lost pre-clear 7800 signature capture or startup clearing\n";
$src =~ /cartram uint8_t diagnostic_boot_7800;\s*cartram uint24_t diagnostic_cpu_fingerprint;/s &&
$src =~ /ARR #\$b8.*?ARR #\$6b.*?ARR #\$6b.*?ARR #\$6b/s &&
$src =~ /diagnostic_compute_cpu_fingerprint\(\);.*?diagnostic_format_boot_rows\(\);/s
   or die "diagnostic CPU fingerprint capture/display path is incomplete\n";
$idx =~ /DIAG_PAIR_NUM_26\s*:=\s*110/ && $idx =~ /DIAG_PAIR_NUM_78\s*:=\s*111/ &&
$idx =~ /DIAG_PAIR_F_SPACE\s*:=\s*116/ && $idx =~ /DIAG_PAIR_COUNT\s*:=\s*117/
   or die "diagnostic platform/fingerprint pair indices are incomplete\n";
$src =~ /DIAGNOSTIC_TV_SECAM.*?COLUP0 := VCS_SECAM_YELLOW;\s*COLUP1 := VCS_SECAM_CYAN;\s*COLUPF := VCS_SECAM_MAGENTA;/s
   or die "diagnostic SECAM TIA colors are no longer distinctive\n";
$src =~ /GRP0 := 0xff;.*?GRP1 := 0x81;/s
   or die "diagnostic P0/P1 silhouettes are no longer distinct\n";

my $timing_source=File::Spec->catfile($repo,'test','vcs_frame_timing.cpp');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_diagnostic');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
require_ok('compile diagnostic frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic',
   '-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);

# Build the ordinary input-driven cartridge once.  SWCHB is then changed only
# at synchronized VSYNC boundaries by the timing harness.  These runs lock the
# real SELECT edge/hold behavior rather than the synthetic DIAGNOSTIC_TEST_SWEEP
# path, and they read the final mode directly from F4SC Superchip RAM.
my $input_bin=File::Spec->catfile($tmp,'diagnostic-input.bin');
my $input_map=File::Spec->catfile($tmp,'diagnostic-input.map');
require_ok('build input-driven diagnostic',$driver,'-I',$vcs,'-I',$example,'-T',$generic,
   '-Wa,--illegals','-DDIAGNOSTIC_TEST_TV=0','-Map',$input_map,$source,$boot,'-o',$input_bin);
my $input_map_text=read_file($input_map);
$input_map_text =~ /^\s+ZERO BSS\.cartram\.__vcsc_object\$diagnostic_boot_7800\s+read=\$F080 write=\$F000 size=\$0001 split=yes$/m
   or die "diagnostic_boot_7800 is not the first Superchip byte expected by diagnostic_boot.s26\n";
my $controller_mode=map_symbol_addr($input_map_text,'diagnostic_controller_mode');
my $tv_mode=map_symbol_addr($input_map_text,'diagnostic_tv_mode');
my $frame_tv_mode=map_symbol_addr($input_map_text,'diagnostic_frame_tv_mode');

my $controller_hold=switch_sequence(72,0xfd,6);
require_ok('held SELECT advances one controller only',$timing,$input_bin,'55','--no-audio',
   '--raw-lines','264','--released-inputs','--frame-sequence','0x282',$controller_hold,
   '--expect-memory',sprintf('0x%04x',$controller_mode),'1',
   '--expect-memory',sprintf('0x%04x',$tv_mode),'0');

my $controller_cycle=switch_sequence(120,0xfd,6,24,42,60);
require_ok('SELECT cycles all controller modes',$timing,$input_bin,'90','--no-audio',
   '--raw-lines','264','--released-inputs','--frame-sequence','0x282',$controller_cycle,
   '--expect-memory',sprintf('0x%04x',$controller_mode),'0',
   '--expect-memory',sprintf('0x%04x',$tv_mode),'0');

my $tv_hold=switch_sequence(80,0xfc,6);
require_ok('held RESET+SELECT advances one TV mode only',$timing,$input_bin,'60','--no-audio',
   '--released-inputs','--frame-sequence','0x282',$tv_hold,
   '--raw-lines-by-memory',sprintf('0x%04x',$frame_tv_mode),'0:264,1:314,2:314',
   '--expect-memory',sprintf('0x%04x',$tv_mode),'1',
   '--expect-memory',sprintf('0x%04x',$controller_mode),'0');

my $tv_cycle=switch_sequence(120,0xfc,6,24,42);
require_ok('RESET+SELECT cycles NTSC PAL SECAM',$timing,$input_bin,'90','--no-audio',
   '--released-inputs','--frame-sequence','0x282',$tv_cycle,
   '--raw-lines-by-memory',sprintf('0x%04x',$frame_tv_mode),'0:264,1:314,2:314',
   '--expect-memory',sprintf('0x%04x',$tv_mode),'0',
   '--expect-memory',sprintf('0x%04x',$controller_mode),'0');

# Each frame consumes one SWCHA read per controller. Repeat the same Gray
# phase for the left/right pair, then advance through the real clockwise
# sequence 3 -> 1 -> 0 -> 2 -> 3 on successive frames. This reproduces the
# moving-wheel decoder paths that made the old multi-sample diagnostic unstable.
for my $spec (['NTSC',0,264],['PAL',1,314],['SECAM',2,314]) {
   my($name,$tv,$raw)=@$spec;
   my $tag=lc($name);
   my $bin=File::Spec->catfile($tmp,"diagnostic-$tag-sweep.bin");
   my $map=File::Spec->catfile($tmp,"diagnostic-$tag-sweep.map");
   require_ok("build $name diagnostic sweep",$driver,'-I',$vcs,'-I',$example,'-T',$generic,
      '-Wa,--illegals','-DDIAGNOSTIC_TEST_SWEEP=1',"-DDIAGNOSTIC_TEST_TV=$tv",'-Map',$map,$source,$boot,'-o',$bin);
   -s $bin==32768 or die "diagnostic is not a 32K F4SC image\n";
   my($out,$err)=require_ok("$name moving driving timing",$timing,$bin,'130','--no-audio',
      '--raw-lines',"$raw",'--released-inputs','--read-sequence','0x280',
      '0x33,0x33,0x11,0x11,0x00,0x00,0x22,0x22');
   $out =~ /^vcs_frame_timing ok:/
      or die "unexpected $name moving-driving timing result:\n$out";
   $err eq '' or die "$name moving-driving timing wrote stderr:\n$err";
}

# Prove the reset shim sees the 7800 signature before it clears RIOT RAM.
# reset-on-pc preserves RAM, so the first pass plants a candidate signature;
# the second reset must capture it, clear it, and publish the result in F4SC RAM.
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $f4sc_cfg=File::Spec->catfile($vcs,'vcs_32k_f4sc.cfg');
for my $probe ([ea=>0xea,1],[not_ea=>0x00,0]) {
   my($tag,$tail,$want)=@$probe;
   my $probe_src=File::Spec->catfile($tmp,"diagnostic-boot-$tag.c26");
   my $probe_bin=File::Spec->catfile($tmp,"diagnostic-boot-$tag.bin");
   my $probe_map=File::Spec->catfile($tmp,"diagnostic-boot-$tag.map");
   open(my $pf,'>',$probe_src) or die "write $probe_src: $!\n";
   print {$pf} qq{include "vcs_32k_f4sc.c26"\ncartram uint8_t diagnostic_boot_7800;\ncartram uint8_t boot_probe_result;\nvoid boot_probe_stop(void) { while (1) { } }\nvoid main(void) {\n   if (diagnostic_boot_7800) { boot_probe_result := 0xaa; asm jmp boot_probe_stop; }\n   boot_probe_result := 0x11;\n   asm lda #\$6c; asm sta \$e0;\n   asm lda #\$fc; asm sta \$e1;\n   asm lda #\$ff; asm sta \$e2;\n   asm lda #\$@{[sprintf('%02x',$tail)]}; asm sta \$e3;\n   asm jmp boot_probe_stop;\n}\n};
   close($pf);
   require_ok("build 7800 boot $tag probe",$driver,'-I',$vcs,'-I',$example,'-T',$generic,
      '-Map',$probe_map,$probe_src,$boot,'-o',$probe_bin);
   my $probe_map_text=read_file($probe_map);
   my $done=map_symbol_addr($probe_map_text,'boot_probe_stop');
   my $result=map_symbol_addr($probe_map_text,'boot_probe_result');
   my($dump,$simerr)=require_ok("simulate 7800 boot $tag probe",$sim,'-T',$f4sc_cfg,
      sprintf('--reset-on-pc=0x%04x',$done),sprintf('--stop-pc=0x%04x',$done),'--dump-on-stop',$probe_bin);
   $simerr eq '' or die "7800 boot $tag simulator wrote stderr:\n$simerr";
   my $mem=parse_dump($dump);
   my $expected=$want ? 0xaa : 0x11;
   $mem->[$result]==$expected
      or die sprintf("7800 boot %s result=%02x expected=%02x\n",$tag,$mem->[$result],$expected);
   if ($want) {
      for my $addr (0xe0..0xe3) {
         $mem->[$addr]==0 or die sprintf("7800 boot shim did not clear RIOT byte %04x\n",$addr);
      }
   }
}

print "diagnostic cartridge passed\n";
