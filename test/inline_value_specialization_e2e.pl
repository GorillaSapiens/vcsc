#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: Inline value specialization E2E passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp { my ($fh)=@_; local $/; return <$fh> // ''; }
sub run_capture {
   my (@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close $in;
   my $stdout=slurp($out); my $stderr=slurp($err); waitpid($pid,0);
   return ($?>>8,$?&127,$stdout,$stderr);
}
sub okrun {
   my ($label,@cmd)=@_; my ($rc,$sig,$out,$err)=run_capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
}
sub write_file { my ($p,$t)=@_; open my $f,'>:raw',$p or die "write $p: $!"; print {$f} $t; close $f; }
sub read_file { my ($p)=@_; open my $f,'<:raw',$p or die "read $p: $!"; local $/; my $t=<$f>//''; close $f; return $t; }
sub symaddr { my ($s,$n)=@_; $s =~ /^\Q$n\E\s+([0-9A-Fa-f]{4})\s*$/m or die "missing symbol $n\n"; return hex $1; }
sub parse_dump {
   my ($t)=@_; my @m=(0)x65536;
   for(split /\n/,$t){ next unless /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my($n,$a,$b)=(hex($1),hex($2),$3); for my $i(0..$n-1){$m[$a+$i]=hex substr($b,$i*2,2)} }
   return \@m;
}
sub activation_bss_size {
   my ($map,$name)=@_;
   return hex($1) if $map =~ /^\s*BSS\.__vcsc_activation\$\Q$name\E\s+run=\$[0-9A-Fa-f]{4}\s+size=\$([0-9A-Fa-f]{4})\b/m;
   return 0;
}

my ($repo,$tmp)=@ARGV; die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $inc=File::Spec->catdir($repo,'test');
my $cfg=File::Spec->catfile($tmp,'inline-value.cfg');
my $src=File::Spec->catfile($tmp,'inline-value.c26');
my $hex=File::Spec->catfile($tmp,'inline-value.hex');
my $map_path=File::Spec->catfile($tmp,'inline-value.map');
my $sym_path=File::Spec->catfile($tmp,'inline-value.sym');

write_file($cfg, <<'CFG');
MEMORY {
    ZEROPAGE: start = $0000, size = $0100, type = rw, define = yes;
    CPUSTACK: start = $0100, size = $0100, type = rw, define = yes;
    RAM:      start = $0200, size = $1E00, type = rw, define = yes;
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

uint8_t mutable_global;
uint8_t *escaped_pointer;
uint8_t status;
uint8_t result0;
uint8_t result1;
uint8_t result2;
uint8_t result3;
uint8_t result4;
uint16_t result16;

static void save_ref(ref uint8_t y) { escaped_pointer := &y; }
static void mutate_copy(ref uint8_t y) { y++; }
static const uint8_t *address_of_copy(ref const uint8_t y) { return &<y; }

static uint8_t safe_value(uint8_t x) { return x + 1; }
static uint8_t escaped_value(uint8_t x) { return x + 1; }
static uint8_t literal_value(uint8_t x) { return x + 3; }
static uint8_t const_if_zero(uint8_t x) { if (x) { return 9; } else { return 4; } }
static uint8_t written_value(uint8_t x) { x++; return x; }
static uint8_t write_through_value(uint8_t x) { mutate_copy(x); return x; }
static uint8_t same_alias(uint8_t x, ref uint8_t y) { y++; return x; }
static uint8_t global_copy(uint8_t x) { mutable_global++; return x; }
static const uint8_t *address_observed(const uint8_t x) { return address_of_copy(x); }
static uint16_t conversion_value(uint16_t x) { return x + 0x100; }

void simulator_done(void) { while (1) {} }
void main(void) {
   uint8_t safe := 10;
   uint8_t escaped := 20;
   uint8_t written := 30;
   uint8_t through := 40;
   uint8_t aliased := 50;
   uint8_t observed := 60;
   uint8_t converted := 70;
   const uint8_t *observed_address;

   save_ref(escaped);
   result0 := safe_value(safe);              // aliases safe caller storage
   result1 := escaped_value(escaped);        // must retain by-value copy
   result2 := literal_value(7);              // no parameter storage
   if (const_if_zero(0) != 4) { status := 11; asm jmp simulator_done; }
   result3 := written_value(written);        // formal is mutable: copy required
   result4 := write_through_value(through);  // ref exposure of formal: copy required

   result0 := result0 + same_alias(aliased, aliased);
   mutable_global := 80;
   result1 := result1 + global_copy(mutable_global);
   observed_address := address_observed(observed);
   result16 := conversion_value(converted);

   if (safe != 10 || result0 != 61) { status := 1; asm jmp simulator_done; }
   if (escaped != 20 || result1 != 101) { status := 2; asm jmp simulator_done; }
   if (result2 != 10) { status := 3; asm jmp simulator_done; }
   if (written != 30 || result3 != 31) { status := 4; asm jmp simulator_done; }
   if (through != 40 || result4 != 41) { status := 5; asm jmp simulator_done; }
   if (aliased != 51) { status := 6; asm jmp simulator_done; }
   if (mutable_global != 81) { status := 7; asm jmp simulator_done; }
   if (observed_address == &observed) { status := 8; asm jmp simulator_done; }
   if (result16 != 0x146) { status := 9; asm jmp simulator_done; }
   status := 0xaa;
   asm jmp simulator_done;
}
SOURCE

okrun('build readonly value specialization fixture', $driver, '-I',$inc,
      '-DMACHINE_6502_NO_DEFAULT_ROM','-T',$cfg,'-Map',$map_path,'-Sym',$sym_path,
      $src,'-o',$hex);
my $map=read_file($map_path);
my $safe_size=activation_bss_size($map,'safe_value');
my $escaped_size=activation_bss_size($map,'escaped_value');
$escaped_size == $safe_size + 1
   or die "safe/escaped activation sizes are $safe_size/$escaped_size, expected exactly one byte saved\n$map";

my $sym=read_file($sym_path);
my $done=symaddr($sym,'simulator_done');
my $status=symaddr($sym,'status');
my ($dump,$err)=okrun('simulate readonly value specialization fixture', $sim,'-T',$cfg,
                      sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$hex);
$err eq '' or die "simulator stderr:\n$err";
my $mem=parse_dump($dump);
$mem->[$status] == 0xaa
   or die sprintf("readonly value specialization status is %02X, expected AA\n",$mem->[$status]);

print "Inline value specialization E2E passed\n";
