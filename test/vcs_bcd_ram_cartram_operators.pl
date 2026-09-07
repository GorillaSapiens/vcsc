#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: BCD RAM/cartram operator matrix passed
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

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $source=File::Spec->catfile($repo,'test','fixtures','vcs_bcd_ram_cartram_operators.c26');
my $bin=File::Spec->catfile($tmp,'bcd-ram-cartram.bin');
my $map=File::Spec->catfile($tmp,'bcd-ram-cartram.map');

my $src=read_file($source);
for my $type (qw(bcd8_t bcd16_t bcd24_t bcd32_t)) {
   $src =~ /^\Q$type\E\s+ram\d+/m or die "matrix missing ordinary-RAM $type operand\n";
   $src =~ /^cartram\s+\Q$type\E\s+cart\d+/m or die "matrix missing cartram $type operand\n";
}
for my $name (qw(ram8 ram16 ram24 ram32 cart8 cart16 cart24 cart32)) {
   $src =~ /\b\Q$name\E\s*\+=/ or die "matrix missing $name +=\n";
   $src =~ /\b\Q$name\E\s*-=/ or die "matrix missing $name -=\n";
   $src =~ /\b\Q$name\E\s*\+\+/ or die "matrix missing $name postfix ++\n";
   $src =~ /\+\+\s*\Q$name\E\b/ or die "matrix missing $name prefix ++\n";
   $src =~ /\b\Q$name\E\s*--/ or die "matrix missing $name postfix --\n";
   $src =~ /--\s*\Q$name\E\b/ or die "matrix missing $name prefix --\n";
}

require_ok('build BCD RAM/cartram operator matrix',$driver,'-I',$vcs,'-Map',$map,$source,'-o',$bin);
-s $bin==32768 or die "BCD RAM/cartram matrix output is not 32768 bytes\n";
my $m=read_file($map);
$m =~ /^\s*cartram\s+read_start=\$F080 write_start=\$F000 size=\$0080 type=rw shared=yes\b/m
   or die "BCD matrix lost F4SC split-address cartram\n$m";
for my $name (qw(cart8 cart16 cart24 cart32)) {
   $m =~ /(?:BSS|DATA)\.cartram\.__vcsc_object\$\Q$name\E\b.*\bsplit=yes\b/m
      or die "BCD matrix $name is not actually allocated in split cartram\n$m";
}
for my $name (qw(ram8 ram16 ram24 ram32)) {
   $m =~ /(?:BSS|DATA)\.__vcsc_object\$\Q$name\E\b/m
      or die "BCD matrix $name is not actually allocated in ordinary RAM\n$m";
}

my $done=map_symbol($m,'simulator_done');
my $failure=map_symbol($m,'failure');
my($out,$err)=require_ok('simulate BCD RAM/cartram operator matrix',$sim,'--map',$map,
   '--split-fill=0xA7',sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$bin);
$err eq '' or die "BCD RAM/cartram simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($out);
$mem->[$failure]==0
   or die sprintf("BCD RAM/cartram operator matrix failed at check %u\n",$mem->[$failure]);

print "BCD RAM/cartram operator matrix passed\n";
