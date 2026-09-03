#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 3E max diagnostic passed: 512K ROM, 32K RAM, 65025 lower-pair calls, 65535 total calls, 262-line display
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
}
sub read_file {
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub map_symbol {
   my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map missing $name\n"; return hex($1);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $dir=File::Spec->catdir($repo,qw(examples 09_bankswitching 19_3e_max));
my $source=File::Spec->catfile($dir,'3e_max_diagnostic.c26');
my $status_font=File::Spec->catfile($dir,'status_font.c26');
my $wait_font=File::Spec->catfile($dir,'wait_font.c26');
my $cart_font=File::Spec->catfile($dir,'cart_type_font.c26');
my $generator=File::Spec->catfile($dir,'make_torture.pl');
my $swapram_source=File::Spec->catfile($dir,'3e_max_swapram.c26');
my $swapram_storage=File::Spec->catfile($dir,'3e_max_swapram_storage.s26');
my $makefile=File::Spec->catfile($dir,'Makefile');
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
for ($source,$status_font,$wait_font,$cart_font,$generator,$swapram_source,$swapram_storage,$makefile,$driver) { -e $_ or die "missing 3E max support file $_\n"; }

my $src=read_file($source);
$src =~ /VCS_3E_BANKS\s*:=\s*256/ or die "3E max source lost 256-bank ROM profile\n";
$src =~ /\/\/\s*"3E max"/ or die "3E max source lost exact second-line label\n";
$src =~ /bank251\s+extern\s+void\s+load_mapper_type\(void\)/ &&
$src =~ /bank253\s+extern\s+void\s+load_wait\(void\)/ &&
$src =~ /bank254\s+extern\s+void\s+load_pass\(void\)/ &&
$src =~ /bank254\s+extern\s+void\s+load_fail\(void\)/
   or die "3E max source lost banked label/WAIT/PASS/FAIL pointer loaders\n";
$src =~ /instantiate\s+"six_glyph_big_wide_component\.c26"\s+as\s+status_result\s*\(external_pointers\s*:=\s*1\)/
   or die "3E max status display no longer uses the standard big-wide external-pointer renderer\n";
$src =~ /COLUBK\s*:=\s*0x84/
   or die "3E max wait display lost blank-screen blue background\n";
$src =~ /spinner_frame\+\+.*?spinner_frame\s*==\s*15.*?spinner_index\+\+/s
   or die "3E max spinner no longer advances every 15 NTSC frames\n";
$src =~ /ram_phase\).*?torture_batch\s*:=\s*2.*?torture_batch\s*:=\s*10.*?step_3e_max_torture\(\).*?ram_phase\).*?torture_batch\s*:=\s*2.*?torture_batch\s*:=\s*8.*?step_3e_max_torture\(\)/s
   or die "3E max torture no longer uses bounded compiler-swapram/ROM VBLANK and overscan batches\n";
$src =~ /vcs_ntsc_wait_component_scanlines\(80\).*?status_result_draw\(\).*?lda #\$fb.*?sta \$3f.*?WSYNC\s*:=\s*_.*?vcs_ntsc_component_handoff\(\).*?cart_type_draw\(\).*?vcs_ntsc_wait_visible_tail_scanlines\(81\)/s
   or die "3E max banked-label handoff no longer preserves the 192-line visible frame\n";
read_file($cart_font) =~ /Characters:\s*"3E max"/ or die "3E max font no longer encodes exact second line\n";
my $status_text=read_file($status_font);
$status_text =~ /Characters:\s*" pasFAIL"/ or die "3E max status font lost pass\/FAIL glyph set\n";
$status_text =~ /Source font:\s*big_ascii\.c26/ or die "3E max PASS/FAIL display no longer uses the standard big font\n";
my $wait_text=read_file($wait_font);
$wait_text =~ /Characters:\s*" wait\/-\\\\\|"/ or die "3E max WAIT font lost wait + spinner glyph set\n";
$wait_text =~ /Source font:\s*big_ascii\.c26/ or die "3E max WAIT display no longer uses the standard big font\n";
my $generator_text=read_file($generator);
$generator_text =~ /segmentalign.*CODE\.bank%d.*2048/ &&
$generator_text =~ /wait_glyphs/ && $generator_text =~ /status_glyphs/ &&
$generator_text =~ /cart_type_glyphs/
   or die "3E max generator lost fixed lower-bank layout or embedded display fonts\n";
$generator_text =~ /\$ram_banks\s*=\s*32/ &&
$generator_text =~ /\$lfsr_seed\s*=\s*0xACE1/i &&
$generator_text =~ /\$lfsr_tap_mask\s*=\s*0xB400/i &&
$generator_text =~ /period\s*==\s*65535/
   or die "3E max generator lost maximal 16-bit LFSR contract\n";
my $swapram_text=read_file($swapram_source);
my $storage_text=read_file($swapram_storage);
for my $bank (0..31) {
   my $name=sprintf 'ram_%02d',$bank;
   my $access=sprintf 'ram_access_%02d',$bank;
   $swapram_text =~ /extern\s+swapram\s+uint8_t\s+\Q$name\E\[1024\]/
      or die "3E max compiler source lost 1K swapram object $name\n";
   $swapram_text =~ /bank\Q$bank\E\s+void\s+\Q$access\E\(void\)/
      or die "3E max compiler source lost bank-local accessor $access\n";
   $swapram_text =~ /\Q$name\E\[ram_offset\]\s*:=\s*ram_value/
      or die "3E max $access lost compiler-lowered runtime-offset write\n";
   $swapram_text =~ /ram_value\s*:=\s*\Q$name\E\[ram_offset\]/
      or die "3E max $access lost compiler-lowered runtime-offset read\n";
   my $storage_needle='.segment "BSS.swapram.__vcsc_object$'.$name."\"\n$name:\n    .res 1024";
   index($storage_text,$storage_needle) >= 0
      or die "3E max swapram backing storage lost $name\n";
}
$generator_text =~ /step_3e_max_ram:/ &&
$generator_text =~ /jsr ram_compiler_access/ &&
$generator_text =~ /\.banktarget ram_compiler_access/ &&
$generator_text =~ /whose ordinary swapram lvalue is compiler-lowered through swapram_read1 or.*?swapram_write1/s &&
$generator_text !~ /adc #\$14.*?sta \(_vcsc_ptr0\),y/s &&
$generator_text !~ /adc #\$10.*?lda \(_vcsc_ptr0\),y/s
   or die "3E max RAM torture no longer exclusively exercises compiler-managed swapram lvalues\n";
$generator_text =~ /load_pass:\s*lda #<status_glyphs\s*sta status_result_pointers\+0.*?lda #<\{status_glyphs \+ 16\}\s*sta status_result_pointers\+2.*?lda #<\{status_glyphs \+ 32\}\s*sta status_result_pointers\+4.*?lda #<\{status_glyphs \+ 48\}\s*sta status_result_pointers\+6.*?lda #<\{status_glyphs \+ 48\}\s*sta status_result_pointers\+8.*?lda #<status_glyphs\s*sta status_result_pointers\+10/s
   or die "3E max PASS loader no longer centers pass as blank/p/a/s/s/blank\n";
read_file($makefile) =~ /^BIG_FONT\s*:=.*\/big_ascii\.c26\s*$/m &&
read_file($makefile) =~ /^CART_FONT_FLAGS\s*:=.*--bank bank251\s*$/m
   or die "3E max font regeneration lost big status font or bank251 label placement\n";

# Independently verify the exact Galois recurrence used by the generated runtime.
my $lfsr=0xACE1;
my $period=0;
do {
   $lfsr=(($lfsr >> 1) ^ (($lfsr & 1) ? 0xB400 : 0)) & 0xffff;
   ++$period;
   $period <= 65535 or die "3E max LFSR exceeded maximal 16-bit period\n";
} while ($lfsr != 0xACE1);
$period==65535 or die "3E max LFSR period is $period, expected 65535\n";
my $after_32k=0xACE1;
for (1..32768) {
   $after_32k=(($after_32k >> 1) ^ (($after_32k & 1) ? 0xB400 : 0)) & 0xffff;
}
$after_32k==0x5f32 or die sprintf("3E max 32K LFSR endpoint changed to $%04X\n",$after_32k);

my @torture=sort glob(File::Spec->catfile($dir,'3e_max_torture_*.s26'));
@torture==9 or die "expected eight lower-bank torture objects plus fixed ROM/RAM scheduler\n";
for my $i (0..7) {
   $torture[$i] =~ /_\Q@{[sprintf('%02d',$i)]}\E\.s26\z/ or die "missing generated torture chunk $i\n";
}
$torture[-1] =~ /_fixed\.s26\z/ or die "missing generated fixed torture scheduler\n";

my $bin=File::Spec->catfile($tmp,'3e_max.bin');
my $map_path=File::Spec->catfile($tmp,'3e_max.map');
my($build_out,$build_err)=require_ok('build 3E max diagnostic',$driver,'-I',$vcs,'-I',$dir,'-Map',$map_path,$source,@torture,$swapram_source,$swapram_storage,'-o',$bin);
$build_err eq '' or die "3E max build wrote stderr:\n$build_err";
-s $bin==524288 or die "3E max output is not exactly 512K\n";
my $rom=read_file($bin);
substr($rom,-8,4) eq "3E\0\0" or die "3E max signature missing from fixed final bank\n";

my $map=read_file($map_path);
my %file_index;
while ($map =~ /^\s+bank(\d+)\s+file-index=(\d+)\b/mg) { $file_index{$1}=0+$2; }
keys(%file_index)==256 or die "3E max map does not contain 256 physical banks\n";
for my $bank (0..255) {
   exists($file_index{$bank}) && $file_index{$bank}==$bank
      or die "3E max map lost physical bank $bank/file-index identity\n";
}
for my $bank (0..254) {
   $build_out =~ /^\s+bank\Q$bank\E\s+used=([1-9][0-9]*) bytes/m
      or die "3E max lower physical bank $bank contains no torture payload\n";
}
$map =~ /^\s+bank255\s+file-index=255\b.*cpu=\$1800.*startup=yes/m
   or die "3E max fixed/startup bank is not physical bank 255\n";
for my $bank (0..31) {
   my $name=sprintf 'ram_%02d',$bank;
   $map =~ /^\s+BSS\.swapram\.__vcsc_object\x24\Q$name\E\s+logical=\$[0-9A-Fa-f]+\s+swapram-bank=\Q$bank\E\s+swapram-offset=\$0000\s+size=\$0400\b/m
      or die "3E max map lost compiler-managed 1K swapram allocation $name/bank$bank\n";
}
$map =~ /^\s*\$[0-9A-Fa-f]{4}\s+swapram_read1\b/m &&
$map =~ /^\s*\$[0-9A-Fa-f]{4}\s+swapram_write1\b/m
   or die "3E max link lost compiler-selected swapram read/write helpers\n";

my $timing_source=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $mos_dir=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_3e_max');
require_ok('compile 3E max frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic',
   '-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);
my %sym=map { $_=>map_symbol($map,$_) } qw(failure torture_count ram_phase ram_bank ram_page ram_offset ram_lfsr);
my @memory_oracle=(
   '--expect-memory',sprintf('0x%04X',$sym{failure}),'0',
   '--expect-memory',sprintf('0x%04X',$sym{torture_count}),'0xff',
   '--expect-memory',sprintf('0x%04X',$sym{torture_count}+1),'0xff',
   '--expect-memory',sprintf('0x%04X',$sym{ram_phase}),'3',
   '--expect-memory',sprintf('0x%04X',$sym{ram_bank}),'32',
   '--expect-memory',sprintf('0x%04X',$sym{ram_page}),'0',
   '--expect-memory',sprintf('0x%04X',$sym{ram_offset}),'0',
   '--expect-memory',sprintf('0x%04X',$sym{ram_lfsr}),'0x32',
   '--expect-memory',sprintf('0x%04X',$sym{ram_lfsr}+1),'0x5f',
);
my($timing_out,$timing_err)=require_ok('time and verify complete 3E max run',$timing,$bin,'22000',
   '--no-audio','--raw-lines','264',@memory_oracle);
$timing_out eq "vcs_frame_timing ok: 21997 frames at 262 lines, 0 AUDV0 writes\n"
   or die "3E max complete WAIT/result frame timing was not exactly 262 scanlines:\n$timing_out";
$timing_err eq '' or die "3E max frame timing wrote stderr:\n$timing_err";

print "3E max diagnostic passed: 512K ROM, 32K RAM, 65025 lower-pair calls, 65535 total calls, 262-line display\n";
