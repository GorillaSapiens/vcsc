#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: NMOS page-wrap hazards rejected
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

sub write_file { my ($p,$d)=@_; open(my $f,'>:raw',$p) or die "write $p: $!\n"; print {$f} $d; close($f) or die "close $p: $!\n"; }
sub run_capture { my (@c)=@_; my $e=gensym; my $pid=open3(my $in,my $out,$e,@c); close($in); local $/; my $o=<$out>//''; my $x=<$e>//''; waitpid($pid,0); return ($?>>8,$?&127,$o,$x); }
sub require_ok { my ($n,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x==0&&!$s or die "$n failed\n@c\n$o$e"; without_cartridge_usage($o) eq '' or die "$n stdout: $o"; $e eq '' or die "$n stderr: $e"; }
sub require_fail { my ($n,$re,@c)=@_; my ($x,$s,$o,$e)=run_capture(@c); $x!=0&&!$s or die "$n unexpectedly succeeded\n@c\n$o$e"; $e =~ $re or die "$n diagnostic mismatch\nexpected $re\ngot:\n$e"; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');
my $rt=File::Spec->catfile($repo,'libraries','runtime','libvcsc.l26');

my $literal=File::Spec->catfile($tmp,'literal.s26');
write_file($literal, ".segment \"CODE\"\nJMP (\$12FF)\n");
require_fail('literal indirect JMP wrap', qr/indirect JMP vector at \$12FF .*page-wrap bug/,
             $as,'-o',File::Spec->catfile($tmp,'literal.o26'),$literal);
my $flat_literal=File::Spec->catfile($tmp,'flat-literal.s26');
write_file($flat_literal, ".org \$2000\nJMP (\$12FF)\n");
require_fail('flat literal indirect JMP wrap', qr/indirect JMP vector at \$12FF .*page-wrap bug/,
             $as,'--hex='.File::Spec->catfile($tmp,'flat-literal.hex'),$flat_literal);

my $src=File::Spec->catfile($tmp,'reloc.s26');
write_file($src,<<'ASM');
.segment "CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
    LDA ($FF),Y       ; intentional zero-page operand wrap remains legal
    JMP (vector)
.endproc
.segment "VECTOR"
.export vector
vector:
    .word $1234
ASM
my $obj=File::Spec->catfile($tmp,'reloc.o26');
require_ok('assemble relocatable indirect JMP',$as,'-o',$obj,$src);

sub cfg_text {
   my ($vec_start)=@_;
   return sprintf <<'CFG', $vec_start;
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 VEC: start=$%04X,size=$0002,type=ro;
 ROM: start=$3000,size=$D000,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 VECTOR: load=VEC,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
}
my $safe_cfg=File::Spec->catfile($tmp,'safe.cfg');
write_file($safe_cfg,cfg_text(0x20FE));
require_ok('safe indirect JMP link',$ld,'-T',$safe_cfg,'-o',File::Spec->catfile($tmp,'safe.bin'),$obj,$rt);

# The assembler-relative address may itself end in $FF; object mode must defer
# the decision because final placement can move that symbol to a safe address.
my $packed_src=File::Spec->catfile($tmp,'packed-ff.s26');
write_file($packed_src,<<'ASM');
.segment "CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
    JMP (packed_vector)
.endproc
.segment "VECTOR"
.res 255
.export packed_vector
packed_vector:
    .word $1234
ASM
my $packed_obj=File::Spec->catfile($tmp,'packed-ff.o26');
require_ok('assemble packed-relative $FF vector',$as,'-o',$packed_obj,$packed_src);
my $packed_cfg=File::Spec->catfile($tmp,'packed-ff.cfg');
write_file($packed_cfg,<<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 VEC: start=$2001,size=$0101,type=ro;
 ROM: start=$3000,size=$D000,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 VECTOR: load=VEC,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
require_ok('relocate packed-relative $FF vector safely',$ld,'-T',$packed_cfg,
           '-o',File::Spec->catfile($tmp,'packed-ff.bin'),$packed_obj,$rt);

my $bad_cfg=File::Spec->catfile($tmp,'bad.cfg');
write_file($bad_cfg,cfg_text(0x20FF));
require_fail('relocated indirect JMP wrap', qr/indirect JMP vector at \$20FF .*page-wrap bug/,
             $ld,'-T',$bad_cfg,'-o',File::Spec->catfile($tmp,'bad.bin'),$obj,$rt);

my $zp_src=File::Spec->catfile($tmp,'zp.s26');
write_file($zp_src,<<'ASM');
.segment "CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
    rts
.endproc
.segment "ZEROPAGE.WRAP"
.exportzp ptr
ptr:
    .res 2
ASM
my $zp_obj=File::Spec->catfile($tmp,'zp.o26');
require_ok('assemble wrapping zero-page object',$as,'-o',$zp_obj,$zp_src);
my $zp_cfg=File::Spec->catfile($tmp,'zp.cfg');
write_file($zp_cfg,<<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 WRAP: start=$00FF,size=$0002,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$1E00,type=rw;
 ROM: start=$2000,size=$E000,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 ZEROPAGE.WRAP: load=ROM,run=WRAP,type=zp;
 CODE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
require_fail('zero-page object wrap', qr/zero-page object ZEROPAGE\.WRAP .*cannot cross \$00FF\/\$0000/,
             $ld,'-T',$zp_cfg,'-o',File::Spec->catfile($tmp,'zp.bin'),$zp_obj,$rt);

print "NMOS page-wrap hazards rejected\n";
