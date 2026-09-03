#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 3E swapram acceptance passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my ($fh)=@_; local $/; return <$fh> // ''; }
sub run_capture {
   my (@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8, $? & 127, $so, $se);
}
sub require_ok {
   my ($label,@cmd)=@_; my ($rc,$sig,$out,$err)=run_capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
}
sub write_file {
   my ($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n"; print {$fh} $d; close($fh);
}
sub read_file {
   my ($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>; close($fh); return $d // '';
}
sub map_symbol {
   my ($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing symbol $name\n";
   return hex($1);
}
sub parse_hex_dump {
   my ($text)=@_; my @mem=(0)x65536;
   for my $line (split /\n/,$text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my ($n,$a,$data)=(hex($1),hex($2),$3);
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
my $cc1=File::Spec->catfile($repo,'compiler','vcsc-cc1');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');

sub run_program {
   my ($name,$source)=@_;
   my $src=File::Spec->catfile($tmp,"$name.c26");
   my $bin=File::Spec->catfile($tmp,"$name.bin");
   my $map_path=File::Spec->catfile($tmp,"$name.map");
   write_file($src,$source);
   require_ok("build $name",$driver,'-I',$vcs,'-Map',$map_path,'--no-list','--no-cfg','-o',$bin,$src);
   my $map=read_file($map_path);
   my $done=map_symbol($map,'simulator_done');
   my $failure=map_symbol($map,'failure');
   my ($dump,$err)=require_ok("simulate $name",$sim,'--map='.$map_path,
      sprintf('--stop-pc=0x%04X',$done),'--dump-on-stop',$bin);
   $err eq '' or die "$name simulator wrote stderr:\n$err";
   my $mem=parse_hex_dump($dump);
   $mem->[$failure]==0 or die sprintf("%s failed: failure=\$%02X\n",$name,$mem->[$failure]);
   return ($src,$map_path,$map);
}

my %families=(
   signed => [
      'int8_t','int16_t','int24_t','int32_t',
      '-7','-300','-70000','-1000000',
      '-8','-301','-70001','-1000001'
   ],
   unsigned => [
      'uint8_t','uint16_t','uint24_t','uint32_t',
      '0xa5','0xbeef','0xabcdef','0x12345678',
      '0x5a','0x1234','0x345678','0x87654321'
   ],
   bcd => [
      'bcd8_t','bcd16_t','bcd24_t','bcd32_t',
      '42','1234','123456','12345678',
      '43','1235','123457','12345679'
   ],
);

for my $family (qw(signed unsigned bcd)) {
   my @v=@{$families{$family}};
   my ($t1,$t2,$t3,$t4,$a1,$a2,$a3,$a4,$b1,$b2,$b3,$b4)=@v;
   my $source=qq{instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)\nuint8_t failure;\nswapram $t1 a; swapram $t2 b; swapram $t3 c; swapram $t4 d;\nbank0 void lower(void) {\n a := $a1; b := $a2; c := $a3; d := $a4;\n if (a != $a1) { failure := 1; } if (b != $a2) { failure := 2; }\n if (c != $a3) { failure := 3; } if (d != $a4) { failure := 4; }\n}\nbank3 void fixed(void) {\n if (a != $a1) { failure := 5; } if (b != $a2) { failure := 6; }\n if (c != $a3) { failure := 7; } if (d != $a4) { failure := 8; }\n a := $b1; b := $b2; c := $b3; d := $b4;\n if (a != $b1) { failure := 9; } if (b != $b2) { failure := 10; }\n if (c != $b3) { failure := 11; } if (d != $b4) { failure := 12; }\n}\nbank3 void simulator_done(void) { while (1) { } }\nbank3 void main(void) { failure := 0; lower(); fixed(); asm jmp simulator_done; }\n};
   my (undef,undef,$map)=run_program("swapram_$family",$source);
   for my $width (1..4) {
      my $r=map_symbol($map,"swapram_read$width");
      my $w=map_symbol($map,"swapram_write$width");
      ($r>=0x1800 && $r<=0x1fff && $w>=0x1800 && $w<=0x1fff)
         or die "swapram width-$width helper escaped fixed/startup ROM\n";
   }
   $map =~ /^\s*STARTUP\s+load=\$[0-9A-Fa-f]{4}\s+size=\$[0-9A-Fa-f]{4}\b.*bank=bank3\s+region=bank3\s+placement=pinned/m
      or die "swapram helper object is not pinned wholly into startup bank\n$map";
   my $z=map_symbol($map,"swapram_zero");
   ($z>=0x1800 && $z<=0x1fff)
      or die "swapram zero helper escaped fixed/startup ROM\n";
}

run_program('swapram_index_compound', <<'SRC');
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)
uint8_t failure;
swapram uint16_t words[8];
swapram uint16_t accum;
bank0 void lower(void) {
   uint8_t i;
   swapram uint32_t local := 0x89abcdef;
   i := 5;
   words[i] := 0xcafe;
   if (words[i] != 0xcafe) { failure := 1; }
   accum := 10;
   accum += 20;
   ++accum;
   if (accum != 31) { failure := 2; }
   if (local != 0x89abcdef) { failure := 3; }
}
bank3 void simulator_done(void) { while (1) { } }
bank3 void main(void) { failure := 0; lower(); asm jmp simulator_done; }
SRC

my $init_source=<<'SRC';
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)
uint8_t failure;
uint16_t seed := 0x1234;
swapram uint32_t init_data := 0x12345678;
swapram uint32_t init_zero;
swapram uint8_t large_zero[1024];
swapram uint16_t runtime_data := seed + 1;
bank0 void check_static(void) {
   static swapram uint16_t local_static := 0x9abc;
   if (local_static != 0x9abc) { failure := 4; }
}
bank3 void simulator_done(void) { while (1) { } }
bank3 void main(void) {
   failure := 0;
   if (init_data != 0x12345678) { failure := 1; }
   if (init_zero != 0) { failure := 2; }
   if (large_zero[0] != 0 || large_zero[1023] != 0) { failure := 5; }
   if (runtime_data != 0x1235) { failure := 3; }
   check_static();
   asm jmp simulator_done;
}
SRC
my ($init_src,undef,$init_map)=run_program('swapram_init',$init_source);
my $init_asm=File::Spec->catfile($tmp,'swapram_init.s26');
require_ok('compile swapram initializer source',$cc1,'-I',$vcs,'-o',$init_asm,$init_src);
my $asm=read_file($init_asm);
$asm =~ /^\.segment "BSS\.swapram\.__vcsc_object\$init_data"$/m &&
$asm =~ /^\.segment "BSS\.swapram\.__vcsc_object\$init_zero"$/m &&
$asm =~ /^\.segment "BSS\.swapram\.__vcsc_object\$runtime_data"$/m &&
$asm =~ /^\.segment "BSS\.swapram\.__vcsc_object\$large_zero"$/m
   or die "swapram file-scope initialization did not reserve swapram BSS objects\n$asm";
$asm !~ /^\.segment "DATA\.swapram\.__vcsc_object\$(?:init_data|init_zero|runtime_data)"$/m
   or die "swapram startup incorrectly emitted ordinary DATA storage\n$asm";
for my $pair (['init_data',4],['runtime_data',2]) {
   my ($sym,$width)=@$pair;
   $asm =~ /#<\{\Q$sym\E \+ 0\}.*?#\^\{\Q$sym\E \+ 0\}.*?jsr swapram_write\Q$width\E\s*\n\s*\.banktarget swapram_write\Q$width\E/s
      or die "runtime initializer did not lower $sym through swapram_write$width\n$asm";
}
$asm =~ /#<\{init_zero \+ 0\}.*?#\^\{init_zero \+ 0\}.*?lda #<4\s*\n\s*sta ptr2\s*\n\s*lda #>4\s*\n\s*sta ptr2\+1\s*\n\s*jsr swapram_zero\s*\n\s*\.banktarget swapram_zero/s
   or die "zero-initialized swapram object did not lower through compact swapram_zero helper\n$asm";
$asm =~ /#<\{large_zero \+ 0\}.*?#\^\{large_zero \+ 0\}.*?lda #<1024\s*\n\s*sta ptr2\s*\n\s*lda #>1024\s*\n\s*sta ptr2\+1\s*\n\s*jsr swapram_zero\s*\n\s*\.banktarget swapram_zero/s
   or die "large zero-initialized swapram object did not use one compact swapram_zero call\n$asm";
$asm =~ /check_static\$local_static.*?jsr swapram_write2\s*\n\s*\.banktarget swapram_write2/s
   or die "static local swapram initializer did not use swapram_write2\n$asm";
$init_map =~ /^\s*CODE\.__vcsc_function\$__init_[0-9a-f]+\s+load=\$[0-9A-Fa-f]{4}.*bank=bank3\s+region=bank3\s+placement=pinned/m
   or die "swapram runtime initializer is not pinned to startup/fixed bank\n$init_map";
$init_map !~ /^(?:\s+)?(?:COPY|ZERO)\s+.*\.swapram(?:\.|\s)/m
   or die "swapram initialization leaked into ordinary CPU COPY/ZERO tables\n$init_map";

# Bank-boundary packing and >64K/18-bit relocation are intentionally retained
# in swapram_metadata_allocation.pl; this acceptance test covers the live
# compiler/helper/runtime surface that consumes those placements.
print "3E swapram acceptance passed\n";
