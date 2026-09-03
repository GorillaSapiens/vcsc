#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 3F max diagnostic passed: 512K, 65025 lower-pair calls, 65535 total calls, 262-line display
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
sub parse_hex_dump {
   my($text)=@_; my @mem=(0)x65536;
   for my $line (split /\n/,$text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($n,$a,$data)=(hex($1),hex($2),$3);
      length($data)==$n*2 or die "bad HEX dump record\n";
      for my $i (0..$n-1) { $mem[$a+$i]=hex(substr($data,$i*2,2)); }
   }
   return \@mem;
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $dir=File::Spec->catdir($repo,qw(examples 09_bankswitching 18_3f_max));
my $source=File::Spec->catfile($dir,'3f_max_diagnostic.c26');
my $status_font=File::Spec->catfile($dir,'status_font.c26');
my $wait_font=File::Spec->catfile($dir,'wait_font.c26');
my $cart_font=File::Spec->catfile($dir,'cart_type_font.c26');
my $generator=File::Spec->catfile($dir,'make_torture.pl');
my $makefile=File::Spec->catfile($dir,'Makefile');
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
for ($source,$status_font,$wait_font,$cart_font,$generator,$makefile,$driver,$sim) { -e $_ or die "missing 3F max support file $_\n"; }

my $src=read_file($source);
$src =~ /VCS_3F_BANKS\s*:=\s*256/ or die "3F max source lost 256-bank profile\n";
$src =~ /\/\/\s*"3F max"/ or die "3F max source lost exact second-line label\n";
$src =~ /bank253\s+extern\s+void\s+load_wait\(void\)/ &&
$src =~ /bank254\s+extern\s+void\s+load_pass\(void\)/ &&
$src =~ /bank254\s+extern\s+void\s+load_fail\(void\)/
   or die "3F max source lost banked WAIT/PASS/FAIL pointer loaders\n";
$src =~ /instantiate\s+"six_glyph_big_wide_component\.c26"\s+as\s+status_result\s*\(external_pointers\s*:=\s*1\)/
   or die "3F max status display no longer uses the standard big-wide external-pointer renderer\n";
$src =~ /COLUBK\s*:=\s*0x84/
   or die "3F max wait display lost blank-screen blue background\n";
$src =~ /spinner_frame\+\+.*?spinner_frame\s*==\s*15.*?spinner_index\+\+/s
   or die "3F max spinner no longer advances every 15 NTSC frames\n";
$src =~ /torture_batch\s*:=\s*10;.*?step_3f_max_torture\(\).*?torture_batch\s*:=\s*8;.*?step_3f_max_torture\(\)/s
   or die "3F max torture no longer uses bounded VBLANK/overscan batches\n";
$src =~ /vcs_ntsc_wait_component_scanlines\(81\).*?status_result_draw\(\).*?cart_type_draw\(\).*?vcs_ntsc_wait_visible_tail_scanlines\(81\)/s
   or die "3F max PASS/FAIL display no longer uses standard bankswitching spacing\n";
read_file($cart_font) =~ /Characters:\s*"3F max"/ or die "3F max font no longer encodes exact second line\n";
my $status_text=read_file($status_font);
$status_text =~ /Characters:\s*" pasFAIL"/ or die "3F max status font lost pass\/FAIL glyph set\n";
$status_text =~ /Source font:\s*big_ascii\.c26/ or die "3F max PASS/FAIL display no longer uses the standard big font\n";
my $wait_text=read_file($wait_font);
$wait_text =~ /Characters:\s*" wait\/-\\\\\|"/ or die "3F max WAIT font lost wait + spinner glyph set\n";
$wait_text =~ /Source font:\s*big_ascii\.c26/ or die "3F max WAIT display no longer uses the standard big font\n";
my $generator_text=read_file($generator);
$generator_text =~ /segmentalign.*CODE\.bank%d.*2048/ &&
$generator_text =~ /wait_glyphs/ && $generator_text =~ /status_glyphs/
   or die "3F max generator lost fixed lower-bank layout or embedded status fonts\n";
read_file($makefile) =~ /^BIG_FONT\s*:=.*\/big_ascii\.c26\s*$/m
   or die "3F max font regeneration no longer selects big_ascii.c26\n";

my @torture=sort glob(File::Spec->catfile($dir,'3f_max_torture_*.s26'));
@torture==9 or die "expected eight lower-bank torture objects plus fixed scheduler\n";
for my $i (0..7) {
   $torture[$i] =~ /_\Q@{[sprintf('%02d',$i)]}\E\.s26\z/ or die "missing generated torture chunk $i\n";
}
$torture[-1] =~ /_fixed\.s26\z/ or die "missing generated fixed torture scheduler\n";

my $bin=File::Spec->catfile($tmp,'3f_max.bin');
my $map_path=File::Spec->catfile($tmp,'3f_max.map');
my($build_out,$build_err)=require_ok('build 3F max diagnostic',$driver,'-I',$vcs,'-I',$dir,'-Map',$map_path,$source,@torture,'-o',$bin);
$build_err eq '' or die "3F max build wrote stderr:\n$build_err";
-s $bin==524288 or die "3F max output is not exactly 512K\n";
my $rom=read_file($bin);
substr($rom,-8,4) eq "3F\0\0" or die "3F max signature missing from fixed final bank\n";

my $map=read_file($map_path);
my %file_index;
while ($map =~ /^\s+bank(\d+)\s+file-index=(\d+)\b/mg) { $file_index{$1}=0+$2; }
keys(%file_index)==256 or die "3F max map does not contain 256 physical banks\n";
for my $bank (0..255) {
   exists($file_index{$bank}) && $file_index{$bank}==$bank
      or die "3F max map lost physical bank $bank/file-index identity\n";
}
for my $bank (0..254) {
   $build_out =~ /^\s+bank\Q$bank\E\s+used=([1-9][0-9]*) bytes/m
      or die "3F max lower physical bank $bank contains no torture payload\n";
}
$map =~ /^\s+bank255\s+file-index=255\b.*cpu=\$1800.*startup=yes/m
   or die "3F max fixed/startup bank is not physical bank 255\n";

my $sim_bin=File::Spec->catfile($tmp,'3f_max_sim.bin');
my $sim_map_path=File::Spec->catfile($tmp,'3f_max_sim.map');
my($sim_build_out,$sim_build_err)=require_ok('build 3F max simulator diagnostic',$driver,'-I',$vcs,'-I',$dir,
   '-DSIMULATOR_TEST','-Map',$sim_map_path,$source,@torture,'-o',$sim_bin);
$sim_build_err eq '' or die "3F max simulator build wrote stderr:\n$sim_build_err";
my $sim_map=read_file($sim_map_path);
my %sym=map { $_=>map_symbol($sim_map,$_) } qw(simulator_done failure torture_count);
my($sim_out,$sim_err)=require_ok('simulate complete 3F max torture',$sim,'--map',$sim_map_path,
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$sim_bin);
$sim_err eq '' or die "3F max simulator wrote stderr:\n$sim_err";
my $mem=parse_hex_dump($sim_out);
$mem->[$sym{failure}]==0 or die sprintf("3F max self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
my $count=$mem->[$sym{torture_count}] | ($mem->[$sym{torture_count}+1] << 8);
$count==0xffff or die sprintf("3F max executed %u target calls instead of 65535\n",$count);

my $timing_source=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $mos_dir=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_3f_max');
require_ok('compile 3F max frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic',
   '-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);
my($timing_out,$timing_err)=require_ok('time 3F max wait/result frames',$timing,$bin,'3800','--no-audio','--raw-lines','264');
$timing_out eq "vcs_frame_timing ok: 3797 frames at 262 lines, 0 AUDV0 writes\n"
   or die "3F max WAIT/result frame timing was not exactly 262 scanlines:\n$timing_out";
$timing_err eq '' or die "3F max frame timing wrote stderr:\n$timing_err";

print "3F max diagnostic passed: 512K, 65025 lower-pair calls, 65535 total calls, 262-line display\n";
