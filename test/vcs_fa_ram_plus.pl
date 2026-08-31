#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: FA RAM Plus diagnostic passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
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
sub write_file {
   my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n"; print {$fh} $d or die "write $p: $!\n"; close($fh) or die "close $p: $!\n";
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
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $disas=File::Spec->catfile($repo,'disassembler','vcsc-disas');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $source=File::Spec->catfile($repo,'examples','09_bankswitching','03_fa_ram_plus','fa_ram_plus_diagnostic.c26');
my $source_text=read_file($source);
$source_text =~ /instantiate "six_glyph_component\.c26" as cart_type/ &&
$source_text =~ /blank \/ blank \/ F \/ A \/ blank \/ blank/ &&
$source_text =~ /cart_type_draw\(\)/
   or die "FA visible diagnostic lost its centered FA mapper line\n";
my $cfg=File::Spec->catfile($vcs,'vcs_12k_fa.cfg');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $bin=File::Spec->catfile($tmp,'fa.bin');
my $map=File::Spec->catfile($tmp,'fa.map');

require_ok('build FA simulator diagnostic',$driver,'-I',$vcs,'-DVCSC_INLINE_BANKCALL=1','-DSIMULATOR_TEST',
   '-T',$generic,'-Map',$map,$source,'-o',$bin);
-s $bin==12288 or die "FA output size is not 12288 bytes\n";
my $rom=read_file($bin);
my $m=read_file($map);
for my $chunk (0..2) {
   substr($rom,$chunk*4096,512) eq ("\xFF" x 512)
      or die "FA physical bank $chunk does not preserve the hidden 512-byte RAM-port prefix\n";
}
$m =~ /^\s+bank2\s+file-index=0\b.*select-access=\$1FF8/m &&
$m =~ /^\s+bank1\s+file-index=1\b.*select-access=\$1FF9/m &&
$m =~ /^\s+bank0\s+file-index=2\b.*select-access=\$1FFA.*startup=yes/m
   or die "FA topology does not report physical selector order/startup bank\n$m";
$m =~ /^\s+cartram\s+read_start=\$F100 write_start=\$F000 size=\$0100 type=rw shared=yes\b/m
   or die "FA RAM split-address map is missing\n$m";
$m =~ /used=256 bytes \(100\.00%\).*free=0 bytes/m
   or die "FA diagnostic does not allocate all 256 cartridge-RAM bytes\n$m";
$m =~ /generic-jsr=\$050\b.*\bentries=0\s+jmp=0\s+jsr=0\b/ &&
$m !~ /JSR entry=/
   or die "FA diagnostic did not use only the fixed generic JSR block\n$m";

# Every physical bank carries the same reset bridge and the real RESET/IRQ
# vectors.  The final bank deliberately replaces the unused NMI-vector bytes
# with the NUL-padded mapper signature at $xFF8-$xFFB.
for my $chunk (1..2) {
   substr($rom,$chunk*4096+0xFE0,0x12) eq substr($rom,0xFE0,0x12)
      or die "FA vector bridge differs in physical bank $chunk\n";
   substr($rom,$chunk*4096+0xFFC,4) eq substr($rom,0xFFC,4)
      or die "FA RESET/IRQ vectors differ in physical bank $chunk\n";
}
substr($rom,2*4096+0xFF8,4) eq "FA\0\0"
   or die "FA final-bank signature is missing\n";

my %sym=map { $_=>map_symbol($m,$_) } qw(simulator_done failure trace ram_count fa_bss fa_data);
for my $start (0..2) {
   my($out,$err)=require_ok("simulate FA from physical bank $start",$sim,'-T',$cfg,
      "--start-bank=$start",sprintf('--stop-pc=0x%04X',$sym{simulator_done}),
      '--dump-on-stop',$bin);
   $err eq '' or die "FA simulator wrote stderr from bank $start:\n$err";
   my $mem=parse_hex_dump($out);
   $mem->[$sym{failure}]==0 or die sprintf("FA self-test failed from bank %d: failure=$%02X\n",$start,$mem->[$sym{failure}]);
   $mem->[$sym{trace}]==63 && $mem->[$sym{ram_count}]==6
      or die "FA exhaustive cross-bank trace/counter failed from bank $start\n";
   $mem->[$sym{fa_data}]==0xA5 or die "FA DATA byte did not persist from bank $start\n";
   $mem->[$sym{fa_bss}+0]==0x11 &&
   $mem->[$sym{fa_bss}+127]==0x22 &&
   $mem->[$sym{fa_bss}+254]==0x33
      or die "FA BSS sentinels did not persist from bank $start\n";
}


# FA banks expose only $x200-$xEFF to ordinary ROM allocation. Diagnose both
# capacity overflow and an explicit attempt to create ROM inside the RAM ports.
my $overflow=File::Spec->catfile($tmp,'overflow.c26');
write_file($overflow,qq{include "vcs_12k_fa.c26"
bank0 const uint8_t too_big[3400] := { 0 };
void main(void) { while (1) { } }
});
my($orc,$osig,$oout,$oerr)=run_capture($driver,'-I',$vcs,'-T',$generic,$overflow,'-o',File::Spec->catfile($tmp,'overflow.bin'));
$orc!=0 && !$osig && $oerr =~ /(?:overflow|does not fit|capacity|placement)/i
   or die "FA bank overflow did not fail clearly\nstdout:\n$oout\nstderr:\n$oerr";

my $overlay=File::Spec->catfile($tmp,'overlay.c26');
write_file($overlay,qq{include "vcs_12k_fa.c26"
mem hidden_rom { \$start:0xF180 \$size:0x0010 \$ro };
hidden_rom const uint8_t illegal := 0x42;
void main(void) { while (1) { } }
});
my($rrc,$rsig,$rout,$rerr)=run_capture($driver,'-I',$vcs,'-T',$generic,$overlay,'-o',File::Spec->catfile($tmp,'overlay.bin'));
$rrc!=0 && !$rsig && $rerr =~ /outside every mapped ROM window/i
   or die "FA RAM-overlay ROM placement did not fail clearly\nstdout:\n$rout\nstderr:\n$rerr";

my $badbank=File::Spec->catfile($tmp,'badbank.c26');
write_file($badbank,qq{include "vcs_12k_fa.c26"
bank3 const uint8_t illegal := 0x42;
void main(void) { while (1) { } }
});
my($brc,$bsig,$bout,$berr)=run_capture($driver,'-I',$vcs,'-T',$generic,$badbank,'-o',File::Spec->catfile($tmp,'badbank.bin'));
$brc!=0 && !$bsig
   or die "FA invalid bank reference unexpectedly succeeded\nstdout:\n$bout\nstderr:\n$berr";

# The normal visible cartridge must retain stable NTSC frame timing according to
# the disassembler's bounded dynamic TIA/RIOT probe.
my $visible=File::Spec->catfile($tmp,'fa-visible.bin');
require_ok('build visible FA PASS/FAIL cartridge',$driver,'-I',$vcs,'-DVCSC_INLINE_BANKCALL=1','-T',$generic,$source,'-o',$visible);
my($s26,$derr)=require_ok('probe visible FA cartridge',$disas,'-o','-',$visible);
$derr eq '' or die "vcsc-disas wrote stderr for FA visible cartridge:\n$derr";
$s26 =~ /^; video: NTSC \(dynamic stable frame measurement: 264 raw line intervals\) \(high confidence\)$/m
   or die "FA visible diagnostic did not retain stable 264-interval raw / 262-line displayed NTSC timing\n$s26";

print "FA RAM Plus diagnostic passed\n";
