#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 0840 diagnostic passed
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
sub write_file {
   my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n";
   print {$fh} $d; close($fh) or die "close $p: $!\n";
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
my $profile=File::Spec->catfile($vcs,'0840/mapper.c26');
my $source=File::Spec->catfile($repo,'examples','09_bankswitching','08_0840','econobanking_diagnostic.c26');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','08_0840');
my $example_make=File::Spec->catfile($example_dir,'Makefile');

my $mk=read_file($example_make);
$mk =~ /^play:\s*\$\(TARGET\)\s*$/m &&
$mk =~ /^\s*stella\s+-bs\s+0840\s+\$\(TARGET\)\s*$/m
   or die "0840 play target must force Stella -bs 0840\n";
my $pt=read_file($profile);
$pt =~ /cartridge\s*\{\s*\$bankcall/s &&
index($pt,'VCSC_INLINE_BANKCALL') < 0 &&
$pt =~ /\$signature:0840\b/ &&
$pt =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x0800\s+\$bankcall_descriptor:0x00\s+\$startup/s &&
$pt =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x0840\s+\$bankcall_descriptor:0x40/s &&
$pt =~ /\$vector_bridge_offset:0x0fe0\s+\$vector_bridge_size:0x0012/
   or die "0840 profile topology/startup contract is wrong\n";
my $src_text=read_file($source);
for my $source_bank (0..1) {
   $src_text =~ /bank\Q$source_bank\E\s+void\s+source_entry\Q$source_bank\E\s*\(void\)\s*\{(.*?)^\}/ms
      or die "0840 diagnostic lacks source_entry$source_bank\n";
   my $body=$1;
   for my $dest (0..1) {
      $body =~ /call_target\Q$dest\E\s*\(\)/
         or die "0840 diagnostic source $source_bank does not call destination $dest\n";
   }
}


my $bin=File::Spec->catfile($tmp,'0840.bin');
my $map=File::Spec->catfile($tmp,'0840.map');
require_ok('build 0840 simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST','-Map',$map,$source,'-o',$bin);
-s $bin==8192 or die "0840 output size is not 8K\n";
my $rom=read_file($bin);
substr($rom,4096+0x0ff8,4) eq '0840'
   or die "0840 signature is missing from final physical bank\n";
substr($rom,0x0ff8,4) ne '0840'
   or die "0840 signature was duplicated into file bank 0\n";

# Every reset/vector bridge entry uses the undocumented NMOS absolute NOP read
# of $0800 followed by JMP.  The bridge is identical in both physical banks.
my $bridge=substr($rom,0x0fe0,0x12);
substr($rom,4096+0x0fe0,0x12) eq $bridge
   or die "0840 vector bridge differs between physical banks\n";
for my $off (0,6,12) {
   substr($bridge,$off,4) eq pack('C*',0x0c,0x00,0x08,0x4c)
      or die "0840 vector bridge does not use NOP-read \$0800; JMP\n";
}
# The fixed descriptor-aware inline call block performs indexed reads from
# $0800,Y. The two bank copies may differ only at the baked source descriptor.
# Destination descriptor bytes come directly from .banktarget payloads.
my $lst=read_file(File::Spec->catfile($tmp,'0840.lst'));
my @descriptor=(0x00,0x40);
for my $destination (0..1) {
   my $desc=sprintf('%02x',$descriptor[$destination]);
   my $count=()=$lst =~ /^\s*\d+\s+[0-9a-f]{4}\s+[0-9a-f]{2}\s+[0-9a-f]{2}\s+\Q$desc\E\s+; \.banktarget call_target\Q$destination\E\b/gmi;
   $count==1
      or die "0840 destination bank $destination descriptor payload count is $count, expected 1\n";
}
my @trampoline=map { substr($rom,$_ * 4096 + 0x0f00,0x48) } 0..1;
my @source_diff=grep {
   my $off=$_;
   ord(substr($trampoline[0],$off,1)) != ord(substr($trampoline[1],$off,1));
} 0..0x47;
@source_diff==1
   or die "0840 descriptor trampoline copies do not differ at exactly one source-descriptor byte\n";
for my $bank (0..1) {
   ord(substr($trampoline[$bank],$source_diff[0],1))==$descriptor[$bank]
      or die sprintf("0840 bank %d baked source descriptor is not $%02X\n",$bank,$descriptor[$bank]);
   (()=$trampoline[$bank] =~ /\x1C\x00\x08/sg)>=2 &&
   index($trampoline[$bank],pack('C*',0x8d,0x00,0x08))<0 &&
   index($trampoline[$bank],pack('C*',0x8d,0x40,0x08))<0
      or die "0840 inline bank-call block does not use read-only indexed selectors\n";
}

my $m=read_file($map);
$m =~ /^\s+bank0\s+file-index=0\b.*mode=selector\s+select-access=\$0800\s+startup=yes/m &&
$m =~ /^\s+bank1\s+file-index=1\b.*mode=selector\s+select-access=\$0840/m &&
$m =~ /vector-bridge=\$0FE0\s+size=\$0012/ &&
$m =~ /^TRAMPOLINES$/m &&
$m =~ /generic-jsr=\$048\b.*\bentries=0\s+jmp=0\s+jsr=0\b/ &&
$m !~ /JSR entry=/
   or die "0840 map topology/trampoline contract is wrong\n$m";
my %sym=map { $_=>map_symbol($m,$_) } qw(simulator_done failure call_count nested_count);
for my $start (0..1) {
   my($out,$err)=require_ok("simulate 0840 from physical bank $start",$sim,'--map',$map,
      "--start-bank=$start",sprintf('--stop-pc=0x%04X',$sym{simulator_done}),
      '--dump-on-stop',$bin);
   $err eq '' or die "0840 simulator start bank $start wrote stderr:\n$err";
   my $mem=parse_hex_dump($out);
   $mem->[$sym{failure}]==0
      or die sprintf("0840 self-test from bank %d failed: failure=\$%02X\n",$start,$mem->[$sym{failure}]);
   $mem->[$sym{call_count}]==4 && $mem->[$sym{nested_count}]==1
      or die "0840 ordered call matrix/nested return check failed from physical bank $start\n";
}

# Explicitly certify write-trigger semantics.  A write to $0840 both selects
# bank 1 and reaches the underlying console memory model; bank 1 then reads the
# same byte back and publishes it in RIOT RAM.
my $write_bin=File::Spec->catfile($tmp,'0840-write.bin');
my $w=("\xFF" x 8192);
substr($w,0,8)=pack('C*',0xA9,0x5A,0x8D,0x40,0x08,0xEA,0xEA,0xEA);
substr($w,4096+5,9)=pack('C*',0xAD,0x40,0x08,0x8D,0x80,0x00,0x4C,0x0E,0xF0);
for my $fb (0..1) { substr($w,$fb*4096+0x0ffc,2)=pack('C*',0x00,0xF0); }
write_file($write_bin,$w);
my($wout,$werr)=require_ok('simulate 0840 write selector',$sim,'--map',$map,
   '--start-bank=0','--stop-pc=0xF00E','--dump-on-stop',$write_bin);
$werr eq '' or die "0840 write-selector simulator wrote stderr:\n$werr";
my $wmem=parse_hex_dump($wout);
$wmem->[0x0080]==0x5A && $wmem->[0x0840]==0x5A
   or die "0840 write did not both switch bank and reach underlying memory\n";

my $visible=File::Spec->catfile($tmp,'0840-visible.bin');
require_ok('build visible 0840 PASS/FAIL cartridge',$driver,'-I',$vcs,$source,'-o',$visible);
my $vrom=read_file($visible);
length($vrom)==8192 && substr($vrom,4096+0x0ff8,4) eq '0840' &&
(()=$vrom =~ /\x0c\x00\x08\x4c/sg)>=2
   or die "visible 0840 diagnostic lost its layout/detector pattern\n";

my $s26=File::Spec->catfile($tmp,'0840-visible.s26');
require_ok('disassemble 0840 cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: 0840 \(high confidence;/m &&
$dis =~ /^; reset\/power-on bank: 0 \(0840 hardware default\)$/m &&
$dis =~ /^; 0840 selectors: below-window accesses with A11=1 use A6 \(\$0800->\$0, \$0840->\$1\); bank 0 powers up$/m
   or die "vcsc-disas did not recognize 0840 semantics\n$dis";

my $rt_in=File::Spec->catdir($tmp,'roundtrip-in');
my $rt_out=File::Spec->catdir($tmp,'roundtrip-out');
make_path($rt_in,$rt_out);
copy($visible,File::Spec->catfile($rt_in,'0840-visible.bin'))
   or die "copy 0840 roundtrip input: $!\n";
require_ok('round-trip 0840 cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'0840-visible.bin')) eq $vrom
   or die "0840 disassembler round trip is not byte-exact\n";

print "0840 diagnostic passed\n";
