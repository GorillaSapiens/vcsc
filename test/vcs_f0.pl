#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@ --stella
# phase: e2e
# timeout: 600
# expectstdout: F0 diagnostics passed: 16-bank complete matrix and hardware-startup edge
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use IO::Select;
use POSIX qw(:sys_wait_h);
use Symbol qw(gensym);

sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my($so,$se)=('',''); my $out_fd=fileno($out); my $sel=IO::Select->new($out,$err);
   while ($sel->count) { for my $fh ($sel->can_read) { my $buf=''; my $n=sysread($fh,$buf,8192);
      if (defined($n) && $n>0) { if (fileno($fh)==$out_fd) {$so.=$buf} else {$se.=$buf} }
      else { $sel->remove($fh); close($fh); }
   }}
   waitpid($pid,0); return ($? >> 8,$? & 127,$so,$se);
}
sub require_ok { my($label,@cmd)=@_; my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
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
sub read_file { my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>; close($fh); return $d // ''; }
sub map_symbol { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n"; return hex($1); }
sub parse_hex_dump { my($text)=@_; my @mem=(0)x65536; for my $line (split /\n/,$text) {
   next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
   my($n,$a,$data)=(hex($1),hex($2),$3); length($data)==$n*2 or die "bad HEX dump record\n";
   for my $i (0..$n-1) { $mem[$a+$i]=hex(substr($data,$i*2,2)); }
} return \@mem; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP [--stella]\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP [--stella]\n";
my $stella_mode=@ARGV && $ARGV[0] eq '--stella' ? shift(@ARGV) : '';
@ARGV and die "usage: $0 REPO TMP [--stella]\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));
my $disas=File::Spec->catfile($repo,qw(disassembler vcsc-disas));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $dir=File::Spec->catdir($repo,qw(examples 07_diagnostics/bankswitching f0));
my $source=File::Spec->catfile($dir,'f0_diagnostic.c26');
my $profile=File::Spec->catfile($vcs,qw(F0 mapper.c26));
my $bankcall=File::Spec->catfile($vcs,qw(F0 bankcall.s26));
my $entry=File::Spec->catfile($vcs,qw(F0 entry.s26));
my $makefile=File::Spec->catfile($dir,'Makefile');
for ($driver,$sim,$disas,$source,$profile,$bankcall,$entry,$makefile) { -e $_ or die "missing F0 support file $_\n"; }

my $pt=read_file($profile);
my $bank_decl_count=()=$pt =~ /^bank\s+bank\d+\s*\{/mg;
$bank_decl_count==16 or die "F0 profile contains $bank_decl_count bank declarations instead of 16\n";
$pt =~ /cartridge\s*\{.*?\$bankcall.*?\$signature:F0.*?\$trampoline_offset:0x0f00.*?\$trampoline_size:0x0060.*?\$vector_bridge_offset:0x0f60.*?\$vector_bridge_size:0x0090/s
   or die "F0 profile lost bankcall/hotspot-safe corridor contract\n";
for my $bank (0..15) {
   my $hex=sprintf('%02x',$bank);
   $pt =~ /^bank\s+bank\Q$bank\E\s*\{[^\n]*\$file_index:\Q$bank\E[^\n]*\$link_start:0xf000[^\n]*\$cpu_start:0xf000[^\n]*\$bankcall_descriptor:0x\Q$hex\E[^\n]*\};/m
      or die "F0 physical bank $bank descriptor geometry drifted\n";
}
$pt =~ /^bank\s+bank15\s*\{[^\n]*\$startup[^\n]*\$bankcall_descriptor:0x0f[^\n]*\};/m
   or die "F0 startup bank is not physical bank 15\n";
$pt !~ /\$select_access:/ or die "F0 profile must not pretend to have absolute selector hotspots\n";

my $bc=read_file($bankcall);
my $advance_count=()=$bc =~ /op0C\s+\$1FF0/g;
$advance_count==2 or die "F0 trampoline must have exactly two maintained $1FF0 advance sites\n";
$bc =~ /sbc\s+#VCSC_BANKCALL_SOURCE_DESCRIPTOR/ && $bc =~ /and\s+#\$0f/ &&
$bc =~ /lda\s+#VCSC_BANKCALL_SOURCE_DESCRIPTOR/ && $bc =~ /adc\s+#3/
   or die "F0 trampoline lost modulo-16 descriptor ABI\n";
$bc =~ /__vcsc_generic_bankcall_reserved_end\s*=\s*\$6060/
   or die "F0 trampoline reservation is no longer 96 bytes\n";
my $en=read_file($entry);
my $reset_advance_count=()=$en =~ /op0C\s+\$1FF0/g;
$reset_advance_count==15
   or die "F0 entry must contain the 15-step randomized-start advance ladder\n";

my $src=read_file($source);
for my $s (0..15) { for my $d (0..15) {
   $src =~ /bank\Q$s\E void source\Q$s\E\(void\).*?probe\Q$d\E\(\)/s
      or die "F0 diagnostic lost ordered call $s->$d\n";
}}
$src =~ /call_count\s*!=\s*256/ or die "F0 diagnostic lost complete 16x16 call-count oracle\n";
$src =~ /wide_probe\(\)\s*!=\s*0xbeef/ or die "F0 diagnostic lost A:X return preservation check\n";
$src =~ /bank15 void main\(void\)/ or die "F0 diagnostic main must live in hardware startup bank 15\n";
my $mk=read_file($makefile);
$mk =~ /^\s*stella\s+-userdir\s+"\$\(CURDIR\)"\s+-bs\s+F0\s+"\$\(CURDIR\)\/\$\(TARGET\)"\s*$/m or die "F0 play target must force Stella -bs F0\n";

my $bin=File::Spec->catfile($tmp,'f0.bin'); my $map_path=File::Spec->catfile($tmp,'f0.map');
my($build_out,$build_err)=require_ok('build F0 simulator diagnostic',$driver,'-I',$vcs,'-I',$dir,'-DSIMULATOR_TEST=1','-Map',$map_path,$source,'-o',$bin);
$build_err eq '' or die "F0 diagnostic build wrote stderr:\n$build_err";
-s $bin==16*4096 or die "F0 diagnostic output is not exactly 64K\n";
my $rom=read_file($bin); substr($rom,-8,4) eq "F0\0\0" or die "F0 signature missing from final physical bank\n";
for my $bank (0..15) {
   my $vo=$bank*4096+0x0ffc;
   my $rv=ord(substr($rom,$vo,1)) | (ord(substr($rom,$vo+1,1))<<8);
   my $want=0xff60 + 48 + $bank*3;
   $rv==$want
      or die sprintf("F0 bank %d RESET vector is \$%04X, expected \$%04X\n",
                     $bank,$rv,$want);
}
my $map=read_file($map_path);
for my $bank (0..15) { $map =~ /^\s+bank\Q$bank\E\s+file-index=\Q$bank\E\b.*cpu=\$F000/m or die "F0 map lost bank $bank/file-index identity\n"; }
$map =~ /^\s+bank15\s+file-index=15\b.*startup=yes/m or die "F0 map lost startup bank 15\n";
$map =~ /^\s+common-offset=\$F00\s+reserved=\$060\s+used=\$060.*generic-jsr=\$060/m
   or die "F0 map lost 96-byte replicated transition corridor\n";
my %sym=map { $_=>map_symbol($map,$_) } qw(simulator_done failure call_count);
my($sim_out,$sim_err)=require_ok('simulate complete F0 ordered call matrix',$sim,'--map',$map_path,sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$sim_err eq '' or die "F0 simulator wrote stderr:\n$sim_err";
my $mem=parse_hex_dump($sim_out);
$mem->[$sym{failure}]==0 or die sprintf("F0 matrix failed: failure=\$%02X\n",$mem->[$sym{failure}]);
my $count=$mem->[$sym{call_count}] | ($mem->[$sym{call_count}+1]<<8);
$count==256 or die "F0 matrix did not execute exactly 256 probe calls (got $count)\n";
for my $start (0..15) {
   my($forced_out,$forced_err)=require_ok("simulate F0 from physical bank $start",
      $sim,'--map',$map_path,"--start-bank=$start",
      sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
   $forced_err eq '' or die "F0 forced-start bank $start wrote stderr:\n$forced_err";
   my $forced=parse_hex_dump($forced_out);
   $forced->[$sym{failure}]==0
      or die sprintf("F0 forced-start bank %d failed: failure=\$%02X\n",
                     $start,$forced->[$sym{failure}]);
}

my $visible=File::Spec->catfile($tmp,'f0-visible.bin'); my $visible_map=File::Spec->catfile($tmp,'f0-visible.map');
require_ok('build visible F0 diagnostic',$driver,'-I',$vcs,'-I',$dir,'-Map',$visible_map,$source,'-o',$visible);
-s $visible==65536 or die "visible F0 diagnostic output is not exactly 64K\n";
my $timing_source=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $mos_dir=File::Spec->catdir($repo,qw(simulator mos6502)); my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp'); my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_f0');
require_ok('compile F0 frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);
my($timing_out,$timing_err)=require_ok('time F0 PASS/FAIL frames',$timing,$visible,'50','--no-audio','--raw-lines','264');
$timing_out eq "vcs_frame_timing ok: 47 frames at 262 lines, 1 AUDV0 writes\n"
   or die "F0 frame timing was not exactly 262 scanlines:\n$timing_out";
$timing_err eq '' or die "F0 frame timing wrote stderr:\n$timing_err";

my $s26=File::Spec->catfile($tmp,'f0.s26'); require_ok('disassemble F0 diagnostic',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: F0 \(high confidence;/m or die "vcsc-disas did not infer F0 with high confidence\n";
$dis =~ /^; reset\/power-on bank: 15 \(F0 hardware bank 15\)$/m or die "F0 disassembly lost hardware startup annotation\n";
$dis =~ /^; F0 switching: every read or write of \$1FF0 advances physical bank \(bank\+1\)&15;/m or die "F0 disassembly lost incremental switching annotation\n";

if ($stella_mode) {
   my $stella=find_executable($ENV{VCSC_STELLA} || $ENV{STELLA} || 'stella');
   require File::Spec->catfile($repo,qw(test stella_test_lib.pl));
   defined($stella) && -x $stella or die "F0 Stella certification requires Stella\n";
   my $xvfb=find_executable($ENV{VCSC_XVFB} || $ENV{XVFB} || 'Xvfb')
      or die "F0 Stella certification requires Xvfb\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   my $snap=File::Spec->catdir($tmp,'stella-snap');
   my $user=File::Spec->catdir($tmp,'stella-user');
   make_path($snap,$user); unlink glob(File::Spec->catfile($snap,'*.png'));
   my $display_num=200+($$%30); $display_num++ while -e "/tmp/.X11-unix/X$display_num";
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
      exec($stella,vcsc_stella_palette_args($repo,$user),'-video','software','-turbo','1',
           '-audio.enabled','0','-startbank','0','-dev.tiarandom','1','-bs','F0',
           '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
           '-exitlauncher','0','-confirmexit','0','-userdir',$user,$visible);
      die "exec Stella: $!\n";
   }
   select undef,undef,undef,0.35;
   require_ok('snapshot forced-bank0 F0 in Stella',$^X,$keys);
   my @png;
   for (1..40) {
      @png=grep { -s $_ } glob(File::Spec->catfile($snap,'*.png'));
      last if @png==1; select undef,undef,undef,0.05;
   }
   terminate_child($pid); terminate_child($xpid);
   @png==1 or die "Stella F0 produced ".scalar(@png)." snapshots\n";
   require_ok('grade forced-bank0 F0 Stella frame',$^X,$grade,$png[0],'pass','F0');
}

print "F0 diagnostics passed: 16-bank complete matrix and hardware-startup edge\n";
