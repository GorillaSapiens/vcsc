#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: FA2 diagnostic passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub capture { my(@cmd)=@_; my $e=gensym; my $p=open3(my $i,my $o,$e,@cmd); close $i; my $so=slurp_fh($o); my $se=slurp_fh($e); waitpid($p,0); return ($? >> 8,$? & 127,$so,$se); }
sub ok { my($label,@cmd)=@_; my($r,$s,$o,$e)=capture(@cmd); $r==0 && !$s or die "$label failed rc=$r sig=$s\n@cmd\nstdout:\n$o\nstderr:\n$e"; return ($o,$e); }
sub find_executable { my($n)=@_; return abs_path($n) if $n =~ m{/} && -x $n; for my $d (split /:/,$ENV{PATH}//''){ my $p=File::Spec->catfile($d,$n); return abs_path($p) if -x $p; } return undef; }
sub terminate_child { my($p)=@_; return unless $p; kill 'TERM',$p; for(1..20){my$d=waitpid($p,WNOHANG); return if $d==$p || $d==-1; select undef,undef,undef,.05;} kill 'KILL',$p; waitpid($p,0); }
sub readf { my($p)=@_; open my $f,'<:raw',$p or die "read $p: $!\n"; local $/; my $d=<$f>; close $f; return $d // ''; }
sub sym { my($m,$n)=@_; $m =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$n\E\b/m or die "map missing $n\n"; return hex $1; }
sub hexmem { my($t)=@_; my @m=(0)x65536; for(split /\n/,$t){ next unless /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)[0-9A-Fa-f]{2}$/; my($n,$a,$d)=(hex($1),hex($2),$3); for my $i(0..$n-1){$m[$a+$i]=hex substr($d,$i*2,2)} } return \@m; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP [--stella]\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP [--stella]\n";
my $stella_mode=@ARGV && $ARGV[0] eq "--stella" ? shift(@ARGV) : ""; @ARGV and die "usage: $0 REPO TMP [--stella]\n"; make_path($tmp);
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $disas=File::Spec->catfile($repo,'disassembler','vcsc-disas');
my $round=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
my $src=File::Spec->catfile($repo,'examples','09_bankswitching','17_fa2','fa2_diagnostic.c26');
my $diag_source=readf($src);
for my $source (0..6) {
   $diag_source =~ /bank\Q$source\E void bank\Q$source\E_source\(void\) \{(.*?)^\}/ms
      or die "public FA2 diagnostic missing bank${source}_source\n";
   my $body=$1;
   for my $destination (0..6) {
      $body =~ /bank\Q$destination\E_probe\(\)/
         or die "public FA2 diagnostic source matrix incomplete at $source->$destination\n";
   }
}
my $cfg=File::Spec->catfile($vcs,'FA2/mapper_28k.cfg');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $bin=File::Spec->catfile($tmp,'fa2.bin');
my $map=File::Spec->catfile($tmp,'fa2.map');

ok('build FA2 simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST','-T',$generic,'-Map',$map,$src,'-o',$bin);
-s $bin==28672 or die "FA2 28K image size wrong\n";
my $rom=readf($bin); my $m=readf($map);
my $lst=readf(File::Spec->catfile($tmp,'fa2.lst'));
for my $destination (0..6) {
   my $jsr_count = () = $lst =~ /; JSR bank\Q$destination\E_probe\b/g;
   my $banktarget_count = () = $lst =~ /; \.banktarget bank\Q$destination\E_probe\b/g;
   $jsr_count == 7 or die "FA2 28K destination bank $destination is not called once from every source bank\n";
   $banktarget_count == 6 or die "FA2 28K destination bank $destination does not have exactly six cross-bank descriptor calls\n";
}
for my $b (0..6) { substr($rom,$b*4096,512) eq ("\xFF" x 512) or die "FA2 bank $b RAM-port prefix exposed\n"; }
for my $b (0..6) {
   my $hot=sprintf('%04X',0x1ff5+$b);
   $m =~ /^\s+bank\Q$b\E\s+file-index=\Q$b\E\b.*select-access=\$$hot/m or die "FA2 bank $b selector/file order wrong\n";
}
$m =~ /^\s+bank0\s+.*startup=yes/m or die "FA2 bank0 is not startup bank\n";
$m =~ /^\s+cartram\s+read_start=\$F100 write_start=\$F000 size=\$0100 type=rw shared=yes\b/m or die "FA2 RAM map missing\n";
$m =~ /cartram\s+used=256 bytes \(100\.00%\).*free=0 bytes/m or die "FA2 diagnostic does not occupy all cart RAM\n";
$m =~ /generic-jsr=\$048\b.*\bentries=0\s+jmp=0\s+jsr=0\b/ && $m !~ /JSR entry=/
   or die "FA2 28K diagnostic did not use only the mapper-specific inline bank-call block\n$m";
substr($rom,6*4096+0xff8,4) eq "FA2\0" or die "FA2 signature missing from final file bank\n";

my %a=map { $_=>sym($m,$_) } qw(simulator_done failure current_source current_destination call_count fa2_data fa2_bss);
for my $b (0..6) {
   my($out,$err)=ok("simulate FA2 from bank $b",$sim,'-T',$cfg,"--start-bank=$b",sprintf('--stop-pc=0x%04X',$a{simulator_done}),'--dump-on-stop',$bin);
   $err eq '' or die "FA2 simulator stderr from bank $b:\n$err";
   my $mem=hexmem($out);
   $mem->[$a{failure}]==0 && $mem->[$a{call_count}]==49 or die "FA2 7x7 call-matrix self-test failed from bank $b\n";
   $mem->[$a{fa2_data}]==0xA5 && $mem->[$a{fa2_bss}]==0x11 && $mem->[$a{fa2_bss}+127]==0x22 && $mem->[$a{fa2_bss}+254]==0x33 or die "FA2 RAM sentinels failed from bank $b\n";
}

# The six-bank public profile gets its own complete ordered 6x6 matrix rather
# than relying on the seven-bank topology being a superset.
my $six_src=File::Spec->catfile($tmp,'fa2-24k-smoke.c26');
open my $sf,'>',$six_src or die "write $six_src: $!\n";
print {$sf} <<'C26';
include "FA2/mapper_24k.c26"

uint8_t six_failure;
uint8_t six_source;
uint8_t six_destination;
uint8_t six_count;

bank0 void six_done(void) { while (1) { } }

bank0 uint16_t six_probe0(void) {
   if (six_source > 5 || six_destination != 0) { six_failure := 0x70; }
   six_count := six_count + 1;
   return 0x6B40`uint16_t;
}

bank1 uint16_t six_probe1(void) {
   if (six_source > 5 || six_destination != 1) { six_failure := 0x71; }
   six_count := six_count + 1;
   return 0x6B41`uint16_t;
}

bank2 uint16_t six_probe2(void) {
   if (six_source > 5 || six_destination != 2) { six_failure := 0x72; }
   six_count := six_count + 1;
   return 0x6B42`uint16_t;
}

bank3 uint16_t six_probe3(void) {
   if (six_source > 5 || six_destination != 3) { six_failure := 0x73; }
   six_count := six_count + 1;
   return 0x6B43`uint16_t;
}

bank4 uint16_t six_probe4(void) {
   if (six_source > 5 || six_destination != 4) { six_failure := 0x74; }
   six_count := six_count + 1;
   return 0x6B44`uint16_t;
}

bank5 uint16_t six_probe5(void) {
   if (six_source > 5 || six_destination != 5) { six_failure := 0x75; }
   six_count := six_count + 1;
   return 0x6B45`uint16_t;
}

bank0 void six_source0(void) {
   six_source := 0;
   six_destination := 0; if (six_probe0() != 0x6B40`uint16_t) { six_failure := 0x00; }
   six_destination := 1; if (six_probe1() != 0x6B41`uint16_t) { six_failure := 0x01; }
   six_destination := 2; if (six_probe2() != 0x6B42`uint16_t) { six_failure := 0x02; }
   six_destination := 3; if (six_probe3() != 0x6B43`uint16_t) { six_failure := 0x03; }
   six_destination := 4; if (six_probe4() != 0x6B44`uint16_t) { six_failure := 0x04; }
   six_destination := 5; if (six_probe5() != 0x6B45`uint16_t) { six_failure := 0x05; }
}

bank1 void six_source1(void) {
   six_source := 1;
   six_destination := 0; if (six_probe0() != 0x6B40`uint16_t) { six_failure := 0x10; }
   six_destination := 1; if (six_probe1() != 0x6B41`uint16_t) { six_failure := 0x11; }
   six_destination := 2; if (six_probe2() != 0x6B42`uint16_t) { six_failure := 0x12; }
   six_destination := 3; if (six_probe3() != 0x6B43`uint16_t) { six_failure := 0x13; }
   six_destination := 4; if (six_probe4() != 0x6B44`uint16_t) { six_failure := 0x14; }
   six_destination := 5; if (six_probe5() != 0x6B45`uint16_t) { six_failure := 0x15; }
}

bank2 void six_source2(void) {
   six_source := 2;
   six_destination := 0; if (six_probe0() != 0x6B40`uint16_t) { six_failure := 0x20; }
   six_destination := 1; if (six_probe1() != 0x6B41`uint16_t) { six_failure := 0x21; }
   six_destination := 2; if (six_probe2() != 0x6B42`uint16_t) { six_failure := 0x22; }
   six_destination := 3; if (six_probe3() != 0x6B43`uint16_t) { six_failure := 0x23; }
   six_destination := 4; if (six_probe4() != 0x6B44`uint16_t) { six_failure := 0x24; }
   six_destination := 5; if (six_probe5() != 0x6B45`uint16_t) { six_failure := 0x25; }
}

bank3 void six_source3(void) {
   six_source := 3;
   six_destination := 0; if (six_probe0() != 0x6B40`uint16_t) { six_failure := 0x30; }
   six_destination := 1; if (six_probe1() != 0x6B41`uint16_t) { six_failure := 0x31; }
   six_destination := 2; if (six_probe2() != 0x6B42`uint16_t) { six_failure := 0x32; }
   six_destination := 3; if (six_probe3() != 0x6B43`uint16_t) { six_failure := 0x33; }
   six_destination := 4; if (six_probe4() != 0x6B44`uint16_t) { six_failure := 0x34; }
   six_destination := 5; if (six_probe5() != 0x6B45`uint16_t) { six_failure := 0x35; }
}

bank4 void six_source4(void) {
   six_source := 4;
   six_destination := 0; if (six_probe0() != 0x6B40`uint16_t) { six_failure := 0x40; }
   six_destination := 1; if (six_probe1() != 0x6B41`uint16_t) { six_failure := 0x41; }
   six_destination := 2; if (six_probe2() != 0x6B42`uint16_t) { six_failure := 0x42; }
   six_destination := 3; if (six_probe3() != 0x6B43`uint16_t) { six_failure := 0x43; }
   six_destination := 4; if (six_probe4() != 0x6B44`uint16_t) { six_failure := 0x44; }
   six_destination := 5; if (six_probe5() != 0x6B45`uint16_t) { six_failure := 0x45; }
}

bank5 void six_source5(void) {
   six_source := 5;
   six_destination := 0; if (six_probe0() != 0x6B40`uint16_t) { six_failure := 0x50; }
   six_destination := 1; if (six_probe1() != 0x6B41`uint16_t) { six_failure := 0x51; }
   six_destination := 2; if (six_probe2() != 0x6B42`uint16_t) { six_failure := 0x52; }
   six_destination := 3; if (six_probe3() != 0x6B43`uint16_t) { six_failure := 0x53; }
   six_destination := 4; if (six_probe4() != 0x6B44`uint16_t) { six_failure := 0x54; }
   six_destination := 5; if (six_probe5() != 0x6B45`uint16_t) { six_failure := 0x55; }
}

bank0 void main(void) {
   six_failure := 0;
   six_source := 0;
   six_destination := 0;
   six_count := 0;
   six_source0();
   six_source1();
   six_source2();
   six_source3();
   six_source4();
   six_source5();
   if (six_count != 36) { six_failure := 0x01; }
   asm jmp six_done;
}
C26
close $sf or die "close $six_src: $!\n";
my $six=File::Spec->catfile($tmp,'fa2-24k.bin');
my $six_map=File::Spec->catfile($tmp,'fa2-24k.map');
ok('build six-bank FA2',$driver,'-I',$vcs,'-T',$generic,'-Map',$six_map,$six_src,'-o',$six);
-s $six==24576 or die "FA2 24K image size wrong\n";
my $six_rom=readf($six); my $six_m=readf($six_map);
my $six_lst=readf(File::Spec->catfile($tmp,'fa2-24k.lst'));
for my $destination (0..5) {
   my $jsr_count = () = $six_lst =~ /; JSR six_probe\Q$destination\E\b/g;
   my $banktarget_count = () = $six_lst =~ /; \.banktarget six_probe\Q$destination\E\b/g;
   $jsr_count == 6 or die "FA2 24K destination bank $destination is not called once from every source bank\n";
   $banktarget_count == 5 or die "FA2 24K destination bank $destination does not have exactly five cross-bank descriptor calls\n";
}
for my $b (0..5) {
   substr($six_rom,$b*4096,512) eq ("\xFF" x 512) or die "FA2 24K bank $b RAM-port prefix exposed\n";
   my $hot=sprintf('%04X',0x1ff5+$b);
   $six_m =~ /^\s+bank\Q$b\E\s+file-index=\Q$b\E\b.*select-access=\$$hot/m or die "FA2 24K bank $b selector/file order wrong\n";
}
$six_m =~ /^\s+bank0\s+.*startup=yes/m or die "FA2 24K bank0 is not startup bank\n";
$six_m =~ /generic-jsr=\$048\b.*\bentries=0\s+jmp=0\s+jsr=0\b/ && $six_m !~ /JSR entry=/
   or die "FA2 24K diagnostic did not use only the mapper-specific inline bank-call block\n$six_m";
substr($six_rom,5*4096+0xff8,4) eq "FA2\0" or die "FA2 24K signature missing from final file bank\n";
my %sa=map { $_=>sym($six_m,$_) } qw(six_done six_failure six_count);
my $six_cfg=File::Spec->catfile($vcs,'FA2/mapper_24k.cfg');
for my $b (0..5) {
   my($out,$err)=ok("simulate six-bank FA2 from bank $b",$sim,'-T',$six_cfg,"--start-bank=$b",sprintf('--stop-pc=0x%04X',$sa{six_done}),'--dump-on-stop',$six);
   $err eq '' or die "FA2 24K simulator stderr from bank $b:\n$err";
   my $mem=hexmem($out);
   $mem->[$sa{six_failure}]==0 && $mem->[$sa{six_count}]==36 or die "FA2 24K 6x6 call-matrix self-test failed from bank $b\n";
}
my($six_s26,$six_derr)=ok('disassemble six-bank FA2',$disas,'-o','-',$six);
$six_derr eq '' or die "FA2 24K disassembler stderr:\n$six_derr";
$six_s26 =~ /^; mapper: FA2 \(high confidence;/m && $six_s26 =~ /^; reset\/power-on bank: 0 \(FA2 hardware bank 0\)$/m or die "FA2 24K disassembler mapper/reset contract missing\n";
my $six_ri=File::Spec->catdir($tmp,'roundtrip-24k-in'); my $six_ro=File::Spec->catdir($tmp,'roundtrip-24k-out'); make_path($six_ri,$six_ro);
copy($six,File::Spec->catfile($six_ri,'fa2-24k.bin')) or die "copy 24K roundtrip input: $!\n";
my($six_rout,$six_rerr)=ok('round-trip six-bank FA2',$^X,$round,$six_ri,$six_ro);
$six_rerr eq '' && $six_rout =~ /PASS fa2-24k\.bin/ or die "FA2 24K roundtrip failed\n$six_rout\n$six_rerr";

my $visible=File::Spec->catfile($tmp,'fa2-visible.bin');
ok('build visible FA2 diagnostic',$driver,'-I',$vcs,'-T',$generic,$src,'-o',$visible);
my($s26,$derr)=ok('disassemble FA2 diagnostic',$disas,'-o','-',$visible);
$derr eq '' or die "FA2 disassembler stderr:\n$derr";
$s26 =~ /^; mapper: FA2 \(high confidence;/m && $s26 =~ /^; reset\/power-on bank: 0 \(FA2 hardware bank 0\)$/m or die "FA2 disassembler mapper/reset contract missing\n";

my $ri=File::Spec->catdir($tmp,'roundtrip-in'); my $ro=File::Spec->catdir($tmp,'roundtrip-out'); make_path($ri,$ro);
copy($visible,File::Spec->catfile($ri,'fa2.bin')) or die "copy roundtrip input: $!\n";
my($rout,$rerr)=ok('round-trip FA2',$^X,$round,$ri,$ro);
$rerr eq '' && $rout =~ /PASS fa2\.bin/ or die "FA2 roundtrip failed\n$rout\n$rerr";


if ($stella_mode) {
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella or die "FA2 Stella certification requires Stella\n";
   my $xvfb=find_executable('Xvfb') or die "FA2 Stella certification requires Xvfb\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   my $snap=File::Spec->catdir($tmp,'stella-snap'); my $user=File::Spec->catdir($tmp,'stella-user'); make_path($snap,$user);
   my $display_num=180+($$%40); $display_num++ while -e "/tmp/.X11-unix/X$display_num"; my $display=':'.$display_num;
   my $xpid=fork(); defined($xpid) or die "fork Xvfb: $!\n";
   if($xpid==0){ open(STDOUT,'>',File::Spec->catfile($tmp,'xvfb.log')); open(STDERR,'>&STDOUT'); exec($xvfb,$display,'-ac','-screen','0','1600x1200x24'); die "exec Xvfb: $!\n"; }
   select undef,undef,undef,.20; my $xdg=File::Spec->catdir($tmp,'xdg'); make_path($xdg);
   local $ENV{DISPLAY}=$display; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp; local $ENV{XDG_CONFIG_HOME}=$xdg; local $ENV{SDL_AUDIODRIVER}='dummy';
   my $pid=fork(); defined($pid) or die "fork Stella: $!\n";
   if($pid==0){ open(STDOUT,'>',File::Spec->catfile($tmp,'stella.log')); open(STDERR,'>&STDOUT'); exec($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','FA2','-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1','-exitlauncher','0','-confirmexit','0','-userdir',$user,$visible); die "exec Stella: $!\n"; }
   select undef,undef,undef,.35; ok('snapshot FA2 in Stella',$^X,$keys); my @png;
   for(1..40){ @png=grep{-s $_} glob(File::Spec->catfile($snap,'*.png')); last if @png==1; select undef,undef,undef,.05; }
   terminate_child($pid); terminate_child($xpid); @png==1 or die "Stella FA2 produced ".scalar(@png)." snapshots\n";
   ok('grade FA2 Stella frame',$^X,$grade,$png[0],'pass','FA2');
}

print "FA2 diagnostic passed\n";
