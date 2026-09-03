#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 3E swapram fixed-bank helpers passed
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

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $profile=File::Spec->catfile($tmp,'profile.c26');
my $main=File::Spec->catfile($tmp,'main.s26');
my $bin=File::Spec->catfile($tmp,'swapram_helpers.bin');
my $map_path=File::Spec->catfile($tmp,'swapram_helpers.map');
my $sym_path=File::Spec->catfile($tmp,'swapram_helpers.sym');

write_file($profile, <<'C26');
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)
C26

write_file($main, <<'ASM');
.include "vcsc-runtime.inc"
.importzp _vcsc_arg0, _vcsc_ptr1, _vcsc_ptr2
.import swapram_read1, swapram_read2, swapram_read3, swapram_read4
.import swapram_write1, swapram_write2, swapram_write3, swapram_write4
.export main, simulator_done, failure

.segment "ZEROPAGE"
failure: .res 1
src: .res 4
dst: .res 4

.segment "CODE.bank3"
main:
    lda #0
    sta failure
    lda #$11
    sta src
    lda #$22
    sta src+1
    lda #$33
    sta src+2
    lda #$44
    sta src+3

    ; width 1, bank 0, offset $003
    lda #$03
    sta ptr1
    lda #$00
    sta ptr1+1
    sta arg0
    lda #<src
    sta ptr2
    lda #>src
    sta ptr2+1
    jsr swapram_write1
    lda #0
    sta dst
    lda #$03
    sta ptr1
    lda #$00
    sta ptr1+1
    sta arg0
    lda #<dst
    sta ptr2
    lda #>dst
    sta ptr2+1
    jsr swapram_read1
    lda dst
    cmp #$11
    bne fail1

    ; width 2, bank 31, offset $1FE => logical $07DFE
    lda #$FE
    sta ptr1
    lda #$7D
    sta ptr1+1
    lda #0
    sta arg0
    lda #<src
    sta ptr2
    lda #>src
    sta ptr2+1
    jsr swapram_write2
    lda #0
    sta dst
    sta dst+1
    lda #$FE
    sta ptr1
    lda #$7D
    sta ptr1+1
    lda #0
    sta arg0
    lda #<dst
    sta ptr2
    lda #>dst
    sta ptr2+1
    jsr swapram_read2
    lda dst
    cmp #$11
    bne fail2
    lda dst+1
    cmp #$22
    bne fail2

    ; width 3, bank 32, offset $2FD => logical $082FD
    lda #$FD
    sta ptr1
    lda #$82
    sta ptr1+1
    lda #0
    sta arg0
    lda #<src
    sta ptr2
    lda #>src
    sta ptr2+1
    jsr swapram_write3
    lda #0
    sta dst
    sta dst+1
    sta dst+2
    lda #$FD
    sta ptr1
    lda #$82
    sta ptr1+1
    lda #0
    sta arg0
    lda #<dst
    sta ptr2
    lda #>dst
    sta ptr2+1
    jsr swapram_read3
    lda dst
    cmp #$11
    bne fail3
    lda dst+1
    cmp #$22
    bne fail3
    lda dst+2
    cmp #$33
    bne fail3

    ; width 4, bank 255, offset $3FC => logical $3FFFC
    lda #$FC
    sta ptr1
    lda #$FF
    sta ptr1+1
    lda #3
    sta arg0
    lda #<src
    sta ptr2
    lda #>src
    sta ptr2+1
    jsr swapram_write4
    lda #0
    sta dst
    sta dst+1
    sta dst+2
    sta dst+3
    lda #$FC
    sta ptr1
    lda #$FF
    sta ptr1+1
    lda #3
    sta arg0
    lda #<dst
    sta ptr2
    lda #>dst
    sta ptr2+1
    jsr swapram_read4
    lda dst
    cmp #$11
    bne fail4
    lda dst+1
    cmp #$22
    bne fail4
    lda dst+2
    cmp #$33
    bne fail4
    lda dst+3
    cmp #$44
    bne fail4
    jmp simulator_done

fail1:
    lda #1
    bne store_failure
fail2:
    lda #2
    bne store_failure
fail3:
    lda #3
    bne store_failure
fail4:
    lda #4
store_failure:
    sta failure
simulator_done:
    jmp simulator_done
ASM

require_ok('build direct fixed-bank swapram helper fixture', $driver, '-I', $vcs,
   '-Map', $map_path, '-Sym', $sym_path, '-o', $bin, $profile, $main);
-s $bin==8192 or die "3E helper fixture output is not 8K\n";

my $map=read_file($map_path);
$map =~ /^\s*pinned\s+STARTUP\s+region=bank3\s+size=\$[0-9A-Fa-f]{4}\s+object=.*3e_swapram.*\.o26$/m
   or die "3E swapram helper block is not wholly pinned to startup bank3\n$map";
for my $name (qw(swapram_read1 swapram_read2 swapram_read3 swapram_read4
                 swapram_write1 swapram_write2 swapram_write3 swapram_write4
                 swapram_zero)) {
   $map =~ /^\s+\$([0-9A-Fa-f]{4})\s+\Q$name\E\s+.*3e_swapram.*\.o26$/m
      or die "map is missing auto-linked $name\n$map";
   my $addr=hex($1);
   $addr>=0x1800 && $addr<=0x1FFF
      or die sprintf("%s landed outside fixed/startup ROM at $%04X\n",$name,$addr);
}

my $sym=read_file($sym_path);
my $done=parse_symbol($sym,'simulator_done');
my $failure=parse_symbol($sym,'failure');
my($dump,$simerr)=require_ok('simulate direct fixed-bank swapram helpers', $sim,
   '--map='.$map_path, sprintf('--stop-pc=0x%04X',$done), '--dump-on-stop', $bin);
$simerr eq '' or die "3E helper simulator wrote stderr:\n$simerr";
my $mem=parse_hex_dump($dump);
$mem->[$failure]==0
   or die sprintf("3E swapram helper self-test failed: failure=$%02X\n",$mem->[$failure]);

print "3E swapram fixed-bank helpers passed\n";
