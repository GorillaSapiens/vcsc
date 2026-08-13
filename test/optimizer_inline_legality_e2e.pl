#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Optimizer inline legality E2E passed
# expectexit: 0

use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file { my($p,$t)=@_; open my$f,'>:raw',$p or die "write $p: $!"; print{$f}$t; close$f; }
sub read_file { my($p)=@_; open my$f,'<:raw',$p or die "read $p: $!"; local$/; my$t=<$f>//''; close$f; return$t; }
sub capture { my(@c)=@_; my$e=gensym; my$p=open3(my$i,my$o,$e,@c); close$i; local$/; my$out=<$o>//''; my$err=<$e>//''; waitpid($p,0); return($?>>8,$?&127,$out,$err); }
sub okrun { my($label,@c)=@_; my($r,$s,$o,$e)=capture(@c); $r==0&&!$s or die "$label failed rc=$r sig=$s\n@c\nstdout:\n$o\nstderr:\n$e"; return($o,$e); }
sub symaddr { my($s,$n)=@_; $s =~ /^\Q$n\E\s+([0-9A-Fa-f]{4})\s*$/m or die "missing symbol $n\n$s"; return hex$1; }
sub parse_dump { my($t)=@_; my@m=(0)x65536; for(split/\n/,$t){ next unless /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/; my($n,$a,$b)=(hex$1,hex$2,$3); for my$i(0..$n-1){$m[$a+$i]=hex substr($b,$i*2,2)} } return\@m; }
sub layout_size { my($m,$n)=@_; $m =~ /CODE\.__vcsc_function\$\Q$n\E\s+load=\$[0-9A-Fa-f]+\s+size=\$([0-9A-Fa-f]+)/ or die "map missing layout size $n\n$m"; return hex$1; }

my($repo,$tmp)=@ARGV; die "usage: $0 REPO TMP\n" unless defined$repo&&defined$tmp;
make_path($tmp);
my$driver=File::Spec->catfile($repo,'driver','vcsc');
my$sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my$inc=File::Spec->catdir($repo,'test');
my$cfg=File::Spec->catfile($repo,'test','generic_6502.cfg');
my$src=File::Spec->catfile($tmp,'inline-legality.c26');

write_file($src, <<'C26');
include "machine_6502.c26"
uint8_t status;

static void safe_target(void) { status += 4; }

/* The separate page_target is small, but page_caller deliberately occupies most
   of one page. Inlining page_target would make the hard page contract depend on
   optimizer growth; subsection 4 therefore retains the call without trial-link
   rollback support. The reserved bytes are skipped at runtime. */
static void page_target(void) {
   status += 8; status += 8; status += 8; status += 8;
   status += 8; status += 8; status += 8; status += 8;
}
page static void page_caller(void) {
   page_target();
   asm jmp @after_padding;
   asm .res 190;
   asm @after_padding:;
}

static void same_target(void) { status += 1; }
static void same_caller(void) {
   same_target();
   asm lda #0;
   asm beq.same @same_done;
   asm nop;
   asm @same_done:;
}

static void cross_target(void) { status += 2; }
static void cross_caller(void) {
   cross_target();
   asm lda #0;
   asm beq.cross @cross_done;
   asm nop;
   asm @cross_done:;
}

void simulator_done(void) { while (1) {} }
void main(void) {
   /* Keep page_caller reachable without executing its padding in simulation. */
   if (status == 0xff) { page_caller(); }
   safe_target();
   same_caller();
   cross_caller();
   asm jmp simulator_done;
}
C26

sub build {
   my($tag,$forced)=@_;
   my$hex=File::Spec->catfile($tmp,"$tag.hex");
   my$map=File::Spec->catfile($tmp,"$tag.map");
   my$sym=File::Spec->catfile($tmp,"$tag.sym");
   my@c=($driver,'-I',$inc,'-T',$cfg,'-Map',$map,'-Sym',$sym);
   push@c,('-Xcompiler','-Xinlineir') if $forced;
   push@c,($src,'-o',$hex);
   okrun("build $tag",@c);
   return($hex,read_file($map),read_file($sym));
}

my($normal_hex,$normal_map,$normal_sym)=build('normal',0);
my($forced_hex,$forced_map,$forced_sym)=build('forced',1);
for my$name(qw(page_target page_caller same_target same_caller cross_target cross_caller)) {
   $forced_map =~ /CODE\.__vcsc_function\$\Q$name\E\b/
      or die "forced map removed placement-sensitive $name\n$forced_map";
}
$forced_map !~ /CODE\.__vcsc_function\$safe_target\b/
   or die "forced map retained unconstrained safe_target\n$forced_map";
$forced_map =~ /CODE\.__vcsc_function\$page_caller\b.*?page=hard/s
   or die "forced map lost hard page containment\n$forced_map";
my$page_size=layout_size($forced_map,'page_caller');
my$target_size=layout_size($forced_map,'page_target');
$page_size + $target_size - 3 > 256
   or die "page fixture no longer proves inlining could exceed hard containment: caller=$page_size target=$target_size\n";
$forced_map =~ /taken-page=same policy=same/
   or die "forced map lost .same branch policy\n$forced_map";
$forced_map =~ /taken-page=crossing policy=cross/
   or die "forced map lost .cross branch policy\n$forced_map";

my$done=symaddr($forced_sym,'simulator_done');
my$status=symaddr($forced_sym,'status');
my($dump,$err)=okrun('simulate forced',$sim,'-T',$cfg,sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$forced_hex);
$err eq '' or die "simulator stderr:\n$err";
my$mem=parse_dump($dump);
$mem->[$status]==7 or die sprintf("forced status=%02X expected 07\n",$mem->[$status]);

print "Optimizer inline legality E2E passed\n";
