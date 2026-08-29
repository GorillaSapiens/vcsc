#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: linker destructive dummy reads covered for all 256 opcodes
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file { my($p,$d)=@_; open(my$f,'>:raw',$p) or die "write $p: $!\n"; print {$f} $d; close($f) or die "close $p: $!\n"; }
sub slurp { my($p)=@_; open(my$f,'<:raw',$p) or die "read $p: $!\n"; local $/; my$d=<$f>; close($f); return $d//' '; }
sub run_capture { my(@c)=@_; my$e=gensym; my$pid=open3(my$in,my$out,$e,@c); close($in); local$/; my$o=<$out>//''; my$x=<$e>//''; waitpid($pid,0); return($?>>8,$?&127,$o,$x); }
sub clean_stdout { my($s)=@_; $s =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $s; }
sub require_ok { my($n,@c)=@_; my($x,$sig,$o,$e)=run_capture(@c); $x==0&&!$sig or die "$n failed\n@c\n$o$e"; clean_stdout($o) eq '' or die "$n stdout: $o"; $e eq '' or die "$n stderr: $e"; }
sub require_fail { my($n,$re,@c)=@_; my($x,$sig,$o,$e)=run_capture(@c); $x!=0&&!$sig or die "$n unexpectedly succeeded\n@c\n$o$e"; $e =~ $re or die "$n diagnostic mismatch\nexpected $re\ngot:\n$e"; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp);
my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ld=File::Spec->catfile($repo,'linker','vcsc-ld');

sub cfg_high {
   return <<'CFG';
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$0100,type=rw;
 HAZ: read_start=$F080,write_start=$F000,size=$0080,type=rw,read_hazard=yes;
 ROM: start=$F800,size=$07FA,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 TABLE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
}
sub cfg_zp {
   return <<'CFG';
MEMORY {
 ZEROPAGE: read_start=$0080,write_start=$0000,size=$0080,type=rw,read_hazard=yes;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$0100,type=rw;
 ROM: start=$F800,size=$07FA,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
}
sub cfg_stack {
   return <<'CFG';
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: read_start=$0180,write_start=$0100,size=$0080,type=rw,read_hazard=yes;
 RAM: start=$0200,size=$0100,type=rw;
 ROM: start=$F800,size=$07FA,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=ROM,run=ZEROPAGE,type=zp;
 CODE: load=ROM,type=ro;
 DATA: load=ROM,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
}
sub vector_source {
   my($body)=@_;
   return ".segment \"CODE\"\n.export __reset\n.export __nmi\n.export __irqbrk\n__reset:\n$body\n__nmi:\n  opEA\n__irqbrk:\n  opEA\n";
}
sub assemble_link {
   my($tag,$cfg,$body,$want_fail,$re)=@_;
   my $src=File::Spec->catfile($tmp,"$tag.s26");
   my $obj=File::Spec->catfile($tmp,"$tag.o26");
   my $cf=File::Spec->catfile($tmp,"$tag.cfg");
   my $bin=File::Spec->catfile($tmp,"$tag.bin");
   write_file($src,vector_source($body)); write_file($cf,$cfg);
   require_ok("assemble $tag",$as,'-o',$obj,$src);
   if ($want_fail) { require_fail("link $tag",$re,$ld,'-T',$cf,'-o',$bin,$obj); }
   else { require_ok("link $tag",$ld,'-T',$cf,'-o',$bin,$obj); }
}

# Build the assembler's authoritative 256-byte mode map, then deliberately use
# raw opXX spelling for every byte.  This prevents the regression from silently
# testing only the compiler's legal-opcode subset.
my @mode;
for my $line (split /\n/,slurp(File::Spec->catfile($repo,'assembler','default.cfg'))) {
   next if $line =~ /^\s*#/;
   if ($line =~ /^\s*\S+\s+(imp|acc|imm|zp|zpx|zpy|abs|absx|absy|ind|indx|indy|rel)\s+\$([0-9A-Fa-f]{2})\b/) {
      $mode[hex($2)] //= $1;
   }
}
for my $op (0..255) { defined $mode[$op] or die sprintf("default.cfg lacks opcode %02X\n",$op); }
my $all=".segment \"CODE\"\n.export __reset\n.export __nmi\n.export __irqbrk\n__reset:\n";
for my $op (0..255) {
   my $hex=sprintf('%02X',$op); my $m=$mode[$op];
   my $arg = $m eq 'imm' ? ' #$55' :
             $m eq 'zp'  ? ' $80' :
             $m eq 'zpx' ? ' $80,X' :
             $m eq 'zpy' ? ' $80,Y' :
             $m eq 'abs' ? ' $F800' :
             $m eq 'absx'? ' $F800,X' :
             $m eq 'absy'? ' $F800,Y' :
             $m eq 'ind' ? ' ($F800)' :
             $m eq 'indx'? ' ($80,X)' :
             $m eq 'indy'? ' ($80),Y' : '';
   if ($m eq 'rel') {
      $all .= "  op$hex L_$hex\nL_$hex:\n";
   } else {
      $all .= "  op$hex$arg\n";
   }
}
$all .= "__nmi:\n  opEA\n__irqbrk:\n  opEA\n";
my $all_src=File::Spec->catfile($tmp,'all256.s26');
my $all_obj=File::Spec->catfile($tmp,'all256.o26');
my $all_cfg=File::Spec->catfile($tmp,'all256.cfg');
write_file($all_src,$all); write_file($all_cfg,cfg_high());
require_ok('assemble all 256 raw opcodes',$as,'--illegals','-o',$all_obj,$all_src);
require_ok('link all 256 raw opcodes safely',$ld,'-T',$all_cfg,'-o',File::Spec->catfile($tmp,'all256.bin'),$all_obj);

my $haz=qr/destructive dummy\/read hazard.*?linked PC=.*?may perform/s;
assemble_link('abs_read',cfg_high(),"  opAD \$F000\n",1,$haz);
assemble_link('illegal_abs_read',cfg_high(),"  op0C \$F000\n",1,$haz);
assemble_link('abs_rmw',cfg_high(),"  op0E \$F000\n",1,$haz);
assemble_link('illegal_abs_rmw',cfg_high(),"  op0F \$F000\n",1,$haz);
assemble_link('absx_read_cross',cfg_high(),"  opBD \$F080,X\n",1,qr/page-cross dummy read/s);
assemble_link('absy_read_cross',cfg_high(),"  opB9 \$F080,Y\n",1,qr/page-cross dummy read/s);
assemble_link('illegal_absx_rmw',cfg_high(),"  op1F \$F080,X\n",1,qr/pre-write\/RMW dummy read/s);
assemble_link('sta_same_byte_safe',cfg_high(),"  op9D \$F000,X\n",0,undef);
assemble_link('sta_wrong_high',cfg_high(),"  op9D \$F080,X\n",1,qr/pre-write\/RMW dummy read/s);
assemble_link('illegal_store_wrong_high',cfg_high(),"  op9F \$F080,Y\n",1,qr/pre-write\/RMW dummy read/s);
assemble_link('jmp_indirect',cfg_high(),"  op6C (\$F000)\n",1,qr/JMP indirect vector low read/s);

assemble_link('zp_read',cfg_zp(),"  opA5 \$00\n",1,qr/architectural zero-page read/s);
assemble_link('zpx_dummy',cfg_zp(),"  opB5 \$00,X\n",1,qr/zero-page indexed dummy read/s);
assemble_link('zpy_illegal_dummy',cfg_zp(),"  opB7 \$00,Y\n",1,qr/zero-page indexed dummy read/s);
assemble_link('indx_pointer',cfg_zp(),"  opA1 (\$80,X)\n",1,qr/runtime-indexed pointer read/s);
assemble_link('indy_pointer',cfg_zp(),"  opB1 (\$00),Y\n",1,qr/pointer low read/s);

assemble_link('pha_stack_write_safe',cfg_stack(),"  op48\n",0,undef);
assemble_link('pla_stack_read',cfg_stack(),"  op68\n",1,qr/runtime stack-page read/s);
assemble_link('rts_stack_read',cfg_stack(),"  op60\n",1,qr/runtime stack-page read/s);
assemble_link('jsr_stack_dummy',cfg_stack(),"  op20 target\ntarget:\n  opEA\n",1,qr/JSR stack-page dummy read/s);

sub cfg_edge {
   my($start,$size)=@_;
   return sprintf <<'CFG', $start, $size;
MEMORY {
 ZEROPAGE: start=$0000,size=$0100,type=rw;
 CPUSTACK: start=$0100,size=$0100,type=rw;
 RAM: start=$0200,size=$0100,type=rw;
 EDGE: start=$%04X,size=$%04X,type=ro;
 HAZ: read_start=$F080,write_start=$F000,size=$0080,type=rw,read_hazard=yes;
 SAFE: start=$F100,size=$0EFA,type=ro;
}
SEGMENTS {
 ZEROPAGE: load=SAFE,run=ZEROPAGE,type=zp;
 CODE: load=EDGE,type=ro;
 HANDLERS: load=SAFE,type=ro;
 DATA: load=SAFE,run=RAM,type=data;
 BSS: load=RAM,type=bss;
}
CFG
}
sub edge_case {
   my($tag,$cfg,$body,$cycle_re)=@_;
   my $src=File::Spec->catfile($tmp,"$tag.s26");
   my $obj=File::Spec->catfile($tmp,"$tag.o26");
   my $cf=File::Spec->catfile($tmp,"$tag.cfg");
   write_file($src,".segment \"CODE\"\n.export __reset\n__reset:\n$body\n.segment \"HANDLERS\"\n.export __nmi\n.export __irqbrk\n__nmi:\n  opEA\n__irqbrk:\n  opEA\n");
   write_file($cf,$cfg);
   require_ok("assemble $tag",$as,'--illegals','-o',$obj,$src);
   require_fail("link $tag",$cycle_re,$ld,'-T',$cf,'-o',File::Spec->catfile($tmp,"$tag.bin"),$obj);
}
edge_case('implied_next_pc',cfg_edge(0xEFFF,1),"  opEA\n",qr/implied\/accumulator next-PC dummy read/s);
edge_case('kil_next_pc',cfg_edge(0xEFFF,1),"  op02\n",qr/KIL\/JAM next-PC bus read/s);
edge_case('brk_padding',cfg_edge(0xEFFF,1),"  op00\n",qr/BRK padding-byte read/s);
edge_case('branch_next_pc',cfg_edge(0xEFFE,2),"  opD0 __reset\n",qr/taken-branch next-PC dummy read/s);

# Fixed handwritten assembly must hard-error with source provenance.
my $fixed_src=File::Spec->catfile($tmp,'fixed.s26');
write_file($fixed_src,vector_source("  opB9 \$F05D,Y\n"));
my $fixed_obj=File::Spec->catfile($tmp,'fixed.o26'); my $fixed_cfg=File::Spec->catfile($tmp,'fixed.cfg');
write_file($fixed_cfg,cfg_high()); require_ok('assemble fixed hazard',$as,'--illegals','-o',$fixed_obj,$fixed_src);
require_fail('fixed hazard provenance',qr/\Q$fixed_src\E:\d+:.*opB9.*(?:architectural read|page-cross dummy read)/si,
             $ld,'-T',$fixed_cfg,'-o',File::Spec->catfile($tmp,'fixed.bin'),$fixed_obj);

# A relocatable table is a solvable case: move the table instead of rewriting
# the timing-sensitive indexed instruction.
my $move_src=File::Spec->catfile($tmp,'move.s26');
write_file($move_src,<<'ASM');
.segment "CODE"
.export __reset
.export __nmi
.export __irqbrk
__reset:
  opB9 table+16-256,Y
  op4C __reset
__nmi:
  op40
__irqbrk:
  op40
.segment "TABLE"
.export table
table:
  .res 16
ASM
my $move_obj=File::Spec->catfile($tmp,'move.o26'); require_ok('assemble movable hazard',$as,'--illegals','-o',$move_obj,$move_src);
my $move_cfg=File::Spec->catfile($tmp,'move.cfg'); write_file($move_cfg,cfg_high());
my $move_map=File::Spec->catfile($tmp,'move.map');
require_ok('relocate movable hazard',$ld,'-T',$move_cfg,'-Map',$move_map,'-o',File::Spec->catfile($tmp,'move.bin'),$move_obj);
my $map=slurp($move_map); $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+table\b/m or die "movable map lacks table\n";
my $table=hex($1); my $operand=($table+16-256)&0xffff;
for my $y (0..255) {
   my $final=($operand+$y)&0xffff; my $cross=(($operand&255)+$y)>255;
   next unless $cross;
   my $dummy=($operand&0xff00)|($final&0xff);
   !($dummy>=0xF000 && $dummy<=0xF07F) or die sprintf("relocated table still has dummy read at %04X (Y=%02X)\n",$dummy,$y);
}

print "linker destructive dummy reads covered for all 256 opcodes\n";
