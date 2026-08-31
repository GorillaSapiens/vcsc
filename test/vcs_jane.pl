#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: JANE diagnostic passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Copy qw(copy);
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
sub read_file {
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub map_symbol {
   my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map missing $name\n"; return hex($1);
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
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $disas=File::Spec->catfile($repo,'disassembler','vcsc-disas');
my $roundtrip=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $cfg=File::Spec->catfile($vcs,'JANE/mapper.cfg');
my $profile=File::Spec->catfile($vcs,'JANE/mapper.c26');
my $source=File::Spec->catfile($repo,'examples','09_bankswitching','07_jane','jane_diagnostic.c26');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','07_jane');
my $example_make=File::Spec->catfile($example_dir,'Makefile');
my $example_readme=File::Spec->catfile($example_dir,'README.md');

my $mk=read_file($example_make);
$mk =~ /^play:\s*\$\(TARGET\)\s*$/m &&
$mk =~ /^\s*stella\s+-bs\s+JANE\s+\$\(TARGET\)\s*$/m
   or die "JANE play target must force Stella -bs JANE\n";
my $ert=read_file($example_readme);
$ert =~ /Stella 7\.0 or newer/ && $ert =~ /stella -bs JANE jane_diagnostic\.bin/
   or die "JANE README must document Stella 7.0+ and forced mapper launch\n";
my $src=read_file($source);
$src =~ /instantiate \"six_glyph_big_wide_component\.c26\" as status_result/ &&
$src =~ /instantiate \"six_glyph_component\.c26\" as cart_type \(compact_font:=0\)/ &&
$src =~ /status_result_color\s*:=\s*0x0e/ &&
$src =~ /^void\s+main\s*\(void\)\s*\{/m &&
$src !~ /^bank\d+\s+void\s+main\s*\(/m &&
$src =~ /81 blank \+ 19 result \+ 11 mapper \+ 81 blank = 192 visible lines/
   or die "JANE diagnostic must use the standard big PASS\/FAIL line and small mapper line\n";
for my $source_bank (0..3) {
   my $start = index($src, "bank$source_bank void source_entry$source_bank(void)");
   $start >= 0 or die "JANE diagnostic is missing source_entry$source_bank\n";
   my $end = $source_bank < 3
      ? index($src, "bank".($source_bank+1)." void source_entry".($source_bank+1)."(void)", $start+1)
      : index($src, "void main(void)", $start+1);
   $end > $start or die "could not bound JANE source_entry$source_bank\n";
   my $body = substr($src,$start,$end-$start);
   for my $destination_bank (0..3) {
      $body =~ /call_target\Q$destination_bank\E\s*\(\s*\)/
         or die "JANE source bank $source_bank does not call destination bank $destination_bank\n";
   }
}
$src =~ /call_count\s*!=\s*16/ && $src =~ /nested_count\s*!=\s*1/
   or die "JANE diagnostic does not enforce the complete 4x4 call matrix\n";

my $pt=read_file($profile);
$pt =~ /\$signature:JANE\b/ &&
$pt =~ /cartridge\s*\{\s*\$inline_bankcall/s &&
index($pt,'VCSC_INLINE_BANKCALL') < 0 &&
$pt =~ /\$vector_bridge_offset:0x0ee0\s+\$vector_bridge_size:0x0012/ &&
$pt =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x1ff0\s+\$bankcall_descriptor:0xf0/s &&
$pt =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x1ff1\s+\$bankcall_descriptor:0xf1\s+\$startup/s &&
$pt =~ /bank\s+bank2\s*\{.*?\$file_index:2.*?\$select_access:0x1ff8\s+\$bankcall_descriptor:0xf8/s &&
$pt =~ /bank\s+bank3\s*\{.*?\$file_index:3.*?\$select_access:0x1ff9\s+\$bankcall_descriptor:0xf9/s &&
(()=$pt =~ /\$size:0x0ee0\s+\$ro/g)==4
   or die "JANE profile topology/startup/corridor contract is wrong\n";

my $ct=read_file($cfg);
$ct =~ /mapper\s*=\s*JANE/ &&
$ct =~ /BANK0:.*hotspot\s*=\s*\$1FF0.*fileindex\s*=\s*0.*startup\s*=\s*no/is &&
$ct =~ /BANK1:.*hotspot\s*=\s*\$1FF1.*fileindex\s*=\s*1.*startup\s*=\s*yes/is &&
$ct =~ /BANK2:.*hotspot\s*=\s*\$1FF8.*fileindex\s*=\s*2/is &&
$ct =~ /BANK3:.*hotspot\s*=\s*\$1FF9.*fileindex\s*=\s*3/is
   or die "JANE simulator cfg physical file-index contract is wrong\n";

my $bin=File::Spec->catfile($tmp,'jane.bin');
my $map=File::Spec->catfile($tmp,'jane.map');
require_ok('build JANE simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST',
   '-T',$generic,'-Map',$map,$source,'-o',$bin);
-s $bin==16384 or die "JANE output size is not 16K\n";
my $rom=read_file($bin);
substr($rom,3*4096+0x0ff8,4) eq 'JANE'
   or die "JANE signature is missing from the final physical bank\n";
for my $file_bank (0..2) {
   substr($rom,$file_bank*4096+0x0ff8,4) ne 'JANE'
      or die "JANE signature was duplicated into file bank $file_bank\n";
}
index($rom,pack('C*',0xAD,0xF1,0xFF,0x60))>=0
   or die "JANE image lost Stella's LDA \$FFF1; RTS detector signature\n";

my $m=read_file($map);
my @file_index=(0,1,2,3);
my @selector=(0x1ff0,0x1ff1,0x1ff8,0x1ff9);
for my $logical (0..3) {
   my $fi=$file_index[$logical];
   my $sel=sprintf('%04X',$selector[$logical]);
   $m =~ /^\s+bank\Q$logical\E\s+file-index=\Q$fi\E\b.*mode=selector\s+select-access=\$\Q$sel\E(?:\s+startup=yes)?/m
      or die "JANE logical bank$logical/file bank/selector mapping is wrong\n$m";
}
$m =~ /^\s+bank1\s+file-index=1\b.*startup=yes/m &&
$m =~ /^\s+bank0\s+file-index=0\b(?!.*startup=yes)/m &&
$m =~ /vector-bridge=\$0EE0\s+size=\$0012/ &&
$m =~ /generic-jsr=\$048\b.*\bentries=0\s+jmp=0\s+jsr=0\b/ &&
$m !~ /JSR entry=/ &&
$m =~ /^TRAMPOLINES$/m
   or die "JANE startup/vector bridge/trampoline map contract is wrong\n$m";
my $lst=read_file(File::Spec->catfile($tmp,'jane.lst'));
my @descriptor=(0xF0,0xF1,0xF8,0xF9);
for my $destination (0..3) {
   my $desc=sprintf('%02x',$descriptor[$destination]);
   my $count=()=$lst =~ /^\s*\d+\s+[0-9a-f]{4}\s+[0-9a-f]{2}\s+[0-9a-f]{2}\s+\Q$desc\E\s+; \.banktarget call_target\Q$destination\E\b/gmi;
   $count==3
      or die "JANE destination bank $destination descriptor payload count is $count, expected 3\n";
}
my @trampoline=map { substr($rom,$_ * 4096 + 0x0f00,0x48) } 0..3;
my @source_diff=grep {
   my $off=$_;
   my %seen=map { ord(substr($trampoline[$_],$off,1)) => 1 } 0..3;
   scalar(keys %seen)>1;
} 0..0x47;
@source_diff==1
   or die "JANE descriptor trampoline copies do not differ at exactly one source-descriptor byte\n";
for my $bank (0..3) {
   ord(substr($trampoline[$bank],$source_diff[0],1))==$descriptor[$bank]
      or die sprintf("JANE bank %d baked source descriptor is not $%02X\n",$bank,$descriptor[$bank]);
}

my $bridge=substr($rom,0x0ee0,0x12);
for my $file_bank (1..3) {
   substr($rom,$file_bank*4096+0x0ee0,0x12) eq $bridge
      or die "JANE vector bridge differs in file bank $file_bank\n";
}
for my $file_bank (1..3) {
   substr($rom,$file_bank*4096+0x0ffc,4) eq substr($rom,0x0ffc,4)
      or die "JANE RESET/IRQ vectors differ in file bank $file_bank\n";
}

my $main_addr=map_symbol($m,'main');
$main_addr >= 0xd000 && $main_addr < 0xdee0
   or die sprintf("JANE linker did not place unqualified main in startup bank1: main=\$%04X\n",$main_addr);
my %sym=map { $_=>map_symbol($m,$_) } qw(simulator_done failure signature source_seen current_source current_destination call_count nested_count stack_before stack_after);
for my $start (0..3) {
   my($out,$err)=require_ok("simulate JANE from physical bank $start",$sim,'-T',$cfg,
      "--start-bank=$start",sprintf('--stop-pc=0x%04X',$sym{simulator_done}),
      '--dump-on-stop',$bin);
   $err eq '' or die "JANE simulator start bank $start wrote stderr:\n$err";
   my $mem=parse_hex_dump($out);
   $mem->[$sym{failure}]==0
      or die sprintf("JANE self-test from physical bank %d failed: failure=\$%02X\n",$start,$mem->[$sym{failure}]);
   $mem->[$sym{call_count}]==16
      or die "JANE complete ordered call-matrix count failed from physical bank $start\n";
   $mem->[$sym{nested_count}]==1 && $mem->[$sym{source_seen}]==3 &&
   $mem->[$sym{current_source}]==3 && $mem->[$sym{current_destination}]==3 &&
   $mem->[$sym{signature}]==0x43 && $mem->[$sym{stack_before}]==$mem->[$sym{stack_after}]
      or die "JANE ordered call-matrix state failed from physical bank $start\n";
}

my $visible=File::Spec->catfile($tmp,'jane-visible.bin');
my(undef,$visible_err)=require_ok('build visible JANE PASS/FAIL cartridge',$driver,'-I',$vcs,'-T',$generic,$source,'-o',$visible);
$visible_err !~ /status_result_color|recommended variable/
   or die "visible JANE diagnostic emitted an unused recommendation warning\n$visible_err";
my $vrom=read_file($visible);
length($vrom)==16384 && substr($vrom,3*4096+0x0ff8,4) eq 'JANE' &&
index($vrom,pack('C*',0xAD,0xF1,0xFF,0x60))>=0
   or die "visible JANE diagnostic lost its layout/signatures\n";

my $s26=File::Spec->catfile($tmp,'jane-visible.s26');
require_ok('disassemble JANE cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: JANE \(high confidence;/m &&
$dis =~ /^; reset\/power-on bank: 1 \(JANE hardware default\)$/m &&
$dis =~ /^; JANE selectors: \$1FF0->\$0, \$1FF1->\$1, \$1FF8->\$2, \$1FF9->\$3; bank 1 powers up$/m
   or die "vcsc-disas did not recognize JANE physical-bank semantics\n$dis";

my $rt_in=File::Spec->catdir($tmp,'roundtrip-in');
my $rt_out=File::Spec->catdir($tmp,'roundtrip-out');
make_path($rt_in,$rt_out);
copy($visible,File::Spec->catfile($rt_in,'jane-visible.bin'))
   or die "copy JANE roundtrip input: $!\n";
require_ok('round-trip JANE cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'jane-visible.bin')) eq $vrom
   or die "JANE disassembler round trip is not byte-exact\n";

print "JANE diagnostic passed\n";
