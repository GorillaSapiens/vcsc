#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: CV diagnostic passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Copy qw(copy);
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
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $cfg=File::Spec->catfile($vcs,'CV/mapper.cfg');
my $profile=File::Spec->catfile($vcs,'CV/mapper.c26');
my $device=File::Spec->catfile($vcs,'CV/ram.c26');
my $source=File::Spec->catfile($repo,'examples','09_bankswitching','06_cv','cv_diagnostic.c26');

my $pt=read_file($profile);
my $dt=read_file($device);
$pt =~ /include\s+"CV\/ram\.c26"/ &&
$pt =~ /\$signature:CV\b/ &&
$pt =~ /\$image_size:0x0800/ &&
$pt =~ /\$link_start:0xf800\s+\$cpu_start:0xf800\s+\$map_size:0x0800/ &&
$dt =~ /mem\s+cartram\s*\{\s*\$read_start:0xF000\s+\$write_start:0xF400\s+\$size:0x0400\s+\$rw\s+\$read_hazard\s*\}/s
   or die "CV profile/device contract is wrong\n";

my $bin=File::Spec->catfile($tmp,'cv.bin');
my $map=File::Spec->catfile($tmp,'cv.map');
require_ok('build CV simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST',
   '-T',$generic,'-Map',$map,$source,'-o',$bin);
-s $bin==2048 or die "CV output size is not 2048 bytes\n";
my $rom=read_file($bin);
substr($rom,0x07f8,4) eq "CV\0\0"
   or die "CV signature is missing from logical \$FFF8-\$FFFB\n";
index($rom,pack('C*',0x99,0x00,0xF4))>=0
   or die "CV diagnostic lost Stella's STA \$F400,Y autodetection signature\n";
my $m=read_file($map);
$m =~ /^\s+bank0\s+file-index=0\b.*image-size=\$0800.*link=\$F800\s+cpu=\$F800\s+map-size=\$0800\s+mode=direct/m &&
$m !~ /^TRAMPOLINES$/m
   or die "CV topology is not a selector-free fixed 2K image\n$m";
$m =~ /^\s+cartram\s+read_start=\$F000 write_start=\$F400 size=\$0400 type=rw shared=yes\b/m
   or die "CV split-address cartram map is missing\n$m";
$m =~ /cartram\s+used=1024 bytes \(100\.00%\).*free=0 bytes/m
   or die "CV diagnostic does not allocate all 1024 cartram bytes\n$m";
$m =~ /COPY DATA\.cartram\.__vcsc_object\$cv_data\s+load=\$[0-9A-F]{4}\s+read=\$F3FF\s+write=\$F7FF\s+size=\$0001\s+split=yes/m &&
$m =~ /ZERO BSS\.cartram\.__vcsc_object\$cv_bss\s+read=\$F000\s+write=\$F400\s+size=\$03FF\s+split=yes/m
   or die "CV DATA/BSS startup does not use the split aliases\n$m";

my %sym=map { $_=>map_symbol($m,$_) } qw(simulator_done failure cv_bss cv_data);
my($out,$err)=require_ok('simulate CV with hostile cartridge RAM',$sim,'-T',$cfg,
   '--split-fill=0xA7',sprintf('--reset-on-pc=0x%04X',$sym{simulator_done}),
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$err eq '' or die "CV simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($out);
$mem->[$sym{failure}]==0 or die sprintf("CV self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{cv_data}]==0xA5 or die "CV DATA byte did not survive split aliases\n";
$mem->[$sym{cv_bss}+0]==0x11 &&
$mem->[$sym{cv_bss}+511]==0x22 &&
$mem->[$sym{cv_bss}+1022]==0x33
   or die "CV BSS sentinels did not survive split aliases\n";

my $visible=File::Spec->catfile($tmp,'cv-visible.bin');
require_ok('build visible CV PASS/FAIL cartridge',$driver,'-I',$vcs,'-T',$generic,$source,'-o',$visible);
my $vrom=read_file($visible);
length($vrom)==2048 && substr($vrom,0x07f8,4) eq "CV\0\0" &&
index($vrom,pack('C*',0x99,0x00,0xF4))>=0
   or die "visible CV diagnostic lost its fixed layout/signatures\n";

my $s26=File::Spec->catfile($tmp,'cv-visible.s26');
require_ok('disassemble CV cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: CV \(high confidence;/m &&
$dis =~ /^; CV cartridge RAM: read \$1000-\$13FF, write \$1400-\$17FF \(1024 bytes\)$/m
   or die "vcsc-disas did not recognize CV/RAM layout\n$dis";

my $rt_in=File::Spec->catdir($tmp,'roundtrip-in');
my $rt_out=File::Spec->catdir($tmp,'roundtrip-out');
make_path($rt_in,$rt_out);
my $rt_bin=File::Spec->catfile($rt_in,'cv-visible.bin');
copy($visible,$rt_bin) or die "copy CV roundtrip input: $!\n";
require_ok('round-trip CV cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'cv-visible.bin')) eq $vrom
   or die "CV disassembler round trip is not byte-exact\n";

print "CV diagnostic passed\n";
