#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Optimizer inline reachability E2E passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($f)=@_; local$/; return <$f>//''; }
sub run_capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; my$so=slurp_fh($o); my$se=slurp_fh($e); waitpid($p,0); return($?>>8,$?&127,$so,$se); }
sub okrun { my($n,@c)=@_; my($r,$s,$o,$e)=run_capture(@c); $r==0&&!$s or die "$n failed rc=$r sig=$s\n@c\n$o$e"; return($o,$e); }
sub write_file { my($p,$t)=@_; open my$f,'>:raw',$p or die "write $p: $!"; print {$f} $t; close$f; }
sub read_file { my($p)=@_; open my$f,'<:raw',$p or die "read $p: $!"; local$/; return <$f>//''; }
sub symaddr { my($s,$n)=@_; $s =~ /^\Q$n\E\s+([0-9A-Fa-f]{4})\s*$/m or die "missing $n\n$s"; return hex$1; }
sub parse_dump { my($t)=@_; my@m=(0)x65536; for(split/\n/,$t){ next unless /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/; my($n,$a,$b)=(hex$1,hex$2,$3); for my$i(0..$n-1){$m[$a+$i]=hex substr($b,$i*2,2)} } return\@m; }

my($repo,$tmp)=@ARGV; die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my$driver=File::Spec->catfile($repo,qw(driver vcsc));
my$sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));
my$inc=File::Spec->catdir($repo,'test');
my$cfg=File::Spec->catfile($tmp,'reach.cfg');
my$src=File::Spec->catfile($tmp,'reach.c26');

write_file($cfg, <<'CFG');
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

write_file($src, <<'SRC');
include "machine_6502.c26"
mem rom { $start:0x8000 $size:0x8000 $ro $priority:1 };
uint8_t result;
uint8_t dead_sink;
uint8_t seed := 2;
static uint8_t init_helper(uint8_t x) { return x + 5; }
uint8_t initialized := init_helper(seed);
static uint8_t live(uint8_t x) { return x + 3; }
static void branch_dead(void) { dead_sink := 0x55; }
static void gate(const uint8_t enabled) { if (enabled) { branch_dead(); } }
static void dead_leaf(void) { dead_sink := 0x66; }
static void dead_parent(void) { dead_leaf(); }
static uint8_t api_child(uint8_t x) { return x + 1; }
uint8_t api(uint8_t x) { return api_child(x) + api_child(x); }
recommend static void contracted(void);
static void contracted(void) { dead_sink := 0x77; }
static void asm_kept(void) { dead_sink := 0x88; }
static void asm_body_kept(void) { asm nop; }
void asm_registry(void) { asm .word asm_kept; }
void done(void) { while (1) {} }
void main(void) { result := live(4) + initialized; gate(0); asm jmp done; }
SRC

sub build {
   my($tag,$profit)=@_;
   my$hex=File::Spec->catfile($tmp,"$tag.hex");
   my$map=File::Spec->catfile($tmp,"$tag.map");
   my$sym=File::Spec->catfile($tmp,"$tag.sym");
   my@c=($driver,'-I',$inc,'-DMACHINE_6502_NO_DEFAULT_ROM','-T',$cfg,'-Map',$map,'-Sym',$sym);
   push@c,'-finline-profit' if $profit;
   push@c,$src,'-o',$hex;
   okrun("build $tag",@c);
   my$mt=read_file($map); my$st=read_file($sym);
   my$done=symaddr($st,'done'); my$res=symaddr($st,'result');
   my($dump,$err)=okrun("sim $tag",$sim,'-T',$cfg,sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$hex);
   $err eq '' or die $err;
   my$mem=parse_dump($dump); $mem->[$res]==14 or die "$tag result=$mem->[$res]\n";
   return $mt;
}

my$normal=build('normal',0);
my$optimized=build('optimized',1);
for my$name(qw(branch_dead dead_leaf dead_parent)) {
   $normal =~ /CODE\.__vcsc_function\$\Q$name\E\b/ or die "normal build missing $name\n$normal";
   $optimized !~ /CODE\.__vcsc_function\$\Q$name\E\b/ or die "optimized build retained unreachable $name\n$optimized";
}
for my$name(qw(init_helper api api_child contracted asm_registry asm_kept asm_body_kept)) {
   $optimized =~ /CODE\.__vcsc_function\$\Q$name\E\b/ or die "optimized build pruned identity/reachability root $name\n$optimized";
}

my$bad=File::Spec->catfile($tmp,'dead-invalid-asm.c26');
my$badhex=File::Spec->catfile($tmp,'dead-invalid-asm.hex');
write_file($bad, <<'BAD');
include "machine_6502.c26"
mem rom { $start:0x8000 $size:0x8000 $ro $priority:1 };
static void dead_bad(void) { asm definitely_not_a_6502_opcode; }
void main(void) { }
BAD
my($brc,$bsig,$bout,$berr)=run_capture($driver,'-I',$inc,'-DMACHINE_6502_NO_DEFAULT_ROM',
   '-T',$cfg,'-finline-profit',$bad,'-o',$badhex);
($brc != 0 || $bsig != 0) or die "dead-function pruning hid an assembler diagnostic\n$bout$berr";

print "Optimizer inline reachability E2E passed\n";
