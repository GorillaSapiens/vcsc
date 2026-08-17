#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 4KSC diagnostic passed
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
sub read_file {
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub write_file {
   my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n";
   print {$fh} $d or die "write $p: $!\n"; close($fh) or die "close $p: $!\n";
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
my $roundtrip=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $source=File::Spec->catfile($repo,'examples','09_bankswitching','04_4ksc','4ksc_diagnostic.c26');
my $cfg=File::Spec->catfile($vcs,'vcs_4k_sc.cfg');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $profile=File::Spec->catfile($vcs,'vcs_4k_sc.c26');
my $bin=File::Spec->catfile($tmp,'4ksc.bin');
my $map=File::Spec->catfile($tmp,'4ksc.map');

my $source_text=read_file($source);
$source_text =~ /blank \/ 4 \/ K \/ S \/ C \/ blank/ &&
$source_text =~ /load_4ksc_type\(\)/ &&
$source_text =~ /cart_type_draw\(\)/
   or die "4KSC visible diagnostic lost its centered mapper line\n";

require_ok('build 4KSC simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST',
   '-T',$generic,'-Map',$map,$source,'-o',$bin);
-s $bin==4096 or die "4KSC output size is not 4096 bytes\n";
my $rom=read_file($bin);
substr($rom,0,256) eq ("\xFF" x 256)
   or die "4KSC physical image does not preserve the hidden 256-byte Superchip prefix\n";
substr($rom,0x0ff8,4) eq "4KSC"
   or die "4KSC cartridge signature is missing from \$1FF8-\$1FFB\n";
my $m=read_file($map);
$m =~ /^\s+bank0\s+file-index=0\b.*image-offset=\$0100.*mode=direct/m &&
$m !~ /^TRAMPOLINES$/m
   or die "4KSC topology is not a selector-free direct 4K image with a hidden prefix\n$m";
$m =~ /^\s+superchip\s+read_start=\$F080 write_start=\$F000 size=\$0080 type=rw shared=yes\b/m
   or die "4KSC Superchip split-address map is missing\n$m";
$m =~ /superchip\s+used=128 bytes \(100\.00%\).*free=0 bytes/m
   or die "4KSC diagnostic does not allocate all 128 Superchip bytes\n$m";

my %sym=map { $_=>map_symbol($m,$_) } qw(simulator_done failure sc_bss sc_data);
my($out,$err)=require_ok('simulate 4KSC through hostile fill and reset',$sim,'-T',$cfg,
   '--split-fill=0xA7',sprintf('--reset-on-pc=0x%04X',$sym{simulator_done}),
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$err eq '' or die "4KSC simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($out);
$mem->[$sym{failure}]==0 or die sprintf("4KSC self-test failed: failure=$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{sc_data}]==0xA5 or die "4KSC DATA byte did not survive split aliases\n";
$mem->[$sym{sc_bss}+0]==0x11 &&
$mem->[$sym{sc_bss}+63]==0x22 &&
$mem->[$sym{sc_bss}+126]==0x33
   or die "4KSC BSS sentinels did not survive split aliases\n";

# Ordinary ROM may not be placed inside the Superchip port prefix.
my $overlay=File::Spec->catfile($tmp,'overlay.c26');
write_file($overlay,qq{include "vcs_4k_sc.c26"\nmem hidden_rom { \$start:0xF080 \$size:0x0010 \$ro };\nhidden_rom const uint8_t illegal := 0x42;\nvoid main(void) { while (1) { } }\n});
my($rrc,$rsig,$rout,$rerr)=run_capture($driver,'-I',$vcs,'-T',$generic,$overlay,'-o',File::Spec->catfile($tmp,'overlay.bin'));
$rrc!=0 && !$rsig && $rerr =~ /outside every mapped ROM window/i
   or die "4KSC RAM-overlay ROM placement did not fail clearly\nstdout:\n$rout\nstderr:\n$rerr";

# The public visible image must identify as 4KSC, retain stable NTSC timing,
# and round-trip exactly through the disassembler/assembler pair.
my $visible=File::Spec->catfile($tmp,'4ksc-visible.bin');
require_ok('build visible 4KSC PASS/FAIL cartridge',$driver,'-I',$vcs,'-T',$generic,$source,'-o',$visible);
my($s26,$derr)=require_ok('probe visible 4KSC cartridge',$disas,'-o','-',$visible);
$derr eq '' or die "vcsc-disas wrote stderr for 4KSC visible cartridge:\n$derr";
$s26 =~ /^; mapper: 4KSC \(high confidence;/m
   or die "4KSC visible diagnostic was not recognized as 4KSC\n$s26";
$s26 =~ /^; video: NTSC \(dynamic stable frame measurement: 264 raw line intervals\) \(high confidence\)$/m
   or die "4KSC visible diagnostic lost stable NTSC timing\n$s26";
my $indir=File::Spec->catdir($tmp,'roundtrip-in');
my $outdir=File::Spec->catdir($tmp,'roundtrip-out');
make_path($indir,$outdir);
write_file(File::Spec->catfile($indir,'4ksc.bin'),read_file($visible));
my($rtout,$rterr)=require_ok('round-trip 4KSC diagnostic','perl',$roundtrip,$indir,$outdir);
$rterr eq '' or die "4KSC roundtrip verifier wrote stderr:\n$rterr";
$rtout =~ /PASS 4ksc\.bin/ or die "4KSC roundtrip verifier did not report PASS\n$rtout";

print "4KSC diagnostic passed\n";
