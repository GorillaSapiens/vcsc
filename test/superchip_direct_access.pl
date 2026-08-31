#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: Superchip direct-access compiler contract passed for 4KSC
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
sub write_file {
   my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n";
   print {$fh} $d or die "write $p: $!\n"; close($fh) or die "close $p: $!\n";
}
sub parse_symbol {
   my($sym,$name)=@_; $sym =~ /^\Q$name\E\s+([0-9A-Fa-f]{4})\s*$/m
      or die "symbol file is missing $name\n"; return hex($1);
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
sub require_resolved_operand {
   my($label,$lst,$op,$expr,$want)=@_;
   $lst =~ /;\s+\Q$op\E\s+\Q$expr\E\s+=>\s*\$([0-9A-Fa-f]{4})/i
      or die "$label is missing from the final linked listing\n";
   my $got=hex($1);
   $got==$want
      or die sprintf("%s resolves to $%04X, expected $%04X\n",$label,$got,$want);
}
sub require_pointer_expr {
   my($label,$lst,$expr,$want)=@_;
   my @low;
   my @high;
   for my $line (split /\n/,$lst) {
      if ($line =~ /^\s*\d+\s+[0-9A-Fa-f]{4}\s+a9\s+([0-9A-Fa-f]{2})\b[^;]*;\s+LDA #\(<\Q$expr\E\)/i) {
         push @low,hex($1);
      }
      if ($line =~ /^\s*\d+\s+[0-9A-Fa-f]{4}\s+a9\s+([0-9A-Fa-f]{2})\b[^;]*;\s+LDA #\(>\Q$expr\E\)/i) {
         push @high,hex($1);
      }
   }
   @low && @low==@high
      or die "$label does not have matched final low/high pointer loads\n";
   for my $i (0..$#low) {
      my $got=$low[$i] | ($high[$i] << 8);
      $got==$want
         or die sprintf("%s pointer %d resolves to $%04X, expected $%04X\n",$label,$i,$got,$want);
   }
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $cfg=File::Spec->catfile($vcs,'4KSC/mapper.cfg');

# First use one ordinary C26 array to occupy all 128 physical SC bytes. This
# catches bad base aliases, bad runtime indexing, boundary errors, adjacent-byte
# corruption, and startup BSS clearing without relying on handwritten assembly.
my $arena_source=File::Spec->catfile($tmp,'superchip_arena.c26');
my $arena_bin=File::Spec->catfile($tmp,'superchip_arena.bin');
my $arena_map_path=File::Spec->catfile($tmp,'superchip_arena.map');
my $arena_sym_path=File::Spec->catfile($tmp,'superchip_arena.sym');
write_file($arena_source, <<'C26');
include "4KSC/mapper.c26"

cartram uint8_t sc[128];
uint8_t failure;
uint8_t i;
uint8_t value;

void simulator_done(void) { while (true) { } }

void main(void) {
   i := 0;
   while (i != 128) {
      if (sc[i] != 0) { failure := 0x01; }
      i := i + 1;
   }

   i := 0;
   while (i != 128) {
      sc[i] := i + 1;
      i := i + 1;
   }
   i := 0;
   while (i != 128) {
      if (sc[i] != i + 1) { failure := 0x02; }
      i := i + 1;
   }

   sc[0] := 0x11;
   sc[1] := 0x22;
   sc[2] := 0x33;
   sc[3] := 0x44;
   sc[4] := 0x55;
   sc[5] := 0x66;
   i := 3;
   value := sc[i];
   if (value != 0x44) { failure := 0x03; }
   sc[i] := 0xA5;
   if (sc[0] != 0x11 || sc[1] != 0x22 || sc[2] != 0x33 ||
       sc[3] != 0xA5 || sc[4] != 0x55 || sc[5] != 0x66) {
      failure := 0x04;
   }

   i := 64;
   sc[i] += 1;
   if (sc[i] != 66) { failure := 0x05; }

   sc[0] := 0xC1;
   sc[64] := 0xC2;
   sc[127] := 0xC3;
   if (sc[0] != 0xC1 || sc[64] != 0xC2 || sc[127] != 0xC3 ||
       sc[63] != 64 || sc[65] != 66 || sc[126] != 127) {
      failure := 0x06;
   }
   simulator_done();
}
C26
require_ok('build exhaustive 4KSC arena', $driver,'-I',$vcs,'-T',$generic,
   '-Map',$arena_map_path,'-Sym',$arena_sym_path,$arena_source,'-o',$arena_bin);
-s $arena_bin==4096 or die "4KSC arena output is not 4096 bytes\n";
my $arena_map=read_file($arena_map_path);
$arena_map =~ /^\s*cartram\s+used=128 bytes \(100\.00%\).*free=0 bytes/m
   or die "4KSC arena does not occupy all 128 Superchip bytes\n$arena_map";
$arena_map =~ /^\s*BSS\.cartram\.__vcsc_object\$sc run=\$F080 write=\$F000 size=\$0080\b/m
   or die "4KSC arena is not exactly mapped across the split SC window\n$arena_map";
$arena_map =~ /^\s*ZERO\s+BSS\.cartram\.__vcsc_object\$sc\s+read=\$F080 write=\$F000 size=\$0080 split=yes/m
   or die "4KSC arena startup does not zero through the write alias\n$arena_map";
my $arena_sym=read_file($arena_sym_path);
my $arena_done=parse_symbol($arena_sym,'simulator_done');
my $arena_failure=parse_symbol($arena_sym,'failure');
my($arena_dump,$arena_err)=require_ok('simulate exhaustive 4KSC arena',$sim,'-T',$cfg,
   '--split-fill=0xA7',sprintf('--reset-on-pc=0x%04X',$arena_done),
   sprintf('--stop-pc=0x%04X',$arena_done),'--dump-on-stop',$arena_bin);
$arena_err eq '' or die "4KSC arena simulator wrote stderr:\n$arena_err";
my $arena_mem=parse_hex_dump($arena_dump);
$arena_mem->[$arena_failure]==0
   or die sprintf("4KSC arena self-test failed: failure=$%02X\n",$arena_mem->[$arena_failure]);
for my $offset (0..127) {
   my $want=($offset+1)&0xff;
   $want=0xC1 if $offset==0;
   $want=0x22 if $offset==1;
   $want=0x33 if $offset==2;
   $want=0xA5 if $offset==3;
   $want=0x55 if $offset==4;
   $want=0x66 if $offset==5;
   $want=0xC2 if $offset==64;
   $want=0xC3 if $offset==127;
   for my $base (0xF000,0xF080) {
      my $got=$arena_mem->[$base+$offset];
      $got==$want or die sprintf("SC byte %d via $%04X is $%02X, expected $%02X\n",
                                 $offset,$base+$offset,$got,$want);
   }
}

# Then use separate scalar/array/DATA/BSS objects so the linked listing can lock
# the compiler's exact direct and runtime-index lowering independently of the
# exhaustive physical-byte sweep above.
my $access_source=File::Spec->catfile($tmp,'superchip_access.c26');
my $access_bin=File::Spec->catfile($tmp,'superchip_access.bin');
my $access_map_path=File::Spec->catfile($tmp,'superchip_access.map');
my $access_sym_path=File::Spec->catfile($tmp,'superchip_access.sym');
write_file($access_source, <<'C26');
include "4KSC/mapper.c26"

cartram uint8_t scalar;
cartram uint8_t src[8];
cartram uint8_t dst[8];
cartram uint8_t init[6] := { 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
cartram uint8_t zeros[6];
uint8_t failure;
uint8_t i;
uint8_t x;

void simulator_done(void) { while (true) { } }

void main(void) {
   if (init[0] != 0x11 || init[1] != 0x22 || init[2] != 0x33 ||
       init[3] != 0x44 || init[4] != 0x55 || init[5] != 0x66) {
      failure := 0x11;
   }
   i := 0;
   while (i != 6) {
      if (zeros[i] != 0) { failure := 0x12; }
      i := i + 1;
   }

   scalar := 0x5A;
   x := scalar;
   if (x != 0x5A) { failure := 0x13; }
   src[3] := 0x44;
   x := src[3];
   if (x != 0x44) { failure := 0x14; }

   i := 2;
   x := 0x77;
   src[i] := x;
   x := src[i];
   if (x != 0x77) { failure := 0x15; }
   dst[i] := src[i];
   if (dst[i] != 0x77) { failure := 0x16; }
   dst[i] += 1;
   if (dst[i] != 0x78 || src[i] != 0x77 || src[1] != 0 || src[3] != 0x44 ||
       dst[1] != 0 || dst[3] != 0) {
      failure := 0x17;
   }
   simulator_done();
}
C26
require_ok('build 4KSC access-pattern test',$driver,'-I',$vcs,'-T',$generic,
   '-Map',$access_map_path,'-Sym',$access_sym_path,$access_source,'-o',$access_bin);
-s $access_bin==4096 or die "4KSC access-pattern output is not 4096 bytes\n";
my $access_map=read_file($access_map_path);
my $access_sym=read_file($access_sym_path);
my %addr=map { $_=>parse_symbol($access_sym,$_) } qw(scalar src dst init zeros simulator_done failure);
for my $name (qw(scalar src dst init zeros)) {
   $addr{$name}>=0xF080 && $addr{$name}<=0xF0FF
      or die sprintf("%s read symbol is outside SC read window: $%04X\n",$name,$addr{$name});
}
$access_map =~ /^\s*COPY\s+DATA\.cartram\.__vcsc_object\$init\s+load=\$[0-9A-Fa-f]{4} read=\$([0-9A-Fa-f]{4}) write=\$([0-9A-Fa-f]{4}) size=\$0006 split=yes/m
   or die "initialized Superchip DATA is missing its split startup copy\n$access_map";
hex($1)==$addr{init} && hex($2)==$addr{init}-0x80
   or die "initialized Superchip DATA copy uses the wrong aliases\n$access_map";
for my $name (qw(scalar src dst zeros)) {
   $access_map =~ /^\s*ZERO\s+BSS\.cartram\.__vcsc_object\$\Q$name\E\s+read=\$([0-9A-Fa-f]{4}) write=\$([0-9A-Fa-f]{4}) size=\$[0-9A-Fa-f]{4} split=yes/m
      or die "Superchip BSS object $name is missing its split startup zero\n$access_map";
   hex($1)==$addr{$name} && hex($2)==$addr{$name}-0x80
      or die "Superchip BSS object $name uses the wrong startup aliases\n$access_map";
}

my $lst=read_file(File::Spec->catfile($tmp,'superchip_access.lst'));
require_resolved_operand('constant scalar store',$lst,'STA','(scalar - 128)',$addr{scalar}-0x80);
require_resolved_operand('constant scalar load',$lst,'LDA','scalar',$addr{scalar});
require_resolved_operand('constant-index store',$lst,'STA','((src - 128) + 3)',$addr{src}+3-0x80);
require_resolved_operand('constant-index load',$lst,'LDA','(src + 3)',$addr{src}+3);
require_pointer_expr('runtime-index src write base',$lst,'((src - 128) + 0)',$addr{src}-0x80);
require_pointer_expr('runtime-index src read base',$lst,'(src + 0)',$addr{src});
require_pointer_expr('runtime-index dst write base',$lst,'((dst - 128) + 0)',$addr{dst}-0x80);
require_pointer_expr('runtime-index dst read base',$lst,'(dst + 0)',$addr{dst});

my($access_dump,$access_err)=require_ok('simulate 4KSC access-pattern test',$sim,'-T',$cfg,
   '--split-fill=0xA7',sprintf('--reset-on-pc=0x%04X',$addr{simulator_done}),
   sprintf('--stop-pc=0x%04X',$addr{simulator_done}),'--dump-on-stop',$access_bin);
$access_err eq '' or die "4KSC access-pattern simulator wrote stderr:\n$access_err";
my $access_mem=parse_hex_dump($access_dump);
$access_mem->[$addr{failure}]==0
   or die sprintf("4KSC access-pattern self-test failed: failure=$%02X\n",$access_mem->[$addr{failure}]);
my @init=(0x11,0x22,0x33,0x44,0x55,0x66);
for my $i (0..5) {
   $access_mem->[$addr{init}+$i]==$init[$i]
      or die sprintf("initialized SC DATA byte %d is $%02X, expected $%02X\n",$i,$access_mem->[$addr{init}+$i],$init[$i]);
   $access_mem->[$addr{zeros}+$i]==0
      or die sprintf("zeroed SC BSS byte %d is $%02X, expected \$00\n",$i,$access_mem->[$addr{zeros}+$i]);
}
$access_mem->[$addr{scalar}]==0x5A or die "SC scalar execution value is wrong\n";
$access_mem->[$addr{src}+1]==0 && $access_mem->[$addr{src}+2]==0x77 && $access_mem->[$addr{src}+3]==0x44
   or die "SC source array or neighboring bytes are wrong after runtime indexing\n";
$access_mem->[$addr{dst}+1]==0 && $access_mem->[$addr{dst}+2]==0x78 && $access_mem->[$addr{dst}+3]==0
   or die "SC destination array or neighboring bytes are wrong after copy/RMW\n";

print "Superchip direct-access compiler contract passed for 4KSC\n";
