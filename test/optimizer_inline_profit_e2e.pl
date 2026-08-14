#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: Optimizer inline profit E2E passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);
sub slurp_fh{my($f)=@_;local$/;return<$f>//''}
sub run_capture{my(@c)=@_;my$e=gensym;my$p=open3(my$i,my$o,$e,@c);close$i;my$so=slurp_fh($o);my$se=slurp_fh($e);waitpid($p,0);return($?>>8,$?&127,$so,$se)}
sub okrun{my($n,@c)=@_;my($r,$s,$o,$e)=run_capture(@c);$r==0&&!$s or die "$n failed rc=$r sig=$s\n@c\n$o$e";return($o,$e)}
sub write_file{my($p,$t)=@_;open my$f,'>:raw',$p or die "write $p: $!";print{$f}$t;close$f}
sub read_file{my($p)=@_;open my$f,'<:raw',$p or die "read $p: $!";local$/;return<$f>//''}
sub metrics{my($m)=@_;my($rom,$obj,$stack)=(0,0,0);$m =~ /MEMORY USAGE\n(.*?)(?:\n\n|\z)/s or die "no usage\n$m";for(split/\n/,$1){if(/objects=(\d+) bytes hardware-stack=(\d+) bytes/){$obj+=$1;$stack+=$2}elsif(/used=(\d+) bytes/){$rom+=$1}}return($rom,$obj,$stack)}
sub symaddr{my($s,$n)=@_;$s =~ /^\Q$n\E\s+([0-9A-Fa-f]{4})\s*$/m or die "missing $n\n$s";return hex$1}
sub parse_dump{my($t)=@_;my@m=(0)x65536;for(split/\n/,$t){next unless /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;my($n,$a,$b)=(hex$1,hex$2,$3);for my$i(0..$n-1){$m[$a+$i]=hex substr($b,$i*2,2)}}return\@m}

my($repo,$tmp)=@ARGV;die "usage\n" unless defined$tmp;
my$driver=File::Spec->catfile($repo,qw(driver vcsc));my$sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));my$inc=File::Spec->catdir($repo,'test');
my$cfg=File::Spec->catfile($tmp,'profit.cfg');my$src=File::Spec->catfile($tmp,'profit.c26');
write_file($cfg,<<'CFG');
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw,define=yes;
 CPUSTACK: start=$0100,size=$0100,type=rw,define=yes;
 RAM: start=$0200,size=$1E00,type=rw,define=yes,callstack=callgraph;
 ROM: start=$8000,size=$8000,type=ro,define=yes;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp,define=yes;
 CODE: load=ROM,type=ro,define=yes;
 RODATA: load=ROM,type=ro,define=yes;
 BSS: load=RAM,type=bss,define=yes;
 DATA: load=ROM,run=RAM,type=data,define=yes;
}
CFG
write_file($src,<<'SRC');
include "machine_6502.c26"
mem rom { $start:0x8000 $size:0x8000 $ro $priority:1 };
uint8_t result;
uint8_t loss_result;
uint8_t selector;
static uint8_t leaf(uint8_t x) { return x + 1; }
static uint8_t middle(uint8_t x) { return leaf(x) + 2; }
static uint8_t loss(uint8_t x) {
   if (x == 0) { return 10; }
   if (x == 1) { return 11; }
   if (x == 2) { return 12; }
   if (x == 3) { return 13; }
   if (x == 4) { return 14; }
   return 15;
}
void done(void) { while (1) {} }
void main(void) { result := middle(4); loss_result := loss(selector); asm jmp done; }
SRC
sub build{my($tag,$profit)=@_;my$hex=File::Spec->catfile($tmp,"$tag.hex");my$map=File::Spec->catfile($tmp,"$tag.map");my$sym=File::Spec->catfile($tmp,"$tag.sym");my@c=($driver,'-I',$inc,'-DMACHINE_6502_NO_DEFAULT_ROM','-T',$cfg,'-Map',$map,'-Sym',$sym);push@c,('-finline-profit','-v') if $profit;push@c,$src,'-o',$hex;my($buildout,$builderr)=okrun("build $tag",@c);my$mt=read_file($map);my$st=read_file($sym);my$done=symaddr($st,'done');my$res=symaddr($st,'result');my$loss=symaddr($st,'loss_result');my($dump,$err)=okrun("sim $tag",$sim,'-T',$cfg,sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$hex);$err eq '' or die $err;my$mem=parse_dump($dump);$mem->[$res]==7 or die "$tag result=$mem->[$res]\n";$mem->[$loss]==10 or die "$tag loss_result=$mem->[$loss]\n";return($mt,$buildout.$builderr)}
my($n)=build('normal',0);my($o,$diag)=build('optimized',1);my($nr,$no,$ns)=metrics($n);my($or,$oo,$os)=metrics($o);
$diag =~ /inline\s+leaf:\s+accept-rom\b/ or die "leaf was not accepted by measured profitability\n$diag";
$diag =~ /inline\s+middle:\s+accept-rom\b/ or die "middle was not accepted by measured profitability\n$diag";
$diag =~ /inline\s+loss:\s+reject\s+rom=(\d+)->(\d+)/ or die "missing measured ROM-loss rejection\n$diag";
$2 > $1 or die "loss rejection did not measure ROM growth: $1->$2\n";
$n =~ /CODE\.__vcsc_function\$leaf\b/ && $n =~ /CODE\.__vcsc_function\$middle\b/ &&
   $n =~ /CODE\.__vcsc_function\$loss\b/ or die "normal functions missing\n$n";
$o !~ /CODE\.__vcsc_function\$(?:leaf|middle)\b/ or die "profitable functions retained\n$o";
$o =~ /CODE\.__vcsc_function\$loss\b/ or die "measured ROM-loss candidate was not rejected\n$o";
$or==$nr-8 or die "expected exact 8-byte nested ROM win, got $nr->$or\n";
$oo==$no or die "activation/object RAM changed $no->$oo\n";
$os<$ns or die "hardware stack did not shrink $ns->$os\n";
print "Optimizer inline profit E2E passed\n";
