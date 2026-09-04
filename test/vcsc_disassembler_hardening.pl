#!/usr/bin/env perl
# runner: perl @TEST_ROOT@/vcsc_disassembler_hardening.pl @REPO@ @TMP@
# phase: e2e
# expectstdout: vcsc-disassembler hardening ok

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

my ($repo,$tmp)=@ARGV;
die "usage: $0 REPO TMP\n" if @ARGV != 2;
$repo=abs_path($repo) // die "resolve repo\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve tmp\n";

my $disas=File::Spec->catfile($repo,'disassembler','vcsc-disas');
my $roundtrip=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
-x $disas or die "missing $disas\n";
-f $roundtrip or die "missing $roundtrip\n";

sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $d=<$fh>; close($fh);
   return defined($d)?$d:'';
}
sub write_raw {
   my($path,$data)=@_;
   open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $data or die "write $path: $!\n";
   close($fh) or die "close $path: $!\n";
}
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   local $/; my $so=<$out>; my $se=<$err>;
   $so='' if !defined($so); $se='' if !defined($se);
   waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub expect_clean_failure {
   my($input,$out)=@_;
   unlink($out);
   my($rc,$sig,$so,$se)=capture($disas,'-o',$out,$input);
   $rc != 0 or die "$input unexpectedly disassembled successfully\n";
   $sig == 0 or die "$input crashed vcsc-disas with signal $sig\n";
   !-e $out or die "$input left output after failure\n";
   length($se) or die "$input failed without a diagnostic\n";
}

# Minimal valid 4K cartridge.  The exact program is deliberately boring; these
# cases are about container/layout hardening rather than semantic inference.
my $base = chr(0xea) x 4096;
substr($base,0,6)=pack('C*',0xa9,0x42,0x85,0x09,0x60,0xea); # LDA #$42; STA $09; RTS
substr($base,4090,6)=pack('v3',0xf000,0xf000,0xf000);

my $corpus=File::Spec->catdir($tmp,'corpus');
my $rebuilt=File::Spec->catdir($tmp,'rebuilt');
make_path($corpus);
write_raw(File::Spec->catfile($corpus,'space name.bin'),$base);
write_raw(File::Spec->catfile($corpus,q{odd'[]$ name.BIN}),$base);
write_raw(File::Spec->catfile($corpus,'duplicated-8k.bin'),$base.$base);
write_raw(File::Spec->catfile($corpus,'leading-pad-8k.bin'),chr(0xff)x4096 . $base);
write_raw(File::Spec->catfile($corpus,'duplicated-16k.bin'),$base x 4);
write_raw(File::Spec->catfile($corpus,'leading-pad-32k.bin'),chr(0xff)x(4096*7) . $base);

my($rrc,$rsig,$rout,$rerr)=capture($^X,$roundtrip,$corpus,$rebuilt);
$rrc==0 && $rsig==0 or die "hardening round-trip corpus failed\nstdout:\n$rout\nstderr:\n$rerr";
$rerr eq '' or die "hardening round-trip corpus wrote stderr:\n$rerr";
$rout =~ /Summary:\s+6 passed, 0 failed, 6 total\n\z/
   or die "unexpected hardening round-trip summary:\n$rout";

# Optional Stella differential mode is self-contained in the normal suite:
# emulate `stella -rominfo` so parser/normalization behavior is pinned without
# requiring the external emulator.  In particular vcsc-disas spells a plain
# 4K mapper "unbanked 4K" while Stella reports "4K* (4K)".
my $fake_stella=File::Spec->catfile($tmp,'fake-stella.pl');
write_raw($fake_stella,<<'FAKE_STELLA');
#!/usr/bin/env perl
use strict;
use warnings;
use Digest::MD5 qw(md5_hex);
@ARGV == 2 && $ARGV[0] eq '-rominfo' or die "usage: fake-stella -rominfo ROM\n";
open(my $fh,'<:raw',$ARGV[1]) or die "$ARGV[1]: $!\n";
local $/; my $rom=<$fh>; close($fh);
my $size=length($rom);
if ($ARGV[1] =~ /multicart4\.bin\z/) {
   my $slice_size = int($size / 4);
   my $selected = substr($rom, $slice_size, $slice_size);
   print "  Cart MD5:        ",md5_hex($selected),"\n";
   print "  Bankswitch Type: 4IN1 [G2] (2K)\n";
} else {
   print "  Cart MD5:        ",md5_hex($rom),"\n";
   print "  Bankswitch Type: ",($size == 1024 ? "2K* (1K)" : "4K* (4K)"),"\n";
}
FAKE_STELLA
chmod(0755,$fake_stella) or die "chmod $fake_stella: $!\n";
my $stella_in=File::Spec->catdir($tmp,'stella-compare-in');
my $stella_out=File::Spec->catdir($tmp,'stella-compare-out');
make_path($stella_in,$stella_out);
write_raw(File::Spec->catfile($stella_in,'plain4k.bin'),$base);
my $one_k=chr(0xEA)x1024;
substr($one_k,0x3fa,6,pack('v3',0xFC80,0xFC80,0xFC80));
write_raw(File::Spec->catfile($stella_in,'plain1k.bin'),$one_k);
my $multi4 = '';
for my $game (0 .. 3) {
   my $part = chr(0xEA) x 2048;
   substr($part,0,5,pack('C*',0xA9,0x40+$game,0x85,0x80+$game,0x60));
   substr($part,2042,6,pack('v3',0xF800,0xF800,0xF800));
   $multi4 .= $part;
}
write_raw(File::Spec->catfile($stella_in,'multicart4.bin'),$multi4);
my($srcmp,$sscmp,$socmp,$secmp)=capture($^X,$roundtrip,'--stella',$fake_stella,$stella_in,$stella_out);
$srcmp==0 && $sscmp==0 or die "Stella mapper comparison failed\nstdout:\n$socmp\nstderr:\n$secmp";
$secmp eq '' or die "Stella mapper comparison wrote stderr:\n$secmp";
$socmp =~ /plain4k\.bin: mapper vcsc=4K stella=4K MATCH\n/
   or die "Stella mapper comparison lost normalized 4K mapper match:\n$socmp";
$socmp =~ /plain1k\.bin: mapper vcsc=1K stella=1K MATCH\n/
   or die "Stella mapper comparison treated Stella 2K* (1K) as a mismatch:\n$socmp";
$socmp =~ /multicart4\.bin: mapper vcsc=4IN1 stella=4IN1 MATCH\n/
   or die "Stella selected-slice multicart MD5 was not normalized:\n$socmp";
$socmp =~ /Stella mapper comparison: 3 match(?:es)?, 0 mismatch, 0 errors, 3 compared\n\z/
   or die "unexpected Stella mapper comparison summary:\n$socmp";

# A disagreement is diagnostic by default, but --stella-strict promotes it to
# failure for callers that intentionally want a zero-difference gate.
my $fake_wrong=File::Spec->catfile($tmp,'fake-stella-wrong.pl');
my $wrong=slurp($fake_stella);
$wrong =~ s/"4K\* \(4K\)"/"F8* (F8)"/
   or die "could not construct mismatching fake Stella\n";
write_raw($fake_wrong,$wrong);
chmod(0755,$fake_wrong) or die "chmod $fake_wrong: $!\n";
my $stella_wrong_in=File::Spec->catdir($tmp,'stella-wrong-in');
my $stella_wrong_out=File::Spec->catdir($tmp,'stella-wrong-out');
make_path($stella_wrong_in,$stella_wrong_out);
write_raw(File::Spec->catfile($stella_wrong_in,'plain4k.bin'),$base);
my($mrc,$msig,$mout,$merr)=capture($^X,$roundtrip,'--stella',$fake_wrong,$stella_wrong_in,$stella_wrong_out);
$mrc==0 && $msig==0 or die "non-strict Stella mismatch unexpectedly failed\n$mout$merr";
$mout =~ /mapper vcsc=4K stella=F8 MISMATCH\n/ or die "missing Stella mismatch report\n$mout";
my($xrc,$xsig,$xout,$xerr)=capture($^X,$roundtrip,'--stella',$fake_wrong,'--stella-strict',$stella_wrong_in,$stella_wrong_out);
$xrc!=0 && $xsig==0 or die "strict Stella mismatch did not fail\n$xout$xerr";

# Determinism is source determinism, not merely binary round trip.  The same
# input and executable must produce byte-identical .s26 text on repeated runs.
my $det_in=File::Spec->catfile($corpus,'duplicated-16k.bin');
my $det_a=File::Spec->catfile($tmp,'deterministic-a.s26');
my $det_b=File::Spec->catfile($tmp,'deterministic-b.s26');
my($arc,$asig,$aso,$ase)=capture($disas,'-o',$det_a,$det_in);
my($brc,$bsig,$bso,$bse)=capture($disas,'-o',$det_b,$det_in);
$arc==0 && !$asig && $brc==0 && !$bsig
   or die "deterministic disassembly command failed\n$ase$bse";
slurp($det_a) eq slurp($det_b) or die "vcsc-disas output is nondeterministic\n";

# Sizes adjacent to supported layouts are malformed/truncated cartridge dumps.
# They must fail cleanly without signals or stale output artifacts.
my @bad_sizes=(1,17,257,2047,2049,4095,4097,8191,8193,10494,10496,
               12287,12289,16383,16385,32767,32769,65535,65537);
my $state=0x160826;
sub fuzz_byte {
   $state=(1103515245*$state+12345)&0x7fffffff;
   return ($state>>7)&0xff;
}
for my $size (@bad_sizes) {
   my $data=''; $data.=chr(fuzz_byte()) for 1..$size;
   my $path=File::Spec->catfile($tmp,"malformed-$size.bin");
   my $out=File::Spec->catfile($tmp,"malformed-$size.s26");
   write_raw($path,$data);
   expect_clean_failure($path,$out);
}

# A structurally supported size is still not a successful disassembly when no
# instruction exists.  Pin this for every currently size-selected mapper class,
# including the WDSW bad-dump and DPC layouts.
for my $size (2048,4096,8192,8195,10495,12288,16384,32768,65536) {
   my $path=File::Spec->catfile($tmp,"all-kil-$size.bin");
   my $out=File::Spec->catfile($tmp,"all-kil-$size.s26");
   write_raw($path,chr(0x02)x$size);
   expect_clean_failure($path,$out);
}

# roundtrip.pl must not mistake files left by an earlier run for success.
my $bad_in=File::Spec->catdir($tmp,'stale-in');
my $bad_out=File::Spec->catdir($tmp,'stale-out');
make_path($bad_in,$bad_out);
write_raw(File::Spec->catfile($bad_in,'stale.bin'),chr(0x02)x4096);
write_raw(File::Spec->catfile($bad_out,'stale.bin'),'old reconstructed ROM');
write_raw(File::Spec->catfile($bad_out,'stale.s26'),'old generated source');
my($src,$ssig,$sso,$sse)=capture($^X,$roundtrip,$bad_in,$bad_out);
$src != 0 && $ssig==0 or die "stale-output roundtrip unexpectedly succeeded/crashed\n";
!-e File::Spec->catfile($bad_out,'stale.bin') or die "stale rebuilt ROM survived failed roundtrip\n";
!-e File::Spec->catfile($bad_out,'stale.s26') or die "stale .s26 survived failed roundtrip\n";

# Directory aliasing is rejected even when the second spelling is a symlink.
my $empty=File::Spec->catdir($tmp,'empty');
make_path($empty);
my $alias=File::Spec->catfile($tmp,'alias-to-empty');
symlink($empty,$alias) or die "symlink $alias: $!\n";
my($erc,$esig)=capture($^X,$roundtrip,$empty,$alias);
$erc != 0 && $esig==0 or die "roundtrip accepted aliased input/output directories\n";

# Keep the pre-existing tagger side tool independently buildable and preserve a
# tiny functional baseline.  Build in TMP so the E2E does not mutate the source
# tree or race another worker.
my $tagger_src=File::Spec->catfile($repo,'tagger','tagger.c');
my $tagger=File::Spec->catfile($tmp,'tagger-smoke');
my $cc=$ENV{CC} || 'cc';
my($crc,$csig,$cso,$cse)=capture($cc,'-std=c11','-Wall','-Wextra','-Werror','-pedantic','-O2',$tagger_src,'-o',$tagger);
$crc==0 && !$csig or die "tagger standalone build failed\n$cso$cse";
my $tagger_rom=chr(0xea)x2048;
substr($tagger_rom,0,3)=pack('C*',0xa9,0x42,0x60);
substr($tagger_rom,2042,6)=pack('v3',0xf800,0xf800,0xf800);
my $tagger_bin=File::Spec->catfile($tmp,'tagger.bin');
write_raw($tagger_bin,$tagger_rom);
my($trc,$tsig,$tout,$terr)=capture($tagger,$tagger_bin);
$trc==0 && !$tsig or die "tagger smoke run failed\n$tout$terr";
$tout =~ /^size=2048$/m or die "tagger smoke lost size report\n";
$tout =~ /^bank_size=2048$/m or die "tagger smoke lost 2K handling\n";
$tout =~ /^bank=0 reset_vector=\$f800 valid=yes$/m or die "tagger smoke lost reset-vector tracing\n";
$tout =~ /^total_reachable_instruction_starts=[1-9][0-9]*$/m
   or die "tagger smoke found no reachable instructions\n";

print "vcsc-disassembler hardening ok\n";
