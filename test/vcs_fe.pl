#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: FE/SCABS diagnostic passed
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
sub require_fail {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=run_capture(@cmd);
   ($rc!=0 || $sig) or die "$label unexpectedly succeeded\n@cmd\nstdout:\n$out\nstderr:\n$err";
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
   my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\s/m
      or die "map missing $name\n"; return hex($1);
}
sub find_executable {
   my($name)=@_; return abs_path($name) if $name =~ m{/} && -x $name;
   for my $dir (split(/:/,$ENV{PATH} // '')) {
      my $p=File::Spec->catfile($dir,$name); return abs_path($p) if -x $p;
   }
   return undef;
}
sub terminate_child {
   my($pid)=@_; return if !$pid;
   kill 'TERM',$pid;
   for (1..20) { my $d=waitpid($pid,WNOHANG); return if $d==$pid || $d==-1; select undef,undef,undef,0.05; }
   kill 'KILL',$pid; waitpid($pid,0);
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

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP [--stella]\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP [--stella]\n";
my $stella_mode=@ARGV && $ARGV[0] eq '--stella' ? shift(@ARGV) : '';
@ARGV and die "usage: $0 REPO TMP [--stella]\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $disas=File::Spec->catfile($repo,'disassembler','vcsc-disas');
my $roundtrip=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $cfg=File::Spec->catfile($vcs,'vcs_8k_fe.cfg');
my $profile=File::Spec->catfile($vcs,'vcs_8k_fe.c26');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','14_fe');
my $source=File::Spec->catfile($example_dir,'fe_diagnostic.c26');
my $example_make=File::Spec->catfile($example_dir,'Makefile');

my $mk=read_file($example_make);
$mk =~ /^play:\s*\$\(TARGET\)\s*$/m && $mk =~ /^\s*stella\s+-bs\s+FE\s+\$\(TARGET\)\s*$/m
   or die "FE play target must force Stella -bs FE\n";
my $pt=read_file($profile);
$pt =~ /\$signature:FE\b/ && $pt !~ /\$select_access:/ &&
$pt =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$link_start:0xf000.*?\$cpu_start:0xf000.*?\$startup/s &&
$pt =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$link_start:0xd000.*?\$cpu_start:0xd000/s
   or die "FE C26 profile does not describe the two delayed-latch banks\n";
my $ct=read_file($cfg);
$ct =~ /mapper\s*=\s*FE/ && $ct !~ /hotspot\s*=/ &&
$ct =~ /BANK0:.*start\s*=\s*\$F000.*fileindex\s*=\s*0.*startup\s*=\s*yes/is &&
$ct =~ /BANK1:.*start\s*=\s*\$D000.*fileindex\s*=\s*1/is
   or die "FE simulator cfg does not describe deterministic bank 0 plus D-bank 1\n";

my $bin=File::Spec->catfile($tmp,'fe.bin');
my $map_path=File::Spec->catfile($tmp,'fe.map');
require_ok('build FE simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST',
   '-T',$generic,'-Map',$map_path,$source,'-o',$bin);
-s $bin==8192 or die "FE output size is not 8K\n";
my $rom=read_file($bin);
substr($rom,4096+0x0ff8,4) eq "FE\0\0" or die "FE signature is missing from physical bank 1\n";
substr($rom,0x0ff8,4) ne "FE\0\0" or die "FE signature was duplicated into startup bank 0\n";
my $map=read_file($map_path);
$map =~ /^\s+bank0\s+file-index=0\b.*link=\$F000.*cpu=\$F000.*mode=fe-delayed.*startup=yes/m &&
$map =~ /^\s+bank1\s+file-index=1\b.*link=\$D000.*cpu=\$D000.*mode=fe-delayed/m &&
$map !~ /^TRAMPOLINES$/m
   or die "FE map lost its direct delayed-latch topology\n$map";
my %sym=map { $_=>map_symbol($map,$_) } qw(main bank1_probe simulator_done failure trace stack_after);
($sym{main} & 0xF000)==0xF000 && ($sym{bank1_probe} & 0xF000)==0xD000
   or die "FE diagnostic functions were not placed in F/D banks\n";
my $jsr=pack('C*',0x20,$sym{bank1_probe}&0xff,($sym{bank1_probe}>>8)&0xff);
my $main_off=$sym{main}-0xF000;
index(substr($rom,$main_off,0x100),$jsr)>=0
   or die "FE linker did not emit a direct JSR from main into bank 1\n";
my($out,$err)=require_ok('simulate released FE JSR/RTS idiom',$sim,'-T',$cfg,
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$err eq '' or die "FE simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($out);
$mem->[$sym{failure}]==0 or die sprintf("FE self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{trace}]==0x5A or die "FE bank-1 function did not execute\n";
$mem->[$sym{stack_after}]==0xFF or die "FE RTS did not restore the caller bank/stack\n";

# Poison the bank-1 copy of the JSR target-high fetch address. Correct FE
# hardware does not switch on the $01FE write itself: that write only arms the
# latch, so the following high-byte fetch must still come from startup bank 0.
my $raw=File::Spec->catfile($tmp,'fe-delayed.bin');
my $r=("\xFF" x 8192);
my @caller=(0xA2,0xFF,0x9A,0x20,0x00,0xD0,0xA9,0xAA,0x85,0x80,0x4C,0x0D,0xF1,0xEA);
substr($r,0x100,scalar(@caller))=pack('C*',@caller);
substr($r,4096+0x000,5)=pack('C*',0xA9,0x55,0x85,0x81,0x60);
substr($r,4096+0x105,1)=pack('C',0xF0); # poison if switching happens one bus cycle too early
substr($r,0x0ffc,2)=pack('C*',0x00,0xF1);
write_file($raw,$r);
my($rout,$rerr)=require_ok('simulate FE one-cycle delayed latch',$sim,'-T',$cfg,
   '--stop-pc=0xF10D','--dump-on-stop',$raw);
$rerr eq '' or die "FE delayed-latch fixture wrote stderr:\n$rerr";
my $rmem=parse_hex_dump($rout);
$rmem->[0x0081]==0x55 && $rmem->[0x0080]==0xAA
   or die "FE latch switched too early or RTS failed to restore startup bank\n";

# A nested cross-bank JSR is unsafe because its low return-byte push is not
# guaranteed to address $01FE. Reject it instead of generating accidental FE.
my $bad=File::Spec->catfile($tmp,'nested_fe.c26');
write_file($bad,<<'SRC');
include "vcs_8k_fe.c26"
bank1 uint8_t target(void) { return 0x5a; }
bank0 uint8_t helper(void) { return target(); }
void main(void) { uint8_t x; x := helper(); while (1) { } }
SRC
my $badbin=File::Spec->catfile($tmp,'nested_fe.bin');
my($bout,$berr)=require_fail('reject nested FE cross-bank JSR',$driver,'-I',$vcs,'-T',$generic,$bad,'-o',$badbin);
($bout.$berr) =~ /FE cross-bank JSR.*main/is
   or die "nested FE rejection did not explain the top-level-main restriction\nstdout:\n$bout\nstderr:\n$berr";

my $visible=File::Spec->catfile($tmp,'fe-visible.bin');
my $visible_map=File::Spec->catfile($tmp,'fe-visible.map');
require_ok('build visible FE PASS/FAIL cartridge',$driver,'-I',$vcs,'-T',$generic,
   '-Map',$visible_map,$source,'-o',$visible);
my $vrom=read_file($visible);
length($vrom)==8192 && substr($vrom,4096+0x0ff8,4) eq "FE\0\0"
   or die "visible FE diagnostic lost its 8K/signature layout\n";
my $vmap=read_file($visible_map);
$vmap =~ /^\s*\$[0-9A-Fa-f]{4}\s+__vcsc_startup_simple\s/m &&
$vmap !~ /^\s*\$[0-9A-Fa-f]{4}\s+__vcsc_startup_full\s/m
   or die "visible FE diagnostic must use stack-safe simple startup\n";
my $s26=File::Spec->catfile($tmp,'fe-visible.s26');
require_ok('disassemble FE cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: FE \(high confidence;/m &&
$dis =~ /^; reset\/power-on bank: 0 \(FE deterministic bank 0\)$/m &&
$dis =~ /^; FE\/SCABS switching: stack access to \$01FE arms a one-cycle delayed bank latch;/m
   or die "vcsc-disas did not recognize FE/SCABS semantics\n$dis";
my $rt_in=File::Spec->catdir($tmp,'roundtrip-in');
my $rt_out=File::Spec->catdir($tmp,'roundtrip-out');
make_path($rt_in,$rt_out);
copy($visible,File::Spec->catfile($rt_in,'fe-visible.bin')) or die "copy FE roundtrip input: $!\n";
require_ok('round-trip FE cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'fe-visible.bin')) eq $vrom
   or die "FE disassembler round trip is not byte-exact\n";

if ($stella_mode) {
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella or die "FE Stella certification requires Stella\n";
   my $xvfb=find_executable('Xvfb') or die "FE Stella certification requires Xvfb\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   my $snap=File::Spec->catdir($tmp,'stella-snap');
   my $user=File::Spec->catdir($tmp,'stella-user');
   make_path($snap,$user); unlink glob(File::Spec->catfile($snap,'*.png'));
   my $display_num=180+($$%40); $display_num++ while -e "/tmp/.X11-unix/X$display_num";
   my $display=':'.$display_num;
   my $xpid=fork(); defined($xpid) or die "fork Xvfb: $!\n";
   if ($xpid==0) {
      open(STDOUT,'>',File::Spec->catfile($tmp,'xvfb.log')) or die $!;
      open(STDERR,'>&STDOUT') or die $!;
      exec($xvfb,$display,'-ac','-screen','0','1600x1200x24'); die "exec Xvfb: $!\n";
   }
   select undef,undef,undef,0.20;
   my $xdg=File::Spec->catdir($tmp,'xdg'); make_path($xdg);
   local $ENV{DISPLAY}=$display; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp;
   local $ENV{XDG_CONFIG_HOME}=$xdg; local $ENV{SDL_AUDIODRIVER}='dummy';
   my $pid=fork(); defined($pid) or die "fork Stella: $!\n";
   if ($pid==0) {
      open(STDOUT,'>',File::Spec->catfile($tmp,'stella.log')) or die $!;
      open(STDERR,'>&STDOUT') or die $!;
      exec($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','FE',
           '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
           '-exitlauncher','0','-confirmexit','0','-userdir',$user,$visible);
      die "exec Stella: $!\n";
   }
   select undef,undef,undef,0.35;
   require_ok('snapshot FE in Stella',$^X,$keys);
   my @png;
   for (1..40) {
      @png=grep { -s $_ } glob(File::Spec->catfile($snap,'*.png'));
      last if @png==1;
      select undef,undef,undef,0.05;
   }
   terminate_child($pid); terminate_child($xpid);
   @png==1 or die "Stella FE produced ".scalar(@png)." snapshots\n";
   require_ok('grade FE Stella frame',$^X,$grade,$png[0],'pass','FE');
}

print "FE/SCABS diagnostic passed\n";
