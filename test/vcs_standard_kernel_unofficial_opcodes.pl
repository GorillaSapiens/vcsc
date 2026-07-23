#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub read_file { my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$f>; close($f); return defined($d)?$d:''; }
sub write_file { my($p,$d)=@_; open(my $f,'>',$p) or die "write $p: $!\n"; print {$f} $d; close($f); }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   local $/; my $so=<$out>//''; my $se=<$err>//''; waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub ihex_data {
   my($text,$length)=@_; my %m;
   for my $line (split(/\n/,$text)) {
      next if $line eq ''; $line =~ /^:([0-9A-Fa-f]+)$/ or die "bad ihex line: $line\n";
      my $raw=pack('H*',$1); my($len,$hi,$lo,$type)=unpack('C4',$raw);
      next if $type==1; $type==0 or die "unexpected ihex record type $type\n";
      my $addr=($hi<<8)|$lo; my @b=unpack('C*',substr($raw,4,$len));
      $m{$addr+$_}=$b[$_] for 0..$#b;
   }
   return pack('C*',map {$m{$_}//die sprintf("missing ihex byte %04X\n",$_)}
                         0x8000..0x8000+$length-1);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp);
my $dir=File::Spec->catdir($repo,qw(libraries vcs kernels standard_4k_ntsc));
for my $name ('standard_4k_ntsc_macros.inc','standard_4k_ntsc_kernel.s26') {
   my $path=File::Spec->catfile($dir,$name);
   my $line=0;
   for my $raw (split(/\n/,read_file($path))) {
      ++$line;
      $raw =~ s/;.*$//;
      $raw =~ s/^\s+|\s+$//g;
      next if $raw eq '';
      $raw !~ /^(?:ASR|DCP|LAX|SBX|NOP\.z)\b/i
         or die "$name:$line retains unofficial source mnemonic: $raw\n";
   }
}
my $asm=File::Spec->catfile($repo,'assembler','vcsc-as');
my $legal_src=File::Spec->catfile($tmp,'legal_replacement_probe.s26');
my $legal_hex=File::Spec->catfile($tmp,'legal_replacement_probe.hex');
write_file($legal_src,<<'ASM');
.segmentdef "CODE", $8000, $0100
.segment "CODE"
AND #$F0
LSR
TXA
ADC #4
TAX
BIT $00
ASM
my($rc,$sig,$out,$err)=capture($asm,"--hex=$legal_hex",$legal_src);
$rc==0 && !$sig or die "legal replacement probe assembly failed\n$out$err";
my $legal_bytes=ihex_data(read_file($legal_hex),9);
unpack('H*',$legal_bytes) eq '29f04a8a6904aa2400'
   or die "legal replacement byte matrix changed: ".unpack('H*',$legal_bytes)."\n";

my $src=File::Spec->catfile($tmp,'unofficial_probe.s26');
my $hex=File::Spec->catfile($tmp,'unofficial_probe.hex');
write_file($src,<<'ASM');
.segmentdef "CODE", $8000, $0100
.segment "CODE"
ASR #$F0
SBX #252
NOP.z $00
ASM
($rc,$sig,$out,$err)=capture($asm,'--illegals',"--hex=$hex",$src);
$rc==0 && !$sig or die "probe assembly failed\n$out$err";
my $bytes=ihex_data(read_file($hex),6);
unpack('H*',$bytes) eq '4bf0cbfc0400' or die "removed unofficial byte matrix changed: ".unpack('H*',$bytes)."\n";
($rc,$sig,$out,$err)=capture($asm,"--hex=$hex.no_illegals",$src);
$rc!=0 or die "unofficial mnemonics assembled without --illegals\n";

my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $cycle_src=File::Spec->catfile($repo,'test','vcs_standard_kernel_unofficial_cycles.cpp');
my $cycle_exe=File::Spec->catfile($tmp,'unofficial_cycles');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$cycle_src,@mos_input,'-o',$cycle_exe);
$rc==0 && !$sig or die "cycle harness build failed\n$out$err";
($rc,$sig,$out,$err)=capture($cycle_exe);
$rc==0 && !$sig or die "cycle harness failed\n$out$err";
$out eq "vcs_standard_kernel_unofficial_cycles ok\n" or die "unexpected cycle output: $out";
$err eq '' or die "cycle harness stderr: $err";

my $doc=read_file(File::Spec->catfile($dir,'UNOFFICIAL_OPCODES.md'));
for my $needle ('stable/common','silicon-sensitive','unstable','No unofficial source sites remain','`$4B`','`$CB`','`$04`','`AND #$F0`','`ADC #4`','`BIT VSYNC`') {
   index($doc,$needle)>=0 or die "UNOFFICIAL_OPCODES.md lacks $needle\n";
}
print "vcs_standard_kernel_unofficial_opcodes ok\n";
