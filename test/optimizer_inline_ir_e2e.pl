#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Optimizer inline IR E2E passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local$/; return <$fh>//''; }
sub run_capture { my(@cmd)=@_; my$err=gensym; my$pid=open3(my$in,my$out,$err,@cmd); close$in; my$o=slurp_fh($out); my$e=slurp_fh($err); waitpid($pid,0); return($?>>8,$?&127,$o,$e); }
sub okrun { my($label,@cmd)=@_; my($rc,$sig,$o,$e)=run_capture(@cmd); $rc==0&&!$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$o\nstderr:\n$e"; return($o,$e); }
sub write_file { my($p,$t)=@_; open my$f,'>:raw',$p or die "write $p: $!"; print{$f}$t; close$f; }
sub read_file { my($p)=@_; open my$f,'<:raw',$p or die "read $p: $!"; local$/; my$t=<$f>//''; close$f; return$t; }
sub symaddr { my($s,$n)=@_; $s =~ /^\Q$n\E\s+([0-9A-Fa-f]{4})\s*$/m or die "missing symbol $n\n$s"; return hex$1; }
sub parse_dump { my($t)=@_; my@m=(0)x65536; for(split/\n/,$t){ next unless /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/; my($n,$a,$b)=(hex$1,hex$2,$3); for my$i(0..$n-1){$m[$a+$i]=hex substr($b,$i*2,2)} } return\@m; }
sub map_symbol_value { my($m,$n)=@_; $m =~ /^\s*\$([0-9A-Fa-f]+)\s+\Q$n\E\b/m or die "map missing $n\n$m"; return hex$1; }
sub activation_run { my($m,$owner)=@_; $m =~ /^\s*BSS\.__vcsc_activation\$\Q$owner\E\s+run=\$([0-9A-Fa-f]+)/m or die "map missing BSS activation $owner\n$m"; return hex$1; }
sub activation_peak_end { my($m)=@_; my$max=0; while($m =~ /^\s*BSS\.__vcsc_activation\$\S+\s+run=\$([0-9A-Fa-f]+)\s+size=\$([0-9A-Fa-f]+)/mg){ my$end=hex($1)+hex($2); $max=$end if $end>$max; } $max or die "map has no BSS activations\n$m"; return $max; }

my($repo,$tmp)=@ARGV; die "usage: $0 REPO TMP\n" unless defined$repo&&defined$tmp;
my$driver=File::Spec->catfile($repo,'driver','vcsc');
my$sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my$inc=File::Spec->catdir($repo,'test');
my$cfg=File::Spec->catfile($tmp,'inline-ir.cfg');
my$src=File::Spec->catfile($tmp,'inline-ir.c26');

write_file($cfg, <<'CFG');
MEMORY {
    ZEROPAGE: start = $0000, size = $0100, type = rw, define = yes;
    CPUSTACK: start = $0100, size = $0100, type = rw, define = yes;
    RAM:      start = $0200, size = $1E00, type = rw, define = yes, callstack = callgraph;
    ROM:      start = $8000, size = $8000, type = ro, define = yes;
}
SEGMENTS {
    ZEROPAGE: load = ROM, run = ZEROPAGE, type = zp, define = yes;
    CODE:     load = ROM, type = ro, define = yes;
    RODATA:   load = ROM, type = ro, define = yes;
    BSS:      load = RAM, type = bss, define = yes;
    DATA:     load = ROM, run = RAM, type = data, define = yes;
}
CFG
write_file($src, <<'SOURCE');
include "machine_6502.c26"
mem rom { $start:0x8000 $size:0x8000 $ro $priority:1 };
uint8_t status;
uint8_t observed;

static void touch(ref uint8_t x) {
   uint8_t local := 2;
   x += local;
}
static uint8_t choose(uint8_t x) {
   uint8_t y := x + 3;
   if (x == 0) { return 0x44; }
   if (x == 5) { return y; }
   return 0x55;
}
static uint8_t leaf(uint8_t x) {
   return x + 4;
}
static uint8_t shared(uint8_t x) {
   uint8_t local := x + 1;
   return local;
}
static uint8_t middle(uint8_t x) {
   uint8_t local := leaf(x);
   return local + shared(local);
}
static uint8_t mutate(uint8_t x) {
   /* x is written, so subsection 2 must leave a real by-value slot to inline. */
   x += 2;
   return x;
}
static uint8_t unique_choose(uint8_t x) {
   if (x == 5) { return 0x66; }
   return 0x77;
}
static uint8_t combine(uint8_t a, uint8_t b) {
   /* a is copied before b is evaluated; b may call shared(). */
   a += b;
   return a;
}

void simulator_done(void) { while (1) {} }
void main(void) {
   uint8_t value := 3;
   touch(value);                    // -> 5
   if (choose(0) != 0x44) { status := 1; asm jmp simulator_done; }
   if (choose(value) != 8) { status := 2; asm jmp simulator_done; }
   /* choose/shared each have two callsites and remain ordinary; middle/leaf inline.
      middle's local must survive its ordinary shared() call. */
   observed := middle(value);       // local=9, shared(9)=10, result=19
   if (value != 5 || observed != 19) { status := 3; asm jmp simulator_done; }
   if (shared(3) != 4) { status := 4; asm jmp simulator_done; }
   if (mutate(5) != 7) { status := 5; asm jmp simulator_done; }
   if (unique_choose(value) != 0x66) { status := 6; asm jmp simulator_done; }
   if (combine(4, shared(5)) != 10) { status := 7; asm jmp simulator_done; }
   status := 0xaa;
   asm jmp simulator_done;
}
SOURCE

sub build_and_sim {
   my($tag,$forced)=@_;
   my$hex=File::Spec->catfile($tmp,"$tag.hex"); my$map=File::Spec->catfile($tmp,"$tag.map"); my$sym=File::Spec->catfile($tmp,"$tag.sym");
   my@cmd=($driver,'-I',$inc,'-DMACHINE_6502_NO_DEFAULT_ROM','-T',$cfg,'-Map',$map,'-Sym',$sym);
   push @cmd,('-Xcompiler','-Xinlineir') if $forced;
   push @cmd,($src,'-o',$hex);
   okrun("build $tag",@cmd);
   my$st=read_file($sym); my$done=symaddr($st,'simulator_done'); my$status=symaddr($st,'status');
   my($dump,$err)=okrun("simulate $tag",$sim,'-T',$cfg,sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$hex);
   $err eq '' or die "$tag simulator stderr:\n$err";
   my$mem=parse_dump($dump); $mem->[$status]==0xaa or die sprintf("$tag status=%02X expected AA\n",$mem->[$status]);
   return read_file($map);
}

my$normal=build_and_sim('normal',0);
my$forced=build_and_sim('forced',1);
$normal =~ /CODE\.__vcsc_function\$middle\b/ or die "normal map missing middle function\n$normal";
$normal =~ /CODE\.__vcsc_function\$leaf\b/ or die "normal map missing leaf function\n$normal";
$forced !~ /CODE\.__vcsc_function\$middle\b/ or die "forced map retained middle function\n$forced";
$forced !~ /CODE\.__vcsc_function\$leaf\b/ or die "forced map retained leaf function\n$forced";
$forced !~ /CODE\.__vcsc_function\$mutate\b/ or die "forced map retained mutate function\n$forced";
$forced !~ /CODE\.__vcsc_function\$unique_choose\b/ or die "forced map retained unique_choose function\n$forced";
$forced !~ /CODE\.__vcsc_function\$combine\b/ or die "forced map retained combine function\n$forced";
# choose/shared are deliberately called twice and therefore never single-callsite candidates.
$forced =~ /CODE\.__vcsc_function\$choose\b/ or die "forced map unexpectedly removed choose\n$forced";
$forced =~ /CODE\.__vcsc_function\$shared\b/ or die "forced map unexpectedly removed shared\n$forced";
# Inlining must preserve activation nesting/overlay independently of hardware JSR depth.
activation_run($normal,'touch') == activation_run($normal,'middle')
   or die "normal sibling activations do not overlay\n$normal";
activation_run($forced,'touch') == activation_run($forced,'middle')
   or die "forced sibling activations lost overlay\n$forced";
activation_run($forced,'mutate') == activation_run($forced,'middle')
   or die "forced mutable-parameter inline activation lost sibling overlay\n$forced";
activation_run($forced,'combine') == activation_run($forced,'middle')
   or die "forced staged-argument inline activation lost sibling overlay\n$forced";
activation_run($normal,'leaf') == activation_run($normal,'shared')
   or die "normal middle children do not overlay\n$normal";
activation_run($forced,'leaf') == activation_run($forced,'shared')
   or die "forced inline/direct middle children lost overlay\n$forced";
activation_peak_end($forced) <= activation_peak_end($normal)
   or die "forced inlining increased peak BSS activation RAM\n$forced";
$forced !~ /EDGE middle -> shared/ or die "activation-only edge leaked into hardware call graph\n$forced";
my$normal_depth=map_symbol_value($normal,'__call_stack_depth');
my$forced_depth=map_symbol_value($forced,'__call_stack_depth');
$forced_depth < $normal_depth or die "forced stack depth $forced_depth did not improve on $normal_depth\n";

print "Optimizer inline IR E2E passed\n";
