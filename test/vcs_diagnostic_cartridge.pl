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
sub parse_u8_array {
   my($text,$name,$count)=@_;
   $text =~ /\bconst uint8_t \Q$name\E\[$count\]\s*:=\s*\{(.*?)\};/s
      or die "missing ${name}[$count]\n";
   my @v=map { /^0x/i ? hex($_) : 0+$_ } ($1 =~ /\b(?:0x[0-9A-Fa-f]+|\d+)\b/g);
   @v==$count or die "$name has ".scalar(@v)." entries; expected $count\n";
   return \@v;
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
my $support=File::Spec->catfile($example,'diagnostic_support.c26');
my $collision_helper=File::Spec->catfile($example,'make_collision_font.pl');
my $collision_font=File::Spec->catfile($example,'diagnostic_collision_font.c26');
my $half_font=File::Spec->catfile($vcs,qw(fonts half_ascii.c26));
my $big_font=File::Spec->catfile($vcs,qw(fonts big_ascii.c26));
my $logo_font=File::Spec->catfile($vcs,qw(fonts logo_font.c26));
my $fingerprint_font=File::Spec->catfile($example,'diagnostic_fingerprint_font.c26');
my $subset_helper=File::Spec->catfile($vcs,qw(fonts make_font_subset.pl));
my $pair_helper=File::Spec->catfile($vcs,qw(fonts make_pair_font.pl));
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $examples_ignore=File::Spec->catfile($repo,'examples','.gitignore');

my $ignore_text=read_file($examples_ignore);
$ignore_text =~ /^!19_diagnostic\/01_diagnostic\/diagnostic_boot\.s26$/m
   or die "examples/.gitignore would omit maintained diagnostic_boot.s26 from handoff tarballs\n";

my $src=read_file($source);
my $idx=read_file($indices);
my $collision_font_text=read_file($collision_font);
my $fingerprint_font_text=read_file($fingerprint_font);
my $logo_font_text=read_file($logo_font);
my $msg=read_file($pairs);
my $pair_text=read_file($pair_font);
my $support_text=read_file($support);
my $half_text=read_file($half_font);

# The diagnostic pair table is checked in because rendering must be cheap on
# the 2600, but it is generated from Half.  Compare the actual row bytes with
# a fresh make_pair_font.pl --five run so Half readability fixes cannot leave
# stale pre-cooked diagnostic glyphs behind.
$pair_text =~ /^\/\/ Message: "([^"]*)"$/m
   or die "diagnostic pair font lost its source message\n";
my $pair_message=$1;
my($pair_rc,$pair_sig,$pair_out,$pair_err)=run_capture($pair_helper,'--five','--wide-bracket-hash',$half_font,$pair_message);
$pair_rc==0 && !$pair_sig or die "regenerate diagnostic pair font failed\n$pair_out$pair_err";
$pair_err eq '' or die "regenerate diagnostic pair font wrote stderr:\n$pair_err";
my @checked_rows=$pair_text =~ /0b([.X]{8})/g;
my @generated_rows=$pair_out =~ /0b([.X]{8})/g;
@checked_rows==635 && @generated_rows==635
   or die "diagnostic five-row pair font row count changed\n";
join('',@checked_rows) eq join('',@generated_rows)
   or die "diagnostic_pairs.c26 is stale relative to half_ascii.c26\n";
$pair_text =~ m{// 70: "\[#".*?VCS_FONT_GLYPH\(\n\s*0b\.XX\.X\.X\.,\n\s*0b\.X\.XXXXX,\n\s*0b\.X\.\.X\.X\.,\n\s*0b\.X\.XXXXX,\n\s*0b\.XX\.X\.X\.\n\s*\)}s
   or die "diagnostic keypad # lost its five-column bracketed composition\n";
$pair_text =~ /score_font\[637\]/ && $pair_out =~ /message_font\[637\]/
   or die "diagnostic five-row pair font lost page-safe 637-byte storage\n";
my @checked_pads=$pair_text =~ /page-boundary padding before glyph (\d+)/g;
my @generated_pads=$pair_out =~ /page-boundary padding before glyph (\d+)/g;
join(',',@checked_pads) eq '51,102' && join(',',@generated_pads) eq '51,102'
   or die "diagnostic five-row pair font page padding changed\n";

# The runtime address tables must point at the page-safe packed starts.  A
# five-row glyph beginning above offset 250 would make (pointer),Y acquire a
# data-dependent page-cross cycle in the beam renderer.
$support_text =~ /diagnostic_pair_low\[127\]\s*:=\s*\{(.*?)\};/s
   or die "diagnostic support lost low-byte pair table\n";
my @pair_low=$1 =~ /\b(\d+)\b/g;
$support_text =~ /diagnostic_pair_page\[127\]\s*:=\s*\{(.*?)\};/s
   or die "diagnostic support lost page pair table\n";
my @pair_page=$1 =~ /\b(\d+)\b/g;
@pair_low==127 && @pair_page==127 or die "diagnostic pair address table count changed\n";
for my $i (0..126) {
   my $offset=$i*5 + int($i/51);
   my $want_low=$offset & 255;
   my $want_page=$offset >> 8;
   $pair_low[$i]==$want_low && $pair_page[$i]==$want_page
      or die "diagnostic pair address mismatch at glyph $i\n";
   $pair_low[$i] <= 250
      or die "diagnostic pair glyph $i crosses a 256-byte page\n";
}
$src =~ /diagnostic_fixed_header\[6\]\s*:=\s*\{\s*DIAG_PAIR_SPACE_D,\s*DIAG_PAIR_IA,\s*DIAG_PAIR_GN,\s*DIAG_PAIR_OS,\s*DIAG_PAIR_TI,\s*DIAG_PAIR_C_SPACE\s*\}/s
   or die "diagnostic title is no longer centered as ' DIAGNOSTIC '\n";
$src =~ /glyph_rows:=5/ &&
$src =~ /include "diagnostic_fingerprint_font\.c26"/ &&
$src =~ /include "fonts\/logo_font\.c26"/ &&
$src =~ /DIAGNOSTIC_ROW_TITLE\s*:=\s*6.*?DIAGNOSTIC_ROW_TV\s*:=\s*18/s &&
$src =~ /bank3 void diagnostic_prepare_logo\(void\).*?logo_font\+40/s &&
$src =~ /bank3 void diagnostic_draw_logo\(void\).*\@diagnostic_logo_draw_loop/s &&
$src =~ /bank3 void diagnostic_prepare_fingerprint\(void\).*?diagnostic_fingerprint_font/s &&
$src =~ /bank3 void diagnostic_draw_fingerprint\(void\).*?lda #15;.*\@diagnostic_fingerprint_draw_loop/s &&
$src =~ /diagnostic_bank3_task\(3\);\s*diagnostic_prepare_row\(DIAGNOSTIC_ROW_TITLE\); diagnostic_draw_text_row\(\);\s*diagnostic_bank3_task\(4\);\s*diagnostic_prepare_row\(DIAGNOSTIC_ROW_TV\);/s &&
$src =~ /DIAG_PAIR_NUM_26.*?DIAG_PAIR_NUM_78/s
   or die "diagnostic lost canonical logo, Big-font fingerprint, title, or combined host/TV row\n";

# The fingerprint is a checked-in generated 0-9A-F subset of the canonical Big
# ASCII font.  Regenerate it independently so a font edit cannot leave the
# diagnostic's more-readable six-digit display stale.
my $regen_fingerprint=File::Spec->catfile($tmp,'diagnostic_fingerprint_font.c26');
my($fp_rc,$fp_sig,$fp_out,$fp_err)=run_capture($subset_helper,'--bank','bank3','--license','examples/LICENSE.txt',
   $big_font,$regen_fingerprint,'diagnostic_fingerprint_font','0123456789ABCDEF');
$fp_rc==0 && !$fp_sig or die "regenerate diagnostic fingerprint font failed\n$fp_out$fp_err";
$fp_err eq '' or die "regenerate diagnostic fingerprint font wrote stderr:\n$fp_err";
read_file($regen_fingerprint) eq $fingerprint_font_text
   or die "diagnostic_fingerprint_font.c26 is stale relative to big_ascii.c26\n";
$logo_font_text =~ /page const uint8_t logo_font\[48\]/ &&
$src =~ /asm lda #<logo_font;.*?asm lda #<\{logo_font\+40\}/s
   or die "diagnostic does not draw the canonical six-slice VCSC logo\n";
$src =~ /DIAG_PAIR_CO.*DIAG_PAIR_LR/s &&
$src =~ /DIAG_PAIR_BAMP.*DIAG_PAIR_W_SPACE/s &&
$idx =~ /DIAG_PAIR_LR\s*:=\s*36,\s*\/\/ 'LR'/ &&
$idx =~ /DIAG_PAIR_BAMP\s*:=\s*37,\s*\/\/ 'B&'/ &&
$idx =~ /DIAG_PAIR_W_SPACE\s*:=\s*105,\s*\/\/ 'W '/ &&
$msg =~ /COLRB&/ && $msg =~ /W A SSFAIL/
   or die "diagnostic COLOR/B&W labels are not pre-cooked as COLR and B&W\n";

# The collision panel uses canonical Half-font letters A..O, packed into the
# two six-glyph rows with a six-pixel underline added only for active latches.
# Regenerate and compare the whole file so a Half-font edit cannot leave stale
# beam-time tables behind.
my($collision_rc,$collision_sig,$collision_out,$collision_err)=run_capture($collision_helper,$half_font);
$collision_rc==0 && !$collision_sig or die "regenerate diagnostic collision font failed\n$collision_out$collision_err";
$collision_err eq '' or die "regenerate diagnostic collision font wrote stderr:\n$collision_err";
$collision_out eq $collision_font_text
   or die "diagnostic_collision_font.c26 is stale relative to half_ascii.c26\n";
$collision_font_text =~ /top:\s+A=M0-P1 B=M0-P0 C=M1-P0 D=M1-P1 E=P0-PF F=P0-BL G=P1-PF H=P1-BL/ &&
$collision_font_text =~ /bottom:\s+I=M0-PF J=M0-BL K=M1-PF L=M1-BL M=BL-PF N=P0-P1 O=M0-M1 CHECK/ &&
$collision_font_text =~ /six-pixel underline/ &&
$collision_font_text =~ /diagnostic_collision_top_font\[144\]/ &&
$collision_font_text =~ /diagnostic_collision_bottom_font\[144\]/
   or die "diagnostic collision font lost its A-through-O 15-latch layout\n";

$src =~ /bank4 void diagnostic_driving_vblank\(void\).*?diagnostic_left_drive_begin_frame\(\);.*?diagnostic_right_drive_begin_frame\(\);.*?diagnostic_left_drive_sample\(\);.*?diagnostic_right_drive_sample\(\);.*?diagnostic_drive_position0.*?diagnostic_drive_position1/s
   or die "diagnostic driving mode lost its once-per-frame VBLANK sample\n";
$src !~ /diagnostic_driving_overscan/
   or die "diagnostic driving mode must not sample again in overscan\n";
$src =~ /instantiate "four_paddles\.c26" as diagnostic_paddles.*?diagnostic_text_paddle_sample0.*?diagnostic_paddles_score_commit_latched0\(\).*?diagnostic_text_paddle_sample1.*?diagnostic_paddles_score_commit_latched1\(\).*?instantiate "six_glyph_component\.c26" as diagnostic_text .*?paddle_samples:=2/s &&
$src =~ /asm lda #6;\s*diagnostic_paddles_score_account_a\(\);/s &&
$src =~ /bank1 void diagnostic_draw_text_row\(void\).*?diagnostic_paddles_score_latch0123_fixed\(\);\s*WSYNC := _;.*?diagnostic_text_draw\(\);/s &&
$src =~ /diagnostic_paddles_score_commit_latched2\(\);.*?diagnostic_paddles_score_commit_latched3\(\);/s &&
$src =~ /diagnostic_paddles_score_commit_latched2\(\); WSYNC := _;\s*diagnostic_paddles_score_commit_latched3\(\); WSYNC := _;\s*diagnostic_paddles_advance_pair\(\);/s &&
$src !~ /diagnostic_paddles_sample[0-3]\(\); WSYNC := _;/
   or die "diagnostic lost simultaneous score-integrated paddle sampling\n";

my %collision_expected=(
   diagnostic_collision_expected_top   => [0x80,0x40,0x20,0x10,0x08,0x04,0x02,0x01, 0,0,0,0,0,0,0,0],
   diagnostic_collision_expected_bottom=> [0,0,0,0,0,0,0,0, 0x80,0x40,0x20,0x10,0x08,0x04,0x02,0],
   diagnostic_collision_grp0           => [0,0xff,0xff,0,0xff,0xff,0,0, 0,0,0,0,0,0xff,0,0],
   diagnostic_collision_grp1           => [0xff,0,0,0xff,0,0,0xff,0xff, 0,0,0,0,0,0xff,0,0],
   diagnostic_collision_enam0          => [2,2,0,0,0,0,0,0, 2,2,0,0,0,0,2,0],
   diagnostic_collision_enam1          => [0,0,2,2,0,0,0,0, 0,0,2,2,0,0,2,0],
   diagnostic_collision_enabl          => [0,0,0,0,0,2,0,2, 0,2,0,2,2,0,0,0],
   diagnostic_collision_pf             => [0,0,0,0,0xff,0,0xff,0, 0xff,0,0xff,0,0xff,0,0,0],
);
for my $name (sort keys %collision_expected) {
   my $got=parse_u8_array($src,$name,16);
   join(',',@$got) eq join(',',@{$collision_expected{$name}})
      or die "$name no longer isolates the A-through-O collision sequence\n";
}

$src =~ /bank0 const uint8_t diagnostic_collision_expected_top\[16\].*?0x80,0x40,0x20,0x10,0x08,0x04,0x02,0x01/s &&
$src =~ /bank0 const uint8_t diagnostic_collision_expected_bottom\[16\].*?0x80,0x40,0x20,0x10,0x08,0x04,0x02/s &&
$src =~ /diagnostic_collision_grp0\[16\]/ &&
$src =~ /diagnostic_collision_grp1\[16\]/ &&
$src =~ /diagnostic_collision_enam0\[16\]/ &&
$src =~ /diagnostic_collision_enam1\[16\]/ &&
$src =~ /diagnostic_collision_enabl\[16\]/ &&
$src =~ /diagnostic_collision_pf\[16\]/ &&
$src =~ /bank0 void diagnostic_draw_tia_panel\(void\).*?CXCLR := _;.*\@diagnostic_collision_position_loop.*?diagnostic_collision_grp0,x.*?diagnostic_collision_grp1,x.*?diagnostic_collision_enam0,x.*?diagnostic_collision_enam1,x.*?diagnostic_collision_enabl,x.*?diagnostic_collision_pf,x.*?asm lda CXM0P;.*?asm lda CXM1P;.*?asm lda CXP0FB;.*?asm lda CXP1FB;.*?asm lda CXM0FB;.*?asm lda CXM1FB;.*?asm lda CXBLPF;.*?asm lda CXPPMM;.*?cmp diagnostic_collision_expected_top,x.*?cmp diagnostic_collision_expected_bottom,x.*?cmp #\$ff;.*?cmp #\$fe;.*?DIAGNOSTIC_TEST_TIA_FREEZE.*?cmp #\$f0;.*?beq\.flex \@diagnostic_collision_phase_done;.*?adc #16.*?\@diagnostic_collision_phase_done/s
   or die "diagnostic lost exhaustive isolated A-through-O collision testing\n";
$src =~ /DIAGNOSTIC_ROW_COUNT\s*:=\s*9/ && $src =~ /cartram uint8_t diagnostic_rows\[48\];\s*cartram uint8_t diagnostic_detail1_row\[6\];/s &&
$src =~ /cartram uint8_t diagnostic_tia_top_mask;\s*cartram uint8_t diagnostic_tia_bottom_mask;\s*cartram uint8_t diagnostic_tia_current_top;\s*cartram uint8_t diagnostic_tia_current_bottom;\s*cartram uint8_t diagnostic_tia_pass;/s &&
$src =~ /bank3 void diagnostic_bank3_task\(uint8_t task\).*?diagnostic_prepare_collision_top\(\);.*?diagnostic_draw_collision_row\(\);.*?diagnostic_prepare_collision_bottom\(\);.*?diagnostic_draw_collision_row\(\);/s &&
$src =~ /bank1 void diagnostic_prepare_detail1_row\(void\).*?diagnostic_detail1_row\+0.*?diagnostic_detail1_row\+5/s &&
$src =~ /diagnostic_prepare_detail1_row\(\); diagnostic_draw_text_row\(\);\s*diagnostic_bank3_task\(0\);/s &&
$src =~ /asm lda #5;\s*asm sta\.a diagnostic_text_row;.*?\@diagnostic_collision_draw_loop/s
   or die "diagnostic 15-bit collision letter display is incomplete\n";
$src =~ /bank0 const uint8_t diagnostic_audio0\[64\].*?6,6,6,6/s &&
$src =~ /bank0 const uint8_t diagnostic_audio1\[64\].*?6,6,6,6/s &&
$src =~ /bank0 void diagnostic_audio_tick\(void\).*?asm ldx diagnostic_audio_phase;.*?asm lda diagnostic_audio0,x;.*?asm sta AUDV0;.*?asm lda diagnostic_audio1,x;.*?asm sta AUDV1;.*?asm sta diagnostic_audio_phase;/s &&
$src =~ /cartram uint8_t diagnostic_tia_top_mask;/ && $src =~ /cartram uint8_t diagnostic_tia_bottom_mask;/ &&
$src =~ /AUDC0 := 4; AUDC1 := 4;.*?AUDF0 := 10; AUDF1 := 4;/s
   or die "diagnostic dual-channel audio cadence or cartridge-RAM TIA state is incomplete\n";
my $boot_text=read_file($boot);
$boot_text =~ /lda \$80,x.*?cmp #\$6c.*?lda \$81,x.*?cmp #\$fc.*?lda \$82,x.*?cmp #\$ff.*?lda \$83,x.*?cmp #\$ea.*?cpx #\$7d/s &&
$boot_text =~ /\@clear_riot:.*?sta \$80,x.*?\@clear_superchip:.*?sta \$f000,x.*?\@clear_tia:.*?sta \$00,x.*?tya.*?sta \$f000/s
   or die "diagnostic boot shim lost pre-clear 7800 signature capture or startup clearing\n";
$src =~ /cartram uint8_t diagnostic_boot_7800;\s*cartram uint24_t diagnostic_cpu_fingerprint;/s &&
$src =~ /ARR #\$b8.*?ARR #\$6b.*?ARR #\$6b.*?ARR #\$6b/s &&
$src =~ /diagnostic_compute_cpu_fingerprint\(\);.*?diagnostic_initialize_rows\(\);/s &&
$src =~ /diagnostic_cpu_fingerprint\+2.*?diagnostic_cpu_fingerprint\+1.*?diagnostic_cpu_fingerprint.*?diagnostic_fingerprint_font/s
   or die "diagnostic CPU fingerprint capture/Big-font display path is incomplete\n";
$idx =~ /DIAG_PAIR_NUM_26\s*:=\s*110/ && $idx =~ /DIAG_PAIR_NUM_78\s*:=\s*111/ &&
$idx =~ /DIAG_PAIR_F_SPACE\s*:=\s*116/ && $idx =~ /DIAG_PAIR_COUNT\s*:=\s*127/
   or die "diagnostic platform/fingerprint pair indices are incomplete\n";
$src =~ /DIAGNOSTIC_TV_SECAM.*?COLUP0 := VCS_SECAM_YELLOW;\s*COLUP1 := VCS_SECAM_CYAN;\s*COLUPF := VCS_SECAM_MAGENTA;/s
   or die "diagnostic SECAM TIA colors are no longer distinctive\n";
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
my $input_list=File::Spec->catfile($tmp,'diagnostic-input.lst');
require_ok('build input-driven diagnostic',$driver,'-I',$vcs,'-I',$example,'-T',$generic,
   '-Wa,--illegals','-DDIAGNOSTIC_TEST_TV=0','-Map',$input_map,'-List='.$input_list,$source,$boot,'-o',$input_bin);
my $input_map_text=read_file($input_map);
my $input_list_text=read_file($input_list);
$input_map_text =~ /^\s+ZERO BSS\.cartram\.__vcsc_object\$diagnostic_boot_7800\s+read=\$F080 write=\$F000 size=\$0001 split=yes$/m
   or die "diagnostic_boot_7800 is not the first Superchip byte expected by diagnostic_boot.s26\n";
my $detail1_addr=map_symbol_addr($input_map_text,'diagnostic_detail1_row');
$detail1_addr==0xF0CA
   or die sprintf("DETAIL1 moved out of expected Superchip read address: %04X\n",$detail1_addr);
$input_map_text =~ /^\s+ZERO BSS\.cartram\.__vcsc_object\$diagnostic_detail1_row\s+read=\$F0CA write=\$F04A size=\$0006 split=yes$/m
   or die "diagnostic DETAIL1 is no longer allocated in Superchip RAM\n";
my $reposition_addr=map_symbol_addr($input_map_text,'diagnostic_reposition_table');
my $wrapped_base=($reposition_addr+16-256)&0xffff;
my @wrapped_operands=$input_list_text =~ /LDA \(\(diagnostic_reposition_table \+ 16\) - 256\),Y\s+=> \$([0-9A-Fa-f]{4})/g;
@wrapped_operands==1 or die "diagnostic lost wrapped reposition lookup used by five-object positioning\n";
for my $encoded (@wrapped_operands) {
   hex($encoded)==$wrapped_base
      or die sprintf("diagnostic wrapped lookup encoded %s, expected %04X\n",$encoded,$wrapped_base);
}
for my $y (0xF0..0xFF) {
   my $final=($wrapped_base+$y)&0xffff;
   next unless (($wrapped_base&0xff)+$y)>0xff;
   my $dummy=($wrapped_base&0xff00)|($final&0xff);
   !($dummy>=0xF000 && $dummy<=0xF07F)
      or die sprintf("diagnostic reposition lookup can ghost-read Superchip write alias %04X at Y=%02X\n",$dummy,$y);
}
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
