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
   my($text)=@_; my %m;
   for my $line (split(/\n/,$text)) {
      next if $line eq ''; $line =~ /^:([0-9A-Fa-f]+)$/ or die "bad ihex line: $line\n";
      my $raw=pack('H*',$1); my($len,$hi,$lo,$type)=unpack('C4',$raw);
      next if $type==1; $type==0 or die "unexpected ihex record type $type\n";
      my $addr=($hi<<8)|$lo; my @b=unpack('C*',substr($raw,4,$len));
      $m{$addr+$_}=$b[$_] for 0..$#b;
   }
   return pack('C*',map {$m{$_}//die sprintf("missing ihex byte %04X\n",$_)} 0x8000..0x800b);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n"; make_path($tmp); $tmp=abs_path($tmp);
my $dir=File::Spec->catdir($repo,qw(libraries vcs kernels standard_4k_ntsc));
my $gen=File::Spec->catfile($dir,'unofficial_opcodes.pl');
my $tsv=File::Spec->catfile($dir,'standard_4k_ntsc_unofficial_opcodes.tsv');
my $fresh=`cd '$dir' && ./unofficial_opcodes.pl`; $?==0 or die "generator failed\n";
$fresh eq read_file($tsv) or die "unofficial-opcode inventory is stale\n";
my @rows=grep {length} split(/\n/,$fresh); shift @rows eq join("\t",qw(file line mnemonic mode opcode bytes base_cycles page_penalty classification purpose)) or die "bad header\n";
@rows==19 or die "expected 19 retained unofficial sites, got ".scalar(@rows)."\n";
my %count;
for my $row (@rows) {
   my @f=split(/\t/,$row,-1); @f==10 or die "malformed row: $row\n";
   ++$count{"$f[2]:$f[3]"};
   $f[8] eq 'stable/common' or die "retained site is not stable/common: $row\n";
   length($f[9]) or die "missing purpose: $row\n";
}
my %want=('NOP.z:zp'=>1,'LAX:zp'=>3,'ASR:imm'=>1,'DCP:zp'=>11,'SBX:imm'=>1,'LAX:indy'=>2);
join(',',sort keys %count) eq join(',',sort keys %want) or die "retained form set changed\n";
for my $k (keys %want) { ($count{$k}//0)==$want{$k} or die "$k count changed\n"; }

my $asm=File::Spec->catfile($repo,'assembler','vcsc-as');
my $src=File::Spec->catfile($tmp,'unofficial_probe.s');
my $hex=File::Spec->catfile($tmp,'unofficial_probe.hex');
write_file($src,<<'ASM');
.segmentdef "CODE", $8000, $0100
.segment "CODE"
LAX $80
ASR #$F0
DCP $81
SBX #252
LAX ($82),Y
NOP.z $00
ASM
my($rc,$sig,$out,$err)=capture($asm,'--illegals',"--hex=$hex",$src);
$rc==0 && !$sig or die "probe assembly failed\n$out$err";
my $bytes=ihex_data(read_file($hex));
unpack('H*',$bytes) eq 'a7804bf0c781cbfcb3820400' or die "retained unofficial byte matrix changed: ".unpack('H*',$bytes)."\n";
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
for my $needle ('stable/common','silicon-sensitive','unstable','No silicon-sensitive or unstable opcode is retained','`$A7`','`$B3`','`$4B`','`$C7`','`$CB`','`$04`') {
   index($doc,$needle)>=0 or die "UNOFFICIAL_OPCODES.md lacks $needle\n";
}
print "vcs_standard_kernel_unofficial_opcodes ok\n";
