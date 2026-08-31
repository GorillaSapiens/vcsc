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
my $cfg=File::Spec->catfile($vcs,'vcs_28k_fa2.cfg');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $bin=File::Spec->catfile($tmp,'fa2.bin');
my $map=File::Spec->catfile($tmp,'fa2.map');

ok('build FA2 simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST','-T',$generic,'-Map',$map,$src,'-o',$bin);
-s $bin==28672 or die "FA2 28K image size wrong\n";
my $rom=readf($bin); my $m=readf($map);
for my $b (0..6) { substr($rom,$b*4096,512) eq ("\xFF" x 512) or die "FA2 bank $b RAM-port prefix exposed\n"; }
for my $b (0..6) {
   my $hot=sprintf('%04X',0x1ff5+$b);
   $m =~ /^\s+bank\Q$b\E\s+file-index=\Q$b\E\b.*select-access=\$$hot/m or die "FA2 bank $b selector/file order wrong\n";
}
$m =~ /^\s+bank0\s+.*startup=yes/m or die "FA2 bank0 is not startup bank\n";
$m =~ /^\s+cartram\s+read_start=\$F100 write_start=\$F000 size=\$0100 type=rw shared=yes\b/m or die "FA2 RAM map missing\n";
$m =~ /cartram\s+used=256 bytes \(100\.00%\).*free=0 bytes/m or die "FA2 diagnostic does not occupy all cart RAM\n";
substr($rom,6*4096+0xff8,4) eq "FA2\0" or die "FA2 signature missing from final file bank\n";

my %a=map { $_=>sym($m,$_) } qw(simulator_done failure trace ram_count fa2_data fa2_bss);
for my $b (0..6) {
   my($out,$err)=ok("simulate FA2 from bank $b",$sim,'-T',$cfg,"--start-bank=$b",sprintf('--stop-pc=0x%04X',$a{simulator_done}),'--dump-on-stop',$bin);
   $err eq '' or die "FA2 simulator stderr from bank $b:\n$err";
   my $mem=hexmem($out);
   $mem->[$a{failure}]==0 && $mem->[$a{trace}]==8 && $mem->[$a{ram_count}]==7 or die "FA2 self-test failed from bank $b\n";
   $mem->[$a{fa2_data}]==0xA5 && $mem->[$a{fa2_bss}]==0x11 && $mem->[$a{fa2_bss}+127]==0x22 && $mem->[$a{fa2_bss}+254]==0x33 or die "FA2 RAM sentinels failed from bank $b\n";
}

# Six-bank public profile gets its own representative selector/return-path smoke
# rather than relying on the seven-bank topology being a superset.  The complete
# ordered six- and seven-bank JSR matrices live in
# vcs_bankswitching_call_matrix.pl.
my $six_src=File::Spec->catfile($tmp,'fa2-24k-smoke.c26');
open my $sf,'>',$six_src or die "write $six_src: $!\n";
print {$sf} <<'C26';
include "vcs_24k_fa2.c26"

uint8_t six_failure;
uint8_t six_trace;

bank0 void six_done(void) { while (1) { } }

bank0 void six_bank0_tail(void) {
   if (six_trace != 5) { six_failure := 0x60; }
   six_trace := 6;
}

bank5 void six_bank5(void) {
   if (six_trace != 4) { six_failure := 0x50; }
   six_trace := 5;
   six_bank0_tail();
   if (six_trace != 6) { six_failure := 0x51; }
   six_trace := 7;
}

bank4 void six_bank4(void) {
   if (six_trace != 3) { six_failure := 0x40; }
   six_trace := 4;
   six_bank5();
   if (six_trace != 7) { six_failure := 0x41; }
   six_trace := 8;
}

bank3 void six_bank3(void) {
   if (six_trace != 2) { six_failure := 0x30; }
   six_trace := 3;
   six_bank4();
   if (six_trace != 8) { six_failure := 0x31; }
   six_trace := 9;
}

bank2 void six_bank2(void) {
   if (six_trace != 1) { six_failure := 0x20; }
   six_trace := 2;
   six_bank3();
   if (six_trace != 9) { six_failure := 0x21; }
   six_trace := 10;
}

bank1 void six_bank1(void) {
   if (six_trace != 0) { six_failure := 0x10; }
   six_trace := 1;
   six_bank2();
   if (six_trace != 10) { six_failure := 0x11; }
   six_trace := 11;
}

void main(void) {
   six_failure := 0;
   six_trace := 0;
   six_bank1();
   if (six_trace != 11) { six_failure := 0x01; }
   asm jmp six_done;
}
C26
close $sf or die "close $six_src: $!\n";
my $six=File::Spec->catfile($tmp,'fa2-24k.bin');
my $six_map=File::Spec->catfile($tmp,'fa2-24k.map');
ok('build six-bank FA2',$driver,'-I',$vcs,'-T',$generic,'-Map',$six_map,$six_src,'-o',$six);
-s $six==24576 or die "FA2 24K image size wrong\n";
my $six_rom=readf($six); my $six_m=readf($six_map);
for my $b (0..5) {
   substr($six_rom,$b*4096,512) eq ("\xFF" x 512) or die "FA2 24K bank $b RAM-port prefix exposed\n";
   my $hot=sprintf('%04X',0x1ff5+$b);
   $six_m =~ /^\s+bank\Q$b\E\s+file-index=\Q$b\E\b.*select-access=\$$hot/m or die "FA2 24K bank $b selector/file order wrong\n";
}
$six_m =~ /^\s+bank0\s+.*startup=yes/m or die "FA2 24K bank0 is not startup bank\n";
substr($six_rom,5*4096+0xff8,4) eq "FA2\0" or die "FA2 24K signature missing from final file bank\n";
my %sa=map { $_=>sym($six_m,$_) } qw(six_done six_failure six_trace);
my $six_cfg=File::Spec->catfile($vcs,'vcs_24k_fa2.cfg');
for my $b (0..5) {
   my($out,$err)=ok("simulate six-bank FA2 from bank $b",$sim,'-T',$six_cfg,"--start-bank=$b",sprintf('--stop-pc=0x%04X',$sa{six_done}),'--dump-on-stop',$six);
   $err eq '' or die "FA2 24K simulator stderr from bank $b:\n$err";
   my $mem=hexmem($out);
   $mem->[$sa{six_failure}]==0 && $mem->[$sa{six_trace}]==11 or die "FA2 24K selector/return self-test failed from bank $b\n";
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
