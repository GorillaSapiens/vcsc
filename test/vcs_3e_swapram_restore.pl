#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 3E swapram restoration passed
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
sub write_file {
   my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n";
   print {$fh} $d or die "write $p: $!\n"; close($fh) or die "close $p: $!\n";
}
sub read_file {
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub map_symbol {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map missing symbol $name\n";
   return hex($1);
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

my $src=File::Spec->catfile($tmp,'restore.c26');
my $bin=File::Spec->catfile($tmp,'restore.bin');
my $map_path=File::Spec->catfile($tmp,'restore.map');
write_file($src,<<'SRC');
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=6)
uint8_t failure;
uint8_t calls;
swapram uint8_t slot;

bank0 uint8_t lower0(void) {
   slot := 0x10;
   if (slot != 0x10) { failure := 0x10; }
   calls := calls + 1;
   return 0x40;
}
bank1 uint8_t lower1(void) {
   slot := 0x21;
   if (slot != 0x21) { failure := 0x11; }
   calls := calls + 1;
   return 0x41;
}
bank2 uint8_t lower2(void) {
   slot := 0x32;
   if (slot != 0x32) { failure := 0x12; }
   calls := calls + 1;
   return 0x42;
}
bank3 uint8_t lower3(void) {
   calls := calls + 1;
   return 0x43;
}
bank4 uint8_t lower4(void) {
   slot := 0x54;
   if (slot != 0x54) { failure := 0x14; }
   calls := calls + 1;
   return 0x44;
}

bank5 void fixed_ram_then_lower(void) {
   slot := 0x5a;

   // slot is the only swapram object, so its helper selects RAM bank 0 offset 0.
   // A fixed-bank helper deliberately leaves that RAM bank mapped on return.
   asm lda $1000;
   asm cmp #$5a;
   asm beq @ram_still_selected;
   failure := 0x20;
   asm @ram_still_selected:;

   // This automatic fixed->lower call must replace the RAM window with ROM bank 3.
   if (lower3() != 0x43) { failure := 0x21; }
}

bank5 void simulator_done(void) { while (1) { } }
bank5 void main(void) {
   failure := 0;
   calls := 0;

   // Each lower function maps RAM through the fixed helper and must then resume
   // in its own lower ROM bank before it can validate, count, and return.
   if (lower0() != 0x40) { failure := 1; }
   if (lower1() != 0x41) { failure := 2; }
   if (lower2() != 0x42) { failure := 3; }
   if (lower4() != 0x44) { failure := 4; }

   fixed_ram_then_lower();
   if (calls != 5) { failure := 5; }
   asm jmp simulator_done;
}
SRC

require_ok('build 3E swapram restoration fixture',$driver,'-I',$vcs,
   '-Map',$map_path,'--no-list','--no-cfg','-o',$bin,$src);
-s $bin==6*2048 or die "3E restoration fixture output is not 12K\n";
my $map=read_file($map_path);

# The fixture intentionally gives every lower bank a same-address $1000 function.
# Physical bank identity, not CPU address alone, is what restoration must preserve.
for my $bank (0..4) {
   $map =~ /^\s*CODE\.bank\Q$bank\E\.__vcsc_function\$lower\Q$bank\E\s+load=\$1000\b.*bank=bank\Q$bank\E\s+region=bank\Q$bank\E\s+placement=pinned/m
      or die "lower$bank is not pinned at canonical \$1000 in physical bank $bank\n$map";
}
$map =~ /^\s*CODE\.bank5\.__vcsc_function\$fixed_ram_then_lower\s+load=\$[0-9A-Fa-f]{4}\b.*bank=bank5\s+region=bank5\s+placement=pinned/m
   or die "fixed restoration probe is not pinned to the fixed bank\n$map";
$map =~ /^\s*BSS\.swapram\.__vcsc_object\$slot\s+logical=\$00000\s+swapram-bank=0\s+swapram-offset=\$0000\s+size=\$0001\b/m
   or die "restoration fixture's sole swapram byte did not land at RAM bank 0 offset 0\n$map";
for my $name (qw(swapram_read1 swapram_write1)) {
   my $addr=map_symbol($map,$name);
   $addr>=0x1800 && $addr<=0x1fff
      or die sprintf("%s escaped fixed ROM at $%04X\n",$name,$addr);
}

my $done=map_symbol($map,'simulator_done');
my $failure=map_symbol($map,'failure');
my $calls=map_symbol($map,'calls');
my($dump,$err)=require_ok('simulate 3E swapram restoration',$sim,
   '--map='.$map_path,sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$bin);
$err eq '' or die "3E restoration simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($dump);
$mem->[$failure]==0
   or die sprintf("3E restoration self-test failed: failure=$%02X\n",$mem->[$failure]);
$mem->[$calls]==5
   or die sprintf("3E restoration self-test executed %u lower-bank continuations, expected 5\n",$mem->[$calls]);

print "3E swapram restoration passed\n";
