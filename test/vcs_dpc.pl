#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: DPC diagnostic passed
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
sub require_fail {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=run_capture(@cmd);
   ($rc!=0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n";
   return ($out,$err);
}
sub read_file {
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub write_file {
   my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n";
   print {$fh} $d; close($fh) or die "close $p: $!\n";
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
sub poly_step {
   my($x)=@_;
   my @f=(1,0,0,1,0,1,1,0,0,1,1,0,1,0,0,1);
   my $i=(($x>>3)&7) | (($x&0x80)?8:0);
   return (($x<<1)&0xff) | $f[$i];
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
my $cfg=File::Spec->catfile($vcs,'vcs_10k_dpc.cfg');
my $profile=File::Spec->catfile($vcs,'vcs_10k_dpc.c26');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','16_dpc');
my $source=File::Spec->catfile($example_dir,'dpc_diagnostic.c26');

my $pt=read_file($profile);
(()=$pt =~ /\bbank\s+bank\d+\s*\{/g)==4 &&
$pt =~ /bank\s+bank2\s*\{.*?\$image_size:0x0800.*?\$file_index:2.*?\$data_only/s &&
$pt =~ /bank\s+bank3\s*\{.*?\$image_size:0x00ff.*?\$file_index:3.*?\$data_only/s &&
$pt =~ /mem\s+bank2\s*\{.*?\$size:0x0800.*?\$ro.*?\$data_bank:bank2/s &&
$pt =~ /mem\s+bank3\s*\{.*?\$size:0x00ff.*?\$ro.*?\$data_bank:bank3/s
   or die "DPC C26 profile lost its F8 + 2K/255-byte data-only topology\n";
my $ct=read_file($cfg);
$ct =~ /mapper\s*=\s*DPC/ && (()=$ct =~ /size\s*=\s*\$1000/g)==2
   or die "DPC simulator cfg must expose exactly the two F8 program banks\n";
my $mk=read_file(File::Spec->catfile($example_dir,'Makefile'));
$mk =~ /^play:\s*\$\(TARGET\)\s*$/m && $mk =~ /^\s*stella\s+-bs\s+DPC\s+\$\(TARGET\)\s*$/m
   or die "DPC play target must force Stella -bs DPC\n";

my $bin=File::Spec->catfile($tmp,'dpc.bin');
my $map_path=File::Spec->catfile($tmp,'dpc.map');
require_ok('build DPC simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST',
   '-T',$generic,'-Map',$map_path,$source,'-o',$bin);
my $rom=read_file($bin);
length($rom)==10495 or die "DPC output size is not 10495 bytes\n";
substr($rom,0,0x80) eq ("\xFF" x 0x80) or die "DPC physical bank 0 hidden register prefix is not fill bytes\n";
substr($rom,0x1000,0x80) eq ("\xFF" x 0x80) or die "DPC physical bank 1 hidden register prefix is not fill bytes\n";
substr($rom,0x1000+0x0ff8,4) eq "DPC\0" or die "DPC signature is not in the final CPU-mapped program bank\n";

my $display='';
for my $i (0..2047) {
   $display .= chr((($i*73) ^ ($i>>3) ^ int(($i*29)/256) ^ 0x5a) & 0xff);
}
substr($rom,0x2000,0x800) eq $display or die "DPC 2K data-only display bank is not byte-exact\n";
my $poly=''; my $x=0;
for (1..255) { $poly .= chr($x); $x=poly_step($x); }
$x==0 or die "test Poly8 generator did not close after 255 states\n";
substr($rom,0x2800,0xff) eq $poly or die "DPC 255-byte data-only Poly8 bank is not byte-exact\n";

my $map=read_file($map_path);
$map =~ /output-size=\$000028FF/ &&
$map =~ /bank2\s+file-index=2\s+image-size=\$0800.*mode=data-only/ &&
$map =~ /bank3\s+file-index=3\s+image-size=\$00FF.*mode=data-only/ &&
$map =~ /bank2\s+used=2048 bytes \(100\.00%\)/ &&
$map =~ /bank3\s+used=255 bytes \(100\.00%\)/ &&
$map =~ /RODATA\.bank2\.__vcsc_object\$dpc_display_data load=\$0000 size=\$0800/ &&
$map =~ /RODATA\.bank3\.__vcsc_object\$dpc_poly_data load=\$0000 size=\$00FF/
   or die "DPC map lost data-only bank layout\n$map";
$map =~ /JSR entry=.*source=bank0 hotspot=\$1FF9 destination=bank1 hotspot=\$1FF8/i &&
$map =~ /JSR entry=.*source=bank1 hotspot=\$1FF8 destination=bank0 hotspot=\$1FF9/i
   or die "DPC visible self-test no longer generates both ordered program-bank JSR bridges\n$map";
my %sym=map { $_=>map_symbol($map,$_) } qw(simulator_done failure display_sum1 display_sum2 actual_rng expected_rng);
my($out,$err)=require_ok('simulate DPC fetchers and RNG',$sim,'-T',$cfg,
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$err eq '' or die "DPC simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($out);
$mem->[$sym{failure}]==0 or die sprintf("DPC self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{display_sum1}]==0xA0 && $mem->[$sym{display_sum2}]==0x90
   or die "DPC simulator did not traverse the full display-data bank\n";
$mem->[$sym{expected_rng}]==1 && $mem->[$sym{actual_rng}]==1
   or die "DPC simulator did not complete the 255-state RNG cycle\n";

my $bad=File::Spec->catfile($tmp,'bad-data-ref.c26');
write_file($bad,<<'SRC');
include "vcs_10k_dpc.c26"
bank2 const uint8_t hidden[1] := {0x5A};
void main(void) { uint8_t x; x := hidden[0]; if (x) { asm nop; } while (1) { } }
SRC
my($bout,$berr)=require_fail('reject CPU reference to data-only object',$driver,'-I',$vcs,'-T',$generic,$bad,'-o',File::Spec->catfile($tmp,'bad.bin'));
($bout.$berr) =~ /data-only.*no 6507 address/is
   or die "data-only CPU-reference rejection lacked a useful diagnostic\nstdout:\n$bout\nstderr:\n$berr";

my $visible=File::Spec->catfile($tmp,'dpc-visible.bin');
my $visible_map=File::Spec->catfile($tmp,'dpc-visible.map');
require_ok('build visible DPC PASS/FAIL cartridge',$driver,'-I',$vcs,'-T',$generic,
   '-Map',$visible_map,$source,'-o',$visible);
my $vrom=read_file($visible);
length($vrom)==10495 && substr($vrom,0x2000,0x800) eq $display && substr($vrom,0x2800,0xff) eq $poly
   or die "visible DPC diagnostic lost its data-only banks\n";
my $s26=File::Spec->catfile($tmp,'dpc-visible.s26');
require_ok('disassemble DPC cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: DPC \(high confidence;/m &&
$dis =~ /^; DPC auxiliary data ROM: file \$2000\.\.\$27FF \(2048 bytes\)$/m &&
$dis =~ /^; DPC RNG table: file \$2800\.\.\$28FE \(255 bytes\)$/m
   or die "vcsc-disas did not recognize the DPC image regions\n$dis";
my $rt_in=File::Spec->catdir($tmp,'roundtrip-in');
my $rt_out=File::Spec->catdir($tmp,'roundtrip-out');
make_path($rt_in,$rt_out);
copy($visible,File::Spec->catfile($rt_in,'dpc-visible.bin')) or die "copy DPC roundtrip input: $!\n";
require_ok('round-trip DPC cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'dpc-visible.bin')) eq $vrom
   or die "DPC disassembler round trip is not byte-exact\n";

if ($stella_mode) {
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella or die "DPC Stella certification requires Stella\n";
   my $xvfb=find_executable('Xvfb') or die "DPC Stella certification requires Xvfb\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   my $snap=File::Spec->catdir($tmp,'stella-snap');
   my $user=File::Spec->catdir($tmp,'stella-user');
   make_path($snap,$user); unlink glob(File::Spec->catfile($snap,'*.png'));
   my $display_num=180+($$%40); $display_num++ while -e "/tmp/.X11-unix/X$display_num";
   my $display=':'.$display_num;
   my $xpid=fork(); defined($xpid) or die "fork Xvfb: $!\n";
   if ($xpid==0) {
      open(STDOUT,'>',File::Spec->catfile($tmp,'xvfb.log')) or die $!;
      open(STDERR,'>&STDOUT') or die $!;
      exec($xvfb,$display,'-ac','-screen','0','1600x1200x24'); die "exec Xvfb: $!\n";
   }
   select undef,undef,undef,0.20;
   my $xdg=File::Spec->catdir($tmp,'xdg'); make_path($xdg);
   local $ENV{DISPLAY}=$display; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp;
   local $ENV{XDG_CONFIG_HOME}=$xdg; local $ENV{SDL_AUDIODRIVER}='dummy';
   my $pid=fork(); defined($pid) or die "fork Stella: $!\n";
   if ($pid==0) {
      open(STDOUT,'>',File::Spec->catfile($tmp,'stella.log')) or die $!;
      open(STDERR,'>&STDOUT') or die $!;
      exec($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','DPC',
           '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
           '-exitlauncher','0','-confirmexit','0','-userdir',$user,$visible);
      die "exec Stella: $!\n";
   }
   select undef,undef,undef,0.35;
   require_ok('snapshot DPC in Stella',$^X,$keys);
   my @png;
   for (1..40) {
      @png=grep { -s $_ } glob(File::Spec->catfile($snap,'*.png'));
      last if @png==1;
      select undef,undef,undef,0.05;
   }
   terminate_child($pid); terminate_child($xpid);
   @png==1 or die "Stella DPC produced ".scalar(@png)." snapshots\n";
   require_ok('grade DPC Stella frame',$^X,$grade,$png[0],'pass','DPC');
}

print "DPC diagnostic passed\n";
