#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: inline bank-call page crossings passed
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
   my($path,$text)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $text or die "write $path: $!\n"; close($fh) or die "close $path: $!\n";
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n"; local $/;
   my $text=<$fh>; close($fh); return $text // '';
}
sub map_symbol {
   my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map is missing $name\n"; return hex($1);
}
sub parse_dump {
   my($text)=@_; my @mem=(0) x 65536;
   for my $line (split /\n/,$text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($n,$a,$data)=(hex($1),hex($2),$3);
      length($data)==$n*2 or die "bad Intel HEX dump record\n";
      for my $i (0..$n-1) { $mem[$a+$i]=hex(substr($data,$i*2,2)); }
   }
   return \@mem;
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "could not resolve tmp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $simcfg=File::Spec->catfile($vcs,'vcs_8k_f8.cfg');

for my $case (
   [word_cross=>0xD0FC, 'inline target word straddles page boundary'],
   [jsr_end=>0xD0FD, 'JSR ends at page boundary and inline word starts next page'],
) {
   my($name,$edge_start,$why)=@$case;
   my $src=File::Spec->catfile($tmp,"$name.c26");
   my $asm=File::Spec->catfile($tmp,"$name.s26");
   my $map_path=File::Spec->catfile($tmp,"$name.map");
   my $bin=File::Spec->catfile($tmp,"$name.bin");
   my $edge_end=$edge_start+0x20;
   my $source=sprintf <<'SRC', $edge_start;
include "vcs.c26"
cartridge {
   $fill:0xff $signature:F8
   $trampoline_offset:0x0f00 $trampoline_size:0x00e0
   $vector_bridge_offset:0x0fe0 $vector_bridge_size:0x0012
   $vectors_offset:0x0ffa $vectors_size:0x0006
};
bank bank0 {
   $image_size:0x1000 $file_index:1 $image_offset:0x0000
   $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000
   $select_access:0x1ff9 $startup
};
bank bank1 {
   $image_size:0x1000 $file_index:0 $image_offset:0x0000
   $link_start:0xd000 $cpu_start:0xf000 $map_size:0x1000
   $select_access:0x1ff8
};
mem bank0 { $start:0xf000 $size:0x0f00 $ro $priority:2 };
mem edge { $start:0x%04x $size:0x0020 $ro $priority:3 };
uint8_t a_after;
uint8_t x_after;
uint8_t done;
bank0 void target(void) {
   asm lda #$5a;
   asm ldx #$a5;
}
edge void crossing(void) {
   target();
   asm sta a_after;
   asm stx x_after;
   done := 1;
}
bank0 void invoke_edge(void) { crossing(); }
void stop(void) { while (1) { } }
void main(void) {
   a_after := 0;
   x_after := 0;
   done := 0;
   invoke_edge();
   asm jmp stop;
}
SRC
   write_file($src,$source);
   require_ok("compile assembly $name",$driver,'-S','-I',$vcs,'-o',$asm,$src);
   my $assembly=read_file($asm);
   $assembly =~ /\.proc\s+crossing\s+jsr\s+target\s+\.banktarget\s+target/s
      or die "$name does not emit the five-byte inline-target call bundle\n";

   require_ok("link $name",$driver,'-I',$vcs,'-T',File::Spec->catfile($vcs,'vcs.cfg'),
              '-Map',$map_path,$src,'-o',$bin);
   -s $bin==8192 or die "$name did not emit exact 8K F8 image\n";
   my $map=read_file($map_path);
   my $crossing=map_symbol($map,'crossing');
   $crossing==$edge_start
      or die sprintf("%s call fixture moved from %04X to %04X (%s)\n",$name,$edge_start,$crossing,$why);
   $map =~ /^\s*common-offset=\$F00\s+reserved=\$0E0\s+used=\$050\b.*\bgeneric-jsr=\$050\b.*\bentries=0\s+jmp=0\s+jsr=0\b/m
      or die "$name did not use only the fixed generic bank-call block\n$map";
   my $stop=map_symbol($map,'stop');
   my $a=map_symbol($map,'a_after');
   my $x=map_symbol($map,'x_after');
   my $done=map_symbol($map,'done');

   for my $start_bank (0,1) {
      my($out,$err)=require_ok("simulate $name from bank $start_bank",$sim,'-T',$simcfg,
         "--start-bank=$start_bank",sprintf('--stop-pc=0x%04X',$stop),'--dump-on-stop',$bin);
      $err eq '' or die "$name simulator wrote stderr:\n$err";
      my $mem=parse_dump($out);
      $mem->[$a]==0x5A && $mem->[$x]==0xA5 && $mem->[$done]==1
         or die sprintf("%s failed after page-crossing call from start bank %d: A=%02X X=%02X done=%02X\n",
                        $name,$start_bank,$mem->[$a],$mem->[$x],$mem->[$done]);
   }
}

print "inline bank-call page crossings passed\n";
