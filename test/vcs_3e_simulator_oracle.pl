#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 3E simulator hardware oracle passed
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

write_file($profile, <<'C26');
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)
C26

# Hardware-oracle success case: every possible selector value owns independent
# 1K RAM.  Write each bank's selector value through the write alias, leave RAM
# mode through $3F, then reselect every bank and verify the byte through the
# read alias.  Any selector truncation or lost bank contents fails the loop.
my $main=File::Spec->catfile($tmp,'oracle.s26');
my $bin=File::Spec->catfile($tmp,'oracle.bin');
my $map=File::Spec->catfile($tmp,'oracle.map');
my $sym=File::Spec->catfile($tmp,'oracle.sym');
write_file($main, <<'ASM');
.export main, simulator_done, failure, observed

.segment "ZEROPAGE"
failure:  .res 1
observed: .res 1

.segment "CODE.bank3"
main:
    lda #0
    sta failure

    ; Fill all 256 physical RAM banks.  X is the exact $3E selector value.
    ldx #0
write_all:
    stx $3e
    txa
    sta $1400
    inx
    bne write_all

    ; Explicitly leave RAM mode.  The following re-selections must preserve
    ; every bank's previous contents.
    lda #0
    sta $3f

    ldx #0
read_all:
    stx $3e
    lda $1000
    sta observed
    txa
    cmp observed
    bne fail
    inx
    bne read_all
    jmp simulator_done

fail:
    lda #1
    sta failure
simulator_done:
    jmp simulator_done
ASM

require_ok('build 3E selector/persistence oracle',$driver,'-I',$vcs,
   '-Map',$map,'-Sym',$sym,'-o',$bin,$profile,$main);
-s $bin==8192 or die "3E selector oracle output is not 8K\n";
my $symbols=read_file($sym);
my $done=parse_symbol($symbols,'simulator_done');
my $failure=parse_symbol($symbols,'failure');
my($dump,$simerr)=require_ok('simulate all 256 3E RAM selectors',$sim,'--map='.$map,
   sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$bin);
$simerr eq '' or die "3E selector oracle wrote stderr:\n$simerr";
my $mem=parse_hex_dump($dump);
$mem->[$failure]==0
   or die sprintf("3E selector/persistence oracle failed: failure=$%02X\n",$mem->[$failure]);

sub expect_alias_failure {
   my($name,$body,$expect)=@_;
   my $source=File::Spec->catfile($tmp,"$name.s26");
   my $image=File::Spec->catfile($tmp,"$name.bin");
   my $map_path=File::Spec->catfile($tmp,"$name.map");
   write_file($source, qq{.export main\n.segment "CODE.bank3"\nmain:\n$body\nforever:\n    jmp forever\n});
   require_ok("build $name alias fault",$driver,'-I',$vcs,'-Map',$map_path,
      '-o',$image,$profile,$source);
   my($rc,$sig,$out,$err)=run_capture($sim,'--map='.$map_path,$image);
   !$sig && $rc==1
      or die "$name alias fault returned rc=$rc sig=$sig\nstdout:\n$out\nstderr:\n$err";
   $err =~ /\Q$expect\E/
      or die "$name alias fault did not report '$expect'\nstderr:\n$err";
}

my $bad_read = <<'ASM';
    lda #$ff
    sta $3e
    lda $1400
ASM
expect_alias_failure('bad_read_alias', $bad_read,
    'vcsc-sim: read from 3E RAM write alias at $1400');

my $bad_write = <<'ASM';
    lda #$ff
    sta $3e
    lda #$5a
    sta $1000
ASM
expect_alias_failure('bad_write_alias', $bad_write,
    'vcsc-sim: write to 3E RAM read alias at $1000');

print "3E simulator hardware oracle passed\n";
