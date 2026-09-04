#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: F0 diagnostics passed: 16-bank complete matrix and hardware-startup edge
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use IO::Select;
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
sub read_file { my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>; close($fh); return $d // ''; }
sub map_symbol { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n"; return hex($1); }
sub parse_hex_dump { my($text)=@_; my @mem=(0)x65536; for my $line (split /\n/,$text) {
   next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
   my($n,$a,$data)=(hex($1),hex($2),$3); length($data)==$n*2 or die "bad HEX dump record\n";
   for my $i (0..$n-1) { $mem[$a+$i]=hex(substr($data,$i*2,2)); }
} return \@mem; }

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n"; @ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));
my $disas=File::Spec->catfile($repo,qw(disassembler vcsc-disas));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $dir=File::Spec->catdir($repo,qw(examples 09_bankswitching 22_f0));
my $source=File::Spec->catfile($dir,'f0_diagnostic.c26');
my $profile=File::Spec->catfile($vcs,qw(F0 mapper.c26));
my $bankcall=File::Spec->catfile($vcs,qw(F0 bankcall.s26));
my $entry=File::Spec->catfile($vcs,qw(F0 entry.s26));
my $makefile=File::Spec->catfile($dir,'Makefile');
for ($driver,$sim,$disas,$source,$profile,$bankcall,$entry,$makefile) { -e $_ or die "missing F0 support file $_\n"; }

my $pt=read_file($profile);
my $bank_decl_count=()=$pt =~ /^bank\s+bank\d+\s*\{/mg;
$bank_decl_count==16 or die "F0 profile contains $bank_decl_count bank declarations instead of 16\n";
$pt =~ /cartridge\s*\{.*?\$bankcall.*?\$signature:F0.*?\$trampoline_offset:0x0f00.*?\$trampoline_size:0x0060.*?\$vector_bridge_offset:0x0ee0/s
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
$en =~ /__vcsc_mapper_entry_begin:\s*\n__vcsc_mapper_entry_end:/s
   or die "F0 entry is no longer intentionally empty\n";

my $src=read_file($source);
for my $s (0..15) { for my $d (0..15) {
   $src =~ /bank\Q$s\E void source\Q$s\E\(void\).*?probe\Q$d\E\(\)/s
      or die "F0 diagnostic lost ordered call $s->$d\n";
}}
$src =~ /call_count\s*!=\s*256/ or die "F0 diagnostic lost complete 16x16 call-count oracle\n";
$src =~ /wide_probe\(\)\s*!=\s*0xbeef/ or die "F0 diagnostic lost A:X return preservation check\n";
$src =~ /bank15 void main\(void\)/ or die "F0 diagnostic main must live in hardware startup bank 15\n";
my $mk=read_file($makefile);
$mk =~ /^\s*stella\s+-bs\s+F0\s+\$\(TARGET\)/m or die "F0 play target must force Stella -bs F0\n";

my $bin=File::Spec->catfile($tmp,'f0.bin'); my $map_path=File::Spec->catfile($tmp,'f0.map');
my($build_out,$build_err)=require_ok('build F0 simulator diagnostic',$driver,'-I',$vcs,'-I',$dir,'-DSIMULATOR_TEST=1','-Map',$map_path,$source,'-o',$bin);
$build_err eq '' or die "F0 diagnostic build wrote stderr:\n$build_err";
-s $bin==16*4096 or die "F0 diagnostic output is not exactly 64K\n";
my $rom=read_file($bin); substr($rom,-8,4) eq "F0\0\0" or die "F0 signature missing from final physical bank\n";
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

my $visible=File::Spec->catfile($tmp,'f0-visible.bin'); my $visible_map=File::Spec->catfile($tmp,'f0-visible.map');
require_ok('build visible F0 diagnostic',$driver,'-I',$vcs,'-I',$dir,'-Map',$visible_map,$source,'-o',$visible);
-s $visible==65536 or die "visible F0 diagnostic output is not exactly 64K\n";
my $timing_source=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $mos_dir=File::Spec->catdir($repo,qw(simulator mos6502)); my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp'); my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_f0');
require_ok('compile F0 frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);
my($timing_out,$timing_err)=require_ok('time F0 PASS/FAIL frames',$timing,$visible,'50','--no-audio','--raw-lines','264');
$timing_out eq "vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n"
   or die "F0 frame timing was not exactly 262 scanlines:\n$timing_out";
$timing_err eq '' or die "F0 frame timing wrote stderr:\n$timing_err";

my $s26=File::Spec->catfile($tmp,'f0.s26'); require_ok('disassemble F0 diagnostic',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: F0 \(high confidence;/m or die "vcsc-disas did not infer F0 with high confidence\n";
$dis =~ /^; reset\/power-on bank: 15 \(F0 hardware bank 15\)$/m or die "F0 disassembly lost hardware startup annotation\n";
$dis =~ /^; F0 switching: every read or write of \$1FF0 advances physical bank \(bank\+1\)&15;/m or die "F0 disassembly lost incremental switching annotation\n";

print "F0 diagnostics passed: 16-bank complete matrix and hardware-startup edge\n";
