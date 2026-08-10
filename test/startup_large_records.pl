#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 60
# expectstdout: startup large records passed: 300-byte DATA copy and BSS zero
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my ($fh)=@_; local $/; return <$fh> // ''; }
sub capture {
   my (@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8, $? & 127, $so, $se);
}
sub write_file { my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n"; print {$fh} $d; close($fh) or die "close $p: $!\n"; }
sub read_file { my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>//''; close($fh); return $d; }
sub parse_symbol { my($s,$n)=@_; $s =~ /^\Q$n\E\s+([0-9A-Fa-f]{4})\s*$/m or die "missing symbol $n\n"; return hex($1); }
sub parse_dump {
   my($t)=@_; my @m=(0)x65536;
   for my $line (split /\n/,$t) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($n,$a,$bytes)=(hex($1),hex($2),$3);
      length($bytes)==$n*2 or die "bad dump record\n";
      for my $i (0..$n-1) { $m[$a+$i]=hex(substr($bytes,$i*2,2)); }
   }
   return \@m;
}

my($repo,$tmp)=@ARGV; die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $inc=File::Spec->catdir($repo,'test');
my $cfg=File::Spec->catfile($inc,'generic_6502.cfg');
my $src=File::Spec->catfile($tmp,'startup_large_records.c26');
my $hex=File::Spec->catfile($tmp,'startup_large_records.hex');
my $map=File::Spec->catfile($tmp,'startup_large_records.map');
my $sym=File::Spec->catfile($tmp,'startup_large_records.sym');
my @values=map { ($_*37+11)&255 } 0..299;
my $values=join(', ',@values);
write_file($src, qq{include "machine_6502.c26"\nuint8_t result;\nuint8_t seeded[300] := { $values };\nuint8_t zeroed[300];\nvoid simulator_done(void) { while (1) {} }\nvoid main(void) {\n   result := 1;\n   if (seeded[0] != $values[0] || seeded[255] != $values[255] || seeded[256] != $values[256] || seeded[299] != $values[299]) { result := 0xe1; }\n   if (zeroed[0] != 0 || zeroed[255] != 0 || zeroed[256] != 0 || zeroed[299] != 0) { result := 0xe2; }\n   if (result == 1) { result := 0xaa; }\n   asm jmp simulator_done;\n}\n});
my($rc,$sig,$out,$err)=capture($driver,'-I',$inc,'-T',$cfg,'-Map',$map,'-Sym',$sym,$src,'-o',$hex);
$rc==0 && !$sig or die "large startup fixture build failed\n$out$err";
$err eq '' or die "large startup fixture wrote stderr\n$err";
my $maptext=read_file($map);
$maptext =~ /^\s+COPY\s+DATA\.__vcsc_object\$seeded\s+load=\$[0-9A-F]{4}\s+read=\$[0-9A-F]{4}\s+write=\$[0-9A-F]{4}\s+size=\$012C\b/m
   or die "300-byte DATA copy record missing\n$maptext";
$maptext =~ /^\s+ZERO\s+BSS\.__vcsc_object\$zeroed\s+read=\$[0-9A-F]{4}\s+write=\$[0-9A-F]{4}\s+size=\$012C\b/m
   or die "300-byte BSS zero record missing\n$maptext";
my $symtext=read_file($sym);
my $done=parse_symbol($symtext,'simulator_done');
my $result=parse_symbol($symtext,'result');
($rc,$sig,$out,$err)=capture($sim,'-T',$cfg,sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$hex);
$rc==0 && !$sig or die "large startup fixture simulation failed\n$out$err";
$err eq '' or die "large startup fixture simulator wrote stderr\n$err";
my $mem=parse_dump($out);
$mem->[$result]==0xaa or die sprintf("large startup status is %02X, expected AA\n",$mem->[$result]);
print "startup large records passed: 300-byte DATA copy and BSS zero\n";
