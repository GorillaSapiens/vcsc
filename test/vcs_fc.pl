#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: FC diagnostics passed: 8-bank complete matrix, 256-bank 1MiB edge
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);

sub capture {
   my(@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my($so,$se)=('','');
   my $out_fd=fileno($out);
   my $sel=IO::Select->new($out,$err);
   while ($sel->count) {
      for my $fh ($sel->can_read) {
         my $buf=''; my $n=sysread($fh,$buf,8192);
         if (defined($n) && $n>0) {
            if (fileno($fh)==$out_fd) { $so.=$buf; } else { $se.=$buf; }
         } else { $sel->remove($fh); close($fh); }
      }
   }
   waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=capture(@cmd);
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

my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));
my $disas=File::Spec->catfile($repo,qw(disassembler vcsc-disas));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $dir=File::Spec->catdir($repo,qw(examples 09_bankswitching 21_fc));
my $source=File::Spec->catfile($dir,'fc_diagnostic.c26');
my $profile=File::Spec->catfile($vcs,qw(FC mapper.c26));
my $bankcall=File::Spec->catfile($vcs,qw(FC bankcall.s26));
my $entry=File::Spec->catfile($vcs,qw(FC entry.s26));
my $makefile=File::Spec->catfile($dir,'Makefile');
for ($driver,$sim,$disas,$source,$profile,$bankcall,$entry,$makefile) {
   -e $_ or die "missing FC support file $_\n";
}

my $pt=read_file($profile);
$pt =~ /parameter\s+VCS_FC_BANKS\s*;/ or die "FC profile lost VCS_FC_BANKS parameter\n";
$pt =~ /cartridge\s*\{.*?\$bankcall.*?\$signature:FC.*?\$trampoline_offset:0x0f00.*?\$trampoline_size:0x0070/s
   or die "FC profile lost descriptor-bankcall cartridge contract\n";
my $bank_decl_count=()=$pt =~ /^bank\s+bank\d+\s*\{/mg;
$bank_decl_count==256 or die "FC profile contains $bank_decl_count bank declarations instead of 256\n";
$pt =~ /#if\s+VCS_FC_BANKS\s*>\s*255.*?bank\s+bank255\s*\{.*?\$file_index:255.*?\$link_start:0xf000.*?\$cpu_start:0xf000.*?\$bankcall_descriptor:0xff/s
   or die "FC profile lost maximum-bank descriptor geometry\n";
$pt =~ /^bank\s+bank0\s*\{.*?\$file_index:0.*?\$startup.*?\$bankcall_descriptor:0x00\s*\};/m
   or die "FC startup bank is not physical/file bank 0 descriptor 0\n";
$pt !~ /\$select_access:/ or die "FC profile must not use per-bank selector hotspots\n";

my $bc=read_file($bankcall);
$bc =~ /sta\s+\$1FF8/ && $bc =~ /sta\s+\$1FF9/ && $bc =~ /op0C\s+\$1FFC/
   or die "FC trampoline lost staged-selector/commit sequence\n";
$bc =~ /VCSC_BANKCALL_SOURCE_DESCRIPTOR/ && $bc =~ /adc\s+#3/
   or die "FC trampoline lost 3-byte descriptor ABI\n";
my $en=read_file($entry);
$en =~ /__vcsc_mapper_entry_begin:\s*\n__vcsc_mapper_entry_end:/s
   or die "FC entry is no longer intentionally empty\n";
my $src=read_file($source);
$src =~ /VCS_FC_BANKS\s*:=\s*8/ or die "public FC diagnostic lost 8-bank profile\n";
for my $s (0..7) {
   for my $d (0..7) {
      $src =~ /bank\Q$s\E void source\Q$s\E\(void\).*?probe\Q$d\E\(\)/s
         or die "FC diagnostic lost ordered call $s->$d\n";
   }
}
$src =~ /wide_probe\(\)\s*!=\s*0xbeef/ or die "FC diagnostic lost A:X return preservation check\n";
$src =~ /call_count\s*!=\s*64/ or die "FC diagnostic lost complete 8x8 call-count oracle\n";
my $mk=read_file($makefile);
$mk =~ /^\s*stella\s+-bs\s+FC\s+\$\(TARGET\)/m or die "FC play target must force Stella -bs FC\n";

my $bin=File::Spec->catfile($tmp,'fc.bin');
my $map_path=File::Spec->catfile($tmp,'fc.map');
my($build_out,$build_err)=require_ok('build FC simulator diagnostic',$driver,'-I',$vcs,'-I',$dir,
   '-DSIMULATOR_TEST=1','-Map',$map_path,$source,'-o',$bin);
$build_err eq '' or die "FC diagnostic build wrote stderr:\n$build_err";
-s $bin==8*4096 or die "FC 8-bank diagnostic output is not exactly 32K\n";
my $rom=read_file($bin);
substr($rom,-8,4) eq "FC\0\0" or die "FC signature missing from final physical bank\n";
my $map=read_file($map_path);
for my $bank (0..7) {
   $map =~ /^\s+bank\Q$bank\E\s+file-index=\Q$bank\E\b.*cpu=\$F000/m
      or die "FC map lost bank $bank/file-index identity\n";
}
$map =~ /^\s+bank0\s+file-index=0\b.*startup=yes/m or die "FC map lost startup bank 0\n";
$map =~ /^TRAMPOLINES$/m && $map =~ /^\s+common-offset=\$F00\s+reserved=\$070\s+used=\$070.*generic-jsr=\$070/m
   or die "FC map lost 112-byte replicated descriptor-trampoline reservation\n";
my %sym=map { $_=>map_symbol($map,$_) } qw(simulator_done failure call_count);
my($sim_out,$sim_err)=require_ok('simulate complete FC ordered call matrix',$sim,'--map',$map_path,
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$sim_err eq '' or die "FC simulator wrote stderr:\n$sim_err";
my $mem=parse_hex_dump($sim_out);
$mem->[$sym{failure}]==0 or die sprintf("FC matrix failed: failure=\$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{call_count}]==64 or die "FC matrix did not execute exactly 64 probe calls\n";

# Build the visible PASS/FAIL cartridge separately and own its NTSC frame
# timing.  The simulator-only image above owns the complete call matrix.
my $visible=File::Spec->catfile($tmp,'fc-visible.bin');
my $visible_map=File::Spec->catfile($tmp,'fc-visible.map');
require_ok('build visible FC diagnostic',$driver,'-I',$vcs,'-I',$dir,'-Map',$visible_map,$source,'-o',$visible);
-s $visible==8*4096 or die "visible FC diagnostic output is not exactly 32K\n";
my $timing_source=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $mos_dir=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_fc');
require_ok('compile FC frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic',
   '-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);
my($timing_out,$timing_err)=require_ok('time FC PASS/FAIL frames',$timing,$visible,'50','--no-audio','--raw-lines','264');
$timing_out eq "vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n"
   or die "FC frame timing was not exactly 262 scanlines:\n$timing_out";
$timing_err eq '' or die "FC frame timing wrote stderr:\n$timing_err";

# The visible image must auto-detect as FC and retain the staged-protocol model.
my $s26=File::Spec->catfile($tmp,'fc.s26');
require_ok('disassemble FC diagnostic',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: FC \(high confidence;/m or die "vcsc-disas did not infer FC with high confidence\n";
$dis =~ /^; FC switching: write low selector to \$1FF8, write high selector to \$1FF9, then access \$1FFC to commit;/m
   or die "FC disassembly lost staged switching annotation\n";

# Maximum descriptor edge.  Keep the executable tiny while forcing a complete
# 256 x 4K physical image.  This proves descriptor $FF, high selector staging,
# nested return restoration, and the 1MiB linker image planes.
my $maxsrc=File::Spec->catfile($tmp,'fc256.c26');
write_file($maxsrc, <<'C26');
instantiate "FC/mapper.c26" as mapper (VCS_FC_BANKS:=256)
uint8_t failure;
bank0 uint8_t f0(void) { return 0x10; }
bank127 uint8_t f127(void) { return 0x7f; }
bank255 uint16_t f255(void) {
   if (f127() != 0x7f) { failure := 0x55; }
   return 0xbeef;
}
bank0 void simulator_done(void) { while (1) { } }
bank0 void main(void) {
   failure := 0;
   if (f0() != 0x10) { failure := 1; }
   if (f127() != 0x7f) { failure := 2; }
   if (f255() != 0xbeef) { failure := 3; }
   if (f0() != 0x10) { failure := 4; }
   asm jmp simulator_done;
}
C26
my $maxbin=File::Spec->catfile($tmp,'fc256.bin');
my $maxmap_path=File::Spec->catfile($tmp,'fc256.map');
my($max_out,$max_err)=require_ok('build maximum 1MiB FC profile',$driver,'-I',$vcs,'-Map',$maxmap_path,$maxsrc,'-o',$maxbin);
$max_err eq '' or die "FC maximum build wrote stderr:\n$max_err";
-s $maxbin==256*4096 or die "FC 256-bank profile emitted wrong size\n";
my $maxrom=read_file($maxbin);
substr($maxrom,-8,4) eq "FC\0\0" or die "FC 1MiB signature missing from final bank\n";
my $maxmap=read_file($maxmap_path);
my %file_index;
while ($maxmap =~ /^\s+bank(\d+)\s+file-index=(\d+)\b/mg) { $file_index{$1}=0+$2; }
keys(%file_index)==256 or die "FC maximum map does not contain 256 physical banks\n";
for my $bank (0..255) {
   exists($file_index{$bank}) && $file_index{$bank}==$bank
      or die "FC maximum map lost physical bank $bank/file-index identity\n";
}
$maxmap =~ /^\s+bank255\s+file-index=255\b.*cpu=\$F000/m
   or die "FC maximum map lost physical bank 255\n";
my %maxsym=map { $_=>map_symbol($maxmap,$_) } qw(simulator_done failure);
my($max_sim_out,$max_sim_err)=require_ok('simulate FC descriptor FF and nested restore',$sim,'--map',$maxmap_path,
   sprintf('--stop-pc=0x%04X',$maxsym{simulator_done}),'--dump-on-stop',$maxbin);
$max_sim_err eq '' or die "FC maximum simulator wrote stderr:\n$max_sim_err";
my $maxmem=parse_hex_dump($max_sim_out);
$maxmem->[$maxsym{failure}]==0 or die sprintf("FC descriptor FF failed: failure=\$%02X\n",$maxmem->[$maxsym{failure}]);
my($oracle_out,$oracle_err)=require_ok('execute FC descriptor FF in independent timing oracle',$timing,$maxbin,'10',
   '--stop-pc',sprintf('0x%04X',$maxsym{simulator_done}),'--no-audio',
   '--expect-memory',sprintf('0x%04X',$maxsym{failure}),'0');
$oracle_out =~ /^vcs_frame_timing stop ok:/m
   or die "FC timing oracle did not stop at the maximum-image sentinel:\n$oracle_out";
$oracle_err eq '' or die "FC maximum timing oracle wrote stderr:\n$oracle_err";

print "FC diagnostics passed: 8-bank complete matrix, 256-bank 1MiB edge\n";
