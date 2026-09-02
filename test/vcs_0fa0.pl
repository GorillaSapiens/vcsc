#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 0FA0 diagnostic passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Copy qw(copy);
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
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub write_file {
   my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n";
   print {$fh} $d; close($fh) or die "close $p: $!\n";
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
my $disas=File::Spec->catfile($repo,'disassembler','vcsc-disas');
my $roundtrip=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $profile=File::Spec->catfile($vcs,'0FA0/mapper.c26');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','10_0fa0');
my $source=File::Spec->catfile($example_dir,'fotomania_diagnostic.c26');
my $example_make=File::Spec->catfile($example_dir,'Makefile');

my $mk=read_file($example_make);
$mk =~ /^play:\s*\$\(TARGET\)\s*$/m &&
$mk =~ /^\s*stella\s+-bs\s+0FA0\s+\$\(TARGET\)\s*$/m &&
index($mk,'-DVCSC_INLINE_BANKCALL=1')<0
   or die "0FA0 play target must force Stella -bs 0FA0 without an inline-bankcall pilot define\n";
my $pt=read_file($profile);
$pt =~ /\$signature:0FA0\b/ &&
$pt =~ /cartridge\s*\{\s*\$bankcall/s &&
index($pt,'VCSC_INLINE_BANKCALL') < 0 &&
$pt =~ /\(A & \$16E0\)==\$06A0/ &&
$pt =~ /bank\s+bank0\s*\{.*?\$file_index:1.*?\$select_access:0x0fc0\s+\$bankcall_descriptor:0xc0\s+\$startup/s &&
$pt =~ /bank\s+bank1\s*\{.*?\$file_index:0.*?\$select_access:0x0fa0\s+\$bankcall_descriptor:0xa0/s
   or die "0FA0 profile topology/mask/startup contract is wrong\n";

# Pin the actual Stella-compatible mask in both execution engines.  In
# particular, do not regress to the stale $16A0 prose that has appeared in
# historical header comments; A6 and A5 both participate in bank selection.
my $simsrc=read_file(File::Spec->catfile($repo,'simulator','main.cpp'));
my $dissrc=read_file(File::Spec->catfile($repo,'disassembler','vcsc_disas.c'));
$simsrc =~ /canonical & 0x16e0u/ && $dissrc =~ /bus & 0x16e0u/
   or die "0FA0 engines lost the explicit \$16E0 selector mask\n";

my $bin=File::Spec->catfile($tmp,'0fa0.bin');
my $map=File::Spec->catfile($tmp,'0fa0.map');
require_ok('build 0FA0 simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST','-Map',$map,$source,'-o',$bin);
-s $bin==8192 or die "0FA0 output size is not 8K\n";
my $rom=read_file($bin);
substr($rom,4096+0x0ff8,4) eq '0FA0'
   or die "0FA0 signature is missing from final physical bank\n";
substr($rom,0x0ff8,4) ne '0FA0'
   or die "0FA0 signature was duplicated into physical bank 0\n";

# Physical bank 1 is the hardware/home bank. Every replicated reset/vector
# bridge must first select it with a non-destructive NOP read of canonical
# alias $0FC0, then jump into the startup code.
my $bridge=substr($rom,0x0fe0,0x12);
substr($rom,4096+0x0fe0,0x12) eq $bridge
   or die "0FA0 vector bridge differs between physical banks\n";
for my $off (0,6,12) {
   substr($bridge,$off,4) eq pack('C*',0x0c,0xc0,0x0f,0x4c)
      or die "0FA0 vector bridge does not use NOP-read \$0FC0; JMP\n";
}
my $lst=$bin; $lst =~ s/\.bin\z/.lst/; $lst=read_file($lst);
my @logical_descriptor=(0xc0,0xa0);
for my $destination (0..1) {
   my $desc=sprintf('%02x',$logical_descriptor[$destination]);
   my $count=()=$lst =~ /^\s*\d+\s+[0-9a-f]{4}\s+[0-9a-f]{2}\s+[0-9a-f]{2}\s+\Q$desc\E\s+; \.banktarget call_target\Q$destination\E\b/gmi;
   $count==1
      or die "0FA0 destination bank $destination descriptor payload count is $count, expected 1\n";
}
my @trampoline=map { substr($rom,$_ * 4096 + 0x0f00,0x48) } 0..1;
my @source_diff=grep {
   my $off=$_;
   ord(substr($trampoline[0],$off,1)) != ord(substr($trampoline[1],$off,1));
} 0..0x47;
@source_diff==1
   or die "0FA0 descriptor trampoline copies do not differ at exactly one source-descriptor byte\n";
my @physical_descriptor=(0xa0,0xc0);
for my $file_bank (0..1) {
   ord(substr($trampoline[$file_bank],$source_diff[0],1))==$physical_descriptor[$file_bank]
      or die sprintf("0FA0 file bank %d baked source descriptor is not \$%02X\n",$file_bank,$physical_descriptor[$file_bank]);
   (()=$trampoline[$file_bank] =~ /\x1C\x00\x0F/sg)>=2 &&
   index($trampoline[$file_bank],pack('C*',0x99,0x00,0x0F))<0 &&
   index($trampoline[$file_bank],pack('C*',0x9D,0x00,0x0F))<0
      or die "0FA0 inline bank-call block does not use read-only descriptor selectors from \$0F00\n";
}

my $m=read_file($map);
$m =~ /^\s+bank0\s+file-index=1\b.*mode=selector\s+select-access=\$0FC0\s+startup=yes/m &&
$m =~ /^\s+bank1\s+file-index=0\b.*mode=selector\s+select-access=\$0FA0/m &&
$m =~ /vector-bridge=\$0FE0\s+size=\$0012/ &&
$m =~ /^TRAMPOLINES$/m &&
$m =~ /generic-jsr=\$048\b.*\bentries=0\s+jmp=0\s+jsr=0\b/ &&
$m !~ /JSR entry=/
   or die "0FA0 map topology/inline-trampoline contract is wrong\n$m";
$lst =~ /\[bank bank0\] \| call_return := call_target0\(\);\n[^\n]*; JSR call_target0[^\n]*\n(?![^\n]*\.banktarget)/ &&
$lst =~ /\[bank bank0\] \| call_return := call_target1\(\);\n[^\n]*; JSR call_target1[^\n]*\n[^\n]*; \.banktarget call_target1/ &&
$lst =~ /\[bank bank1\] \| call_return := call_target0\(\);\n[^\n]*; JSR call_target0[^\n]*\n[^\n]*; \.banktarget call_target0/ &&
$lst =~ /\[bank bank1\] \| call_return := call_target1\(\);\n[^\n]*; JSR call_target1[^\n]*\n(?![^\n]*\.banktarget)/
   or die "0FA0 diagnostic did not keep same-bank calls as ordinary JSRs and cross-bank calls as inline bundles\n";
my %sym=map { $_=>map_symbol($m,$_) } qw(simulator_done failure call_count nested_count);
for my $start (0..1) {
   my($out,$err)=require_ok("simulate 0FA0 from physical bank $start",$sim,'--map',$map,
      "--start-bank=$start",sprintf('--stop-pc=0x%04X',$sym{simulator_done}),
      '--dump-on-stop',$bin);
   $err eq '' or die "0FA0 simulator start bank $start wrote stderr:\n$err";
   my $mem=parse_hex_dump($out);
   $mem->[$sym{failure}]==0
      or die sprintf("0FA0 self-test from bank %d failed: failure=\$%02X\n",$start,$mem->[$sym{failure}]);
   $mem->[$sym{call_count}]==4 && $mem->[$sym{nested_count}]==1
      or die "0FA0 full ordered call matrix/nested return failed from physical bank $start\n";
}

# Explicitly certify the mask aliases and underlying low-memory access. Start in
# physical bank 1. A write to $07A7 selects bank 0 and remains visible in the
# console-memory model; bank 0 reads it back. A write/read through $0ECF selects
# bank 1. Finally NOP $0FA0 is a read-triggered switch back to bank 0, proven by
# executing bank-0-only code afterward.
my $alias_bin=File::Spec->catfile($tmp,'0fa0-alias.bin');
my $w=("\xFF" x 8192);
# physical bank 1: F000 -> write bank-0 alias, then continue at F005 in bank 0
substr($w,4096+0x0000,5)=pack('C*',0xA9,0x5A,0x8D,0xA7,0x07);
# physical bank 0: read alias; publish; write bank-1 alias -> continue at F010 bank 1
substr($w,0x0005,11)=pack('C*',0xAD,0xA7,0x07,0x8D,0x80,0x00,0xA9,0xA5,0x8D,0xCF,0x0E);
# physical bank 1: read bank-1 alias; publish; NOP-read canonical bank-0 selector
substr($w,4096+0x0010,9)=pack('C*',0xAD,0xCF,0x0E,0x8D,0x81,0x00,0x0C,0xA0,0x0F);
# physical bank 0: prove selection by publishing a third sentinel and stopping
substr($w,0x0019,8)=pack('C*',0xA9,0x3C,0x8D,0x82,0x00,0x4C,0x1E,0xF0);
for my $fb (0..1) { substr($w,$fb*4096+0x0ffc,2)=pack('C*',0x00,0xF0); }
write_file($alias_bin,$w);
my($aout,$aerr)=require_ok('simulate 0FA0 masked aliases',$sim,'--map',$map,
   '--start-bank=1','--stop-pc=0xF01E','--dump-on-stop',$alias_bin);
$aerr eq '' or die "0FA0 alias simulator wrote stderr:\n$aerr";
my $amem=parse_hex_dump($aout);
$amem->[0x0080]==0x5A && $amem->[0x0081]==0xA5 && $amem->[0x0082]==0x3C &&
$amem->[0x07A7]==0x5A && $amem->[0x0ECF]==0xA5
   or die "0FA0 masked read/write aliases did not switch banks and preserve underlying accesses\n";

my $visible=File::Spec->catfile($tmp,'0fa0-visible.bin');
require_ok('build visible 0FA0 PASS/FAIL cartridge',$driver,'-I',$vcs,$source,'-o',$visible);
my $vrom=read_file($visible);
length($vrom)==8192 && substr($vrom,4096+0x0ff8,4) eq '0FA0' &&
index($vrom,pack('C*',0x2c,0xc0,0x0f))>=0
   or die "visible 0FA0 diagnostic lost its layout/Stella detector signature\n";

my $s26=File::Spec->catfile($tmp,'0fa0-visible.s26');
require_ok('disassemble 0FA0 cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: 0FA0 \(high confidence;/m &&
$dis =~ /^; reset\/power-on bank: 1 \(0FA0 hardware default\)$/m &&
$dis =~ /^; 0FA0 selectors: \(A & \$16E0\)==\$06A0->\$0, ==\$06C0->\$1; canonical aliases \$0FA0\/\$0FC0; bank 1 powers up$/m
   or die "vcsc-disas did not recognize 0FA0 semantics\n$dis";

my $rt_in=File::Spec->catdir($tmp,'roundtrip-in');
my $rt_out=File::Spec->catdir($tmp,'roundtrip-out');
make_path($rt_in,$rt_out);
copy($visible,File::Spec->catfile($rt_in,'0fa0-visible.bin'))
   or die "copy 0FA0 roundtrip input: $!\n";
require_ok('round-trip 0FA0 cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'0fa0-visible.bin')) eq $vrom
   or die "0FA0 disassembler round trip is not byte-exact\n";

print "0FA0 diagnostic passed\n";
