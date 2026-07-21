#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub read_file {
   my ($path)=@_;
   open(my $fh, '<:raw', $path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh) or die "could not close $path: $!\n";
   return defined($d)?$d:'';
}
sub write_file {
   my ($path,$data)=@_;
   open(my $fh, '>:raw', $path) or die "could not create $path: $!\n";
   print {$fh} $data or die "could not write $path: $!\n";
   close($fh) or die "could not close $path: $!\n";
}
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($?>>8,$?&127,$stdout,$stderr);
}
sub require_ok {
   my ($what,$exit,$signal,$stdout,$stderr)=@_;
   die "$what exited $exit signal $signal\nstdout:\n$stdout\nstderr:\n$stderr"
      if $exit != 0 || $signal != 0;
   die "$what wrote unexpected stdout:\n$stdout" if $stdout ne '';
   die "$what wrote unexpected stderr:\n$stderr" if $stderr ne '';
}
sub asm_symbol {
   my ($text,$name)=@_;
   $text =~ /^\$([0-9A-Fa-f]+)\s+.*\Q$name\E\s*$/m
      or die "assembler map is missing $name\n";
   return hex($1);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $assembler=File::Spec->catfile($repo,'assembler','vcsc-as');
my $linker=File::Spec->catfile($repo,'linker','vcsc-ld');
my $vcs_dir=File::Spec->catdir($repo,'libraries','vcs');
my $runtime_dir=File::Spec->catdir($repo,'libraries','runtime');
my $cfg=File::Spec->catfile($vcs_dir,'vcs_4k.cfg');
my $runtime=File::Spec->catfile($runtime_dir,'libvcsc.l26');
my $source=File::Spec->catfile($tmp,'return_memory.c26');
my $assembly=File::Spec->catfile($tmp,'return_memory.s');
my $object=File::Spec->catfile($tmp,'return_memory.o26');
my $asm_map=File::Spec->catfile($tmp,'return_memory.asmap');
my $link_map=File::Spec->catfile($tmp,'return_memory.map');
my $binary=File::Spec->catfile($tmp,'return_memory.bin');

write_file($source, <<'SOURCE');
include "vcs.c26"

uint8_t return8(void) {
   return 0xa5`uint8_t;
}

uint16_t return16(void) {
   return 0x1234`uint16_t;
}

bcd24_t return24(void) {
   return 567890;
}

bcd32_t return32(void) {
   return 12345678;
}

void main(void) {
   uint8_t a := return8();
   uint16_t b := return16();
   bcd24_t c := return24();
   bcd32_t d := return32();
   if (a == 0 && b == 0 && c == 0 && d == 0) {
      asm nop;
   }
   asm @forever:;
   asm jmp @forever;
}
SOURCE

my ($exit,$signal,$stdout,$stderr)=run_capture(
   $driver,'-I',$vcs_dir,'-S',$source,'-o',$assembly,
);
require_ok('compiler',$exit,$signal,$stdout,$stderr);

($exit,$signal,$stdout,$stderr)=run_capture(
   $assembler,'-I',$vcs_dir,'-I',$runtime_dir,"--map=$asm_map",'-o',$object,$assembly,
);
require_ok('assembler',$exit,$signal,$stdout,$stderr);

($exit,$signal,$stdout,$stderr)=run_capture(
   $linker,'-T',$cfg,'-Map',$link_map,'-o',$binary,$object,$runtime,
);
require_ok('linker',$exit,$signal,$stdout,$stderr);

my $asmap=read_file($asm_map);
my $ldmap=read_file($link_map);
my $rom=read_file($binary);
length($rom)==4096 or die "raw cartridge size is ".length($rom).", expected 4096\n";

my $return8_slot_off=asm_symbol($asmap,'return8$__return');
my $return16_slot_off=asm_symbol($asmap,'return16$__return');
my $return24_slot_off=asm_symbol($asmap,'return24$__return');
my $return32_slot_off=asm_symbol($asmap,'return32$__return');
my $return8_fini_off=asm_symbol($asmap,'return8::@fini');
my $return16_fini_off=asm_symbol($asmap,'return16::@fini');
my $return24_fini_off=asm_symbol($asmap,'return24::@fini');
my $return32_fini_off=asm_symbol($asmap,'return32::@fini');

$ldmap =~ /MEMORY\s+.*?ROM\s+start=\$([0-9A-Fa-f]+)/s
   or die "linker map is missing ROM start\n";
my $rom_start=hex($1);

$ldmap =~ /\Q$object\E\n(.*?)(?=\n  \S|\nTABLES)/s
   or die "linker map is missing test object layout\n";
my $layout=$1;
$layout =~ /ZEROPAGE\s+run=\$([0-9A-Fa-f]+)/
   or die "test object has no ZEROPAGE layout\n";
my $zp_run=hex($1);
$layout =~ /CODE\s+load=\$([0-9A-Fa-f]+)/
   or die "test object has no CODE layout\n";
my $code_load=hex($1);

my $return8_slot=$zp_run+$return8_slot_off;
my $return16_slot=$zp_run+$return16_slot_off;
my $return24_slot=$zp_run+$return24_slot_off;
my $return32_slot=$zp_run+$return32_slot_off;
$return8_slot <= 0xff or die sprintf("8-bit return object is not zero page: %04x\n",$return8_slot);
$return16_slot+1 <= 0xff or die sprintf("16-bit return object is not zero page: %04x\n",$return16_slot);
$return24_slot+2 <= 0xff or die sprintf("24-bit return object is not zero page: %04x\n",$return24_slot);
$return32_slot+3 <= 0xff or die sprintf("32-bit BCD return object is not zero page: %04x\n",$return32_slot);
$return16_slot-$return8_slot == 1
   or die "8-bit return object does not reserve exactly one byte\n";
$return24_slot-$return16_slot == 2
   or die "16-bit return object does not reserve exactly two bytes\n";
$return32_slot-$return24_slot == 3
   or die "24-bit return object does not reserve exactly three bytes\n";

for my $item (
   [ return8 => $return8_fini_off ],
   [ return16 => $return16_fini_off ],
   [ return24 => $return24_fini_off ],
   [ return32 => $return32_fini_off ],
) {
   my ($name,$off)=@$item;
   my $pos=$code_load+$off-$rom_start;
   my $byte=unpack('C',substr($rom,$pos,1));
   $byte == 0x60 or die sprintf("%s epilogue byte is %02X, expected RTS (60)\n",$name,$byte);
}

my $assembly_text=read_file($assembly);
$assembly_text !~ /\@fini:\n\s+(?:lda|ldx|ldy)\s+[^\n]*\$__return/
   or die "a value-return epilogue still reloads a return object into registers\n";
$assembly_text =~ /jsr return24\n(?:\s+ldy #\d+\n\s+lda return24\$__return,y\n\s+sta __vcsc_scratch_\d+,y\n){3}/
   or die "caller does not consume the three-byte callee-owned return object directly\n";
$assembly_text =~ /jsr return32\n(?:\s+ldy #\d+\n\s+lda return32\$__return,y\n\s+sta __vcsc_scratch_\d+,y\n){4}/
   or die "caller does not consume the four-byte BCD callee-owned return object directly\n";

print "vcs return memory encoding ok\n";
