#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: E0 diagnostic passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
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
sub find_executable {
   my($name)=@_; return abs_path($name) if $name =~ m{/} && -x $name;
   for my $dir (split(/:/,$ENV{PATH} // '')) {
      my $p=File::Spec->catfile($dir,$name); return abs_path($p) if -x $p;
   }
   return undef;
}
sub terminate_child {
   my($pid)=@_; return if !$pid;
   kill 'TERM',$pid;
   for (1..20) { my $d=waitpid($pid,WNOHANG); return if $d==$pid || $d==-1; select undef,undef,undef,0.05; }
   kill 'KILL',$pid; waitpid($pid,0);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP [--stella]\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP [--stella]\n";
my $stella_mode=@ARGV && $ARGV[0] eq '--stella' ? shift(@ARGV) : '';
@ARGV and die "usage: $0 REPO TMP [--stella]\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $disas=File::Spec->catfile($repo,'disassembler','vcsc-disas');
my $roundtrip=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $cfg=File::Spec->catfile($vcs,'vcs_8k_e0.cfg');
my $profile=File::Spec->catfile($vcs,'vcs_8k_e0.c26');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','11_e0');
my $source=File::Spec->catfile($example_dir,'e0_diagnostic.c26');
my $example_make=File::Spec->catfile($example_dir,'Makefile');

my $src=read_file($source);
$src =~ /instantiate "six_glyph_big_wide_component\.c26" as status_result/ &&
$src =~ /instantiate "six_glyph_component\.c26" as cart_type \(compact_font:=0\)/ &&
$src =~ /bank0 void draw_result\(void\)/ &&
$src =~ /bank1 const uint8_t status_glyphs\[128\]/ &&
$src =~ /bank1 const uint8_t cart_type_glyphs\[24\]/ &&
$src =~ /bank2 void component_init\(void\)/ &&
$src =~ /bank2 void component_vblank\(void\)/ &&
$src =~ /asm lda \$1fe0;\s*asm lda \$1fe9;\s*asm lda \$1ff2;\s*draw_result\(\);/s
   or die "E0 visible diagnostic lost its banked PASS/FAIL + E0 presentation\n";

my $mk=read_file($example_make);
$mk =~ /^play:\s*\$\(TARGET\)\s*$/m && $mk =~ /^\s*stella\s+-bs\s+E0\s+\$\(TARGET\)\s*$/m
   or die "E0 play target must force Stella -bs E0\n";
my $pt=read_file($profile);
(()=$pt =~ /\bbank\s+bank\d+\s*\{/g)==8 &&
$pt =~ /\$signature:E0\b/ && $pt !~ /\$select_access:/ &&
$pt =~ /bank\s+bank7\s*\{.*?\$file_index:7.*?\$link_start:0xfc00.*?\$cpu_start:0x1c00.*?\$startup/s &&
$pt =~ /bank\s+bank0\s*\{.*?\$cpu_start:0x1000/s &&
$pt =~ /bank\s+bank1\s*\{.*?\$cpu_start:0x1400/s &&
$pt =~ /bank\s+bank2\s*\{.*?\$cpu_start:0x1800/s
   or die "E0 C26 profile does not describe the segmented 8x1K topology\n";
my $ct=read_file($cfg);
$ct =~ /mapper\s*=\s*E0/ && (()=$ct =~ /size\s*=\s*\$0400/g)==8 &&
$ct =~ /BANK7:.*fileindex\s*=\s*7.*startup\s*=\s*yes/is
   or die "E0 simulator cfg does not describe eight 1K banks/fixed bank 7\n";

my $bin=File::Spec->catfile($tmp,'e0.bin');
my $map_path=File::Spec->catfile($tmp,'e0.map');
require_ok('build E0 simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST',
   '-T',$generic,'-Map',$map_path,$source,'-o',$bin);
-s $bin==8192 or die "E0 output size is not 8K\n";
my $rom=read_file($bin);
substr($rom,8192-8,4) eq "E0\0\0" or die "E0 signature is missing from physical bank 7\n";
for my $fb (0..6) {
   substr($rom,$fb*1024+1016,4) ne "E0\0\0" or die "E0 signature duplicated into physical bank $fb\n";
}
my $map=read_file($map_path);
$map =~ /^\s+bank7\s+file-index=7\b.*cpu=\$1C00.*startup=yes/m && $map !~ /^TRAMPOLINES$/m
   or die "E0 map lost fixed-bank/direct segmented topology\n";
for my $i (0..7) { map_symbol($map,"bank${i}_probe"); }
my %sym=map { $_=>map_symbol($map,$_) } qw(simulator_done failure call_count);
my($out,$err)=require_ok('simulate E0 power-on/selectors',$sim,'-T',$cfg,
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$err eq '' or die "E0 simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($out);
$mem->[$sym{failure}]==0 or die sprintf("E0 self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{call_count}]==12 or die "E0 did not execute all expected physical-bank probes\n";

my $visible=File::Spec->catfile($tmp,'e0-visible.bin');
my $visible_map=File::Spec->catfile($tmp,'e0-visible.map');
require_ok('build visible E0 PASS/FAIL cartridge',$driver,'-I',$vcs,'-T',$generic,'-Map',$visible_map,$source,'-o',$visible);
my $vmap=read_file($visible_map);
$vmap =~ /CODE\.bank0\.__vcsc_function\$draw_result.*bank=bank0/s &&
$vmap =~ /RODATA\.bank1\.__vcsc_object\$status_glyphs.*bank=bank1/s &&
$vmap =~ /RODATA\.bank1\.__vcsc_object\$cart_type_glyphs.*bank=bank1/s &&
$vmap =~ /CODE\.bank2\.__vcsc_function\$component_init.*bank=bank2/s &&
$vmap =~ /CODE\.bank2\.__vcsc_function\$component_vblank.*bank=bank2/s
   or die "visible E0 diagnostic display is not split across windows 0/1/2 as intended\n";
my $vrom=read_file($visible);
length($vrom)==8192 && substr($vrom,-8,4) eq "E0\0\0"
   or die "visible E0 diagnostic lost its 8K/signature layout\n";
my $s26=File::Spec->catfile($tmp,'e0-visible.s26');
require_ok('disassemble E0 cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: E0 \(high confidence;/m &&
$dis =~ /^; reset\/power-on bank: 7 \(E0 fixed vector bank\)$/m &&
$dis =~ /^; E0 segments: \$1000-\$13FF, \$1400-\$17FF, \$1800-\$1BFF are independently banked 1K windows; \$1C00-\$1FFF is fixed physical bank 7$/m
   or die "vcsc-disas did not recognize E0 semantics\n$dis";
my $rt_in=File::Spec->catdir($tmp,'roundtrip-in');
my $rt_out=File::Spec->catdir($tmp,'roundtrip-out');
make_path($rt_in,$rt_out);
copy($visible,File::Spec->catfile($rt_in,'e0-visible.bin')) or die "copy E0 roundtrip input: $!\n";
require_ok('round-trip E0 cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'e0-visible.bin')) eq $vrom
   or die "E0 disassembler round trip is not byte-exact\n";

if ($stella_mode) {
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella or die "E0 Stella certification requires Stella\n";
   my $xvfb=find_executable('Xvfb') or die "E0 Stella certification requires Xvfb\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   my $snap=File::Spec->catdir($tmp,'stella-snap'); my $user=File::Spec->catdir($tmp,'stella-user');
   make_path($snap,$user); unlink glob(File::Spec->catfile($snap,'*.png'));
   my $display_num=180+($$%40); $display_num++ while -e "/tmp/.X11-unix/X$display_num";
   my $display=':'.$display_num;
   my $xpid=fork(); defined($xpid) or die "fork Xvfb: $!\n";
   if ($xpid==0) { open(STDOUT,'>',File::Spec->catfile($tmp,'xvfb.log')) or die $!; open(STDERR,'>&STDOUT') or die $!; exec($xvfb,$display,'-ac','-screen','0','1024x768x24'); die "exec Xvfb: $!\n"; }
   select undef,undef,undef,0.20;
   my $xdg=File::Spec->catdir($tmp,'xdg'); make_path($xdg);
   local $ENV{DISPLAY}=$display; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp;
   local $ENV{XDG_CONFIG_HOME}=$xdg; local $ENV{SDL_AUDIODRIVER}='dummy';
   my $pid=fork(); defined($pid) or die "fork Stella: $!\n";
   if ($pid==0) {
      open(STDOUT,'>',File::Spec->catfile($tmp,'stella.log')) or die $!; open(STDERR,'>&STDOUT') or die $!;
      exec($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','E0',
           '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
           '-exitlauncher','0','-confirmexit','0','-userdir',$user,$visible);
      die "exec Stella: $!\n";
   }
   select undef,undef,undef,0.35;
   require_ok('snapshot E0 in Stella',$^X,$keys);
   my @png; for (1..40) { @png=grep { -s $_ } glob(File::Spec->catfile($snap,'*.png')); last if @png==1; select undef,undef,undef,0.05; }
   terminate_child($pid); terminate_child($xpid);
   @png==1 or die "Stella E0 produced ".scalar(@png)." snapshots\n";
   require_ok('grade E0 Stella frame',$^X,$grade,$png[0],'pass','E0');
}

print "E0 diagnostic passed\n";
