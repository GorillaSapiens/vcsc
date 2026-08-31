#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: OMNI 32K direct profile passed
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
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $data=<$fh>; close($fh); return $data // '';
}
sub write_file {
   my($path,$data)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $data or die "write $path: $!\n"; close($fh) or die "close $path: $!\n";
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
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $cfg=File::Spec->catfile($vcs,'vcs.cfg');
my $profile=File::Spec->catfile($vcs,'OMNI/mapper.c26');
my $sim_cfg=File::Spec->catfile($vcs,'OMNI/mapper.cfg');
my $diagnostic=File::Spec->catfile($repo,'examples','09_bankswitching','05_omni','omni_diagnostic.c26');

my $profile_text=read_file($profile);
$profile_text =~ /No real hardware currently supports this configuration/ &&
$profile_text =~ /\$signature:OMNI/ &&
(()=$profile_text =~ /\$image_size:0x1000/g)==8 &&
(()=$profile_text =~ /\$select_access:/g)==0 &&
(()=$profile_text =~ /\$ro\b/g)==7 &&
(()=$profile_text =~ /\$rw\b/g)==1 &&
$profile_text =~ /mem\s+cartram\s*\{\s*\$start:0x1000\s+\$size:0x1000\s+\$rw\s*\}/s
   or die "OMNI profile topology/capability contract is wrong\n";

my $src=File::Spec->catfile($tmp,'omni.c26');
write_file($src,<<'SRC');
include "OMNI/mapper.c26"
bank6 const uint8_t marker := 0x42;
bank6 uint8_t helper(void) { return marker; }
cartram uint8_t ram_value := 0x5a;
cartram uint8_t scratch;
void main(void) {
   scratch := helper();
   ram_value := scratch;
   COLUBK := ram_value;
   asm @forever:;
   asm jmp @forever;
}
SRC

my $bin=File::Spec->catfile($tmp,'omni.bin');
my $map=File::Spec->catfile($tmp,'omni.map');
require_ok('build OMNI direct profile',$driver,'-I',$vcs,'-T',$cfg,'-Map',$map,$src,'-o',$bin);
-s $bin==32768 or die "OMNI profile did not emit exactly 32K\n";
my $rom=read_file($bin);
my $m=read_file($map);

my @addr=(0xf000,0xd000,0xb000,0x9000,0x7000,0x5000,0x3000,0x1000);
for my $bank (0..7) {
   my $file=7-$bank;
   my $addr=sprintf('%04X',$addr[$bank]);
   $m =~ /^\s+bank\Q$bank\E\s+file-index=\Q$file\E\b.*link=\$\Q$addr\E\s+cpu=\$\Q$addr\E\b.*mode=direct/m
      or die "OMNI bank$bank topology/file order is wrong\n";
}
$m =~ /^\s+cartram\s+start=\$1000\s+size=\$1000\s+type=rw\b.*mode=direct/m &&
$m =~ /^\s+bank0\s+start=\$F000\s+size=\$0FF8\s+type=ro\s+priority=2\b.*mode=direct/m
   or die "OMNI RO/RW memory layout is wrong\n";
$m =~ /^\s+\$F000\s+main\b/m &&
$m =~ /^\s+\$3001\s+helper\b/m &&
$m =~ /^\s+\$3000\s+marker\b/m &&
$m =~ /^\s+\$1000\s+scratch\b/m &&
$m =~ /^\s+\$1001\s+ram_value\b/m
   or die "OMNI explicit code/data placement is wrong\n";
$m =~ /^\s+COPY\s+DATA\.cartram\.__vcsc_object\$ram_value\s+load=\$[0-9A-F]{4}\s+read=\$1001\s+write=\$1001\s+size=\$0001/m &&
$m =~ /^\s+ZERO\s+BSS\.cartram\.__vcsc_object\$scratch\s+read=\$1000\s+write=\$1000\s+size=\$0001/m
   or die "OMNI did not reuse normal initialized-DATA/BSS startup semantics\n";
$m =~ /^BANK PLACEMENT$/m && $m !~ /^TRAMPOLINES$/m && $m !~ /^VECTOR BRIDGES$/m &&
$m =~ /pinned\s+CODE\.__vcsc_function\$main\s+region=bank0/m
   or die "OMNI direct profile placement or switched-bank machinery is wrong\n";

substr($rom,0,4096) eq ("\xFF" x 4096)
   or die "OMNI writable file chunk should remain cartridge fill; DATA initializes at startup\n";
substr($rom,0x7ff8,4) eq 'OMNI'
   or die "OMNI final-bank signature is missing\n";
for my $file_bank (0..6) {
   substr($rom,$file_bank*4096+0x0ff8,4) ne 'OMNI'
      or die "OMNI signature was duplicated into file chunk $file_bank\n";
}
index(substr($rom,7*4096),"\x20\x01\x30")>=0
   or die "OMNI cross-island helper call is not an ordinary JSR \$3001\n";
index($rom,"\xAD\x00\x30")>=0
   or die "OMNI helper did not emit an ordinary direct read from cross-island RODATA at \$3000\n";


# The public diagnostic certifies the complete OMNI contract under the simulator's
# direct logical-address model. No selector or bank state is involved.
my $diag_text=read_file($diagnostic);
$diag_text =~ /include "OMNI\/mapper\.c26"/ &&
$diag_text =~ /cartram uint8_t omni_bss\[4095\]/ &&
$diag_text =~ /load_omni_type\(\)/ &&
$diag_text =~ /blank \/ O \/ M \/ N \/ I \/ blank/
   or die "OMNI public diagnostic lost its RAM or visible mapper contract\n";
-f $sim_cfg or die "OMNI simulator cfg is missing\n";
my $cfg_text=read_file($sim_cfg);
$cfg_text =~ /mapper\s*=\s*OMNI/ &&
$cfg_text =~ /^\s*BANK7:\s+start\s*=\s*\$1000,\s*size\s*=\s*\$1000/mi &&
$cfg_text =~ /^\s*BANK6:\s+start\s*=\s*\$3000,\s*size\s*=\s*\$1000/mi &&
$cfg_text =~ /^\s*BANK5:\s+start\s*=\s*\$5000,\s*size\s*=\s*\$1000/mi &&
$cfg_text =~ /^\s*BANK4:\s+start\s*=\s*\$7000,\s*size\s*=\s*\$1000/mi &&
$cfg_text =~ /^\s*BANK3:\s+start\s*=\s*\$9000,\s*size\s*=\s*\$1000/mi &&
$cfg_text =~ /^\s*BANK2:\s+start\s*=\s*\$B000,\s*size\s*=\s*\$1000/mi &&
$cfg_text =~ /^\s*BANK1:\s+start\s*=\s*\$D000,\s*size\s*=\s*\$1000/mi &&
$cfg_text =~ /^\s*BANK0:\s+start\s*=\s*\$F000,\s*size\s*=\s*\$1000,\s*startup\s*=\s*yes/mi &&
$cfg_text =~ /^\s*cartram:\s+start\s*=\s*\$1000,\s*size\s*=\s*\$1000,\s*type\s*=\s*rw/mi
   or die "OMNI simulator cfg does not describe eight direct islands and cartram\n";

my $diag_bin=File::Spec->catfile($tmp,'omni-diagnostic.bin');
my $diag_map=File::Spec->catfile($tmp,'omni-diagnostic.map');
require_ok('build OMNI simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST',
   '-T',$cfg,'-Map',$diag_map,$diagnostic,'-o',$diag_bin);
-s $diag_bin==32768 or die "OMNI diagnostic output size is not 32K\n";
my $dm=read_file($diag_map);
$dm =~ /cartram\s+used=4096 bytes \(100\.00%\).*free=0 bytes/m &&
$dm !~ /^TRAMPOLINES$/m && $dm !~ /^VECTOR BRIDGES$/m
   or die "OMNI diagnostic does not consume all cartram or generated switched-bank machinery\n$dm";
for my $name (qw(probe6 probe5 probe4 probe3 probe2 probe1 home_probe)) {
   $dm =~ /^\s*\$[0-9A-F]{4}\s+\Q$name\E\b/m
      or die "OMNI diagnostic map is missing $name\n";
}
my %sym=map { $_=>map_symbol($dm,$_) } qw(simulator_done failure trace probe_count omni_bss omni_data);
my($simout,$simerr)=require_ok('simulate OMNI direct diagnostic',$sim,'-T',$sim_cfg,
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$diag_bin);
$simerr eq '' or die "OMNI simulator wrote stderr:\n$simerr";
my $mem=parse_hex_dump($simout);
$mem->[$sym{failure}]==0 or die sprintf("OMNI self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{trace}]==7 && $mem->[$sym{probe_count}]==7
   or die "OMNI direct-island call trace did not visit all seven RO islands\n";
$mem->[$sym{omni_data}]==0xA5 &&
$mem->[$sym{omni_bss}+0]==0x11 &&
$mem->[$sym{omni_bss}+2047]==0x22 &&
$mem->[$sym{omni_bss}+4094]==0x33
   or die "OMNI full cartram initialization/persistence test failed\n";

my $visible=File::Spec->catfile($tmp,'omni-visible.bin');
require_ok('build visible OMNI PASS/FAIL cartridge',$driver,'-I',$vcs,'-T',$cfg,$diagnostic,'-o',$visible);
my $vrom=read_file($visible);
length($vrom)==32768 && substr($vrom,0x7ff8,4) eq 'OMNI'
   or die "visible OMNI diagnostic lost its 32K layout/signature\n";

print "OMNI 32K direct profile passed\n";
