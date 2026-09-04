#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: E0 diagnostics passed: constrained three-state complete matrix
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Copy qw(copy);
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
sub read_file { my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/; my $d=<$fh>; close($fh); return $d // ''; }
sub map_symbol { my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m or die "map missing $name\n"; return hex($1); }
sub parse_hex_dump { my($text)=@_; my @mem=(0)x65536; for my $line (split /\n/,$text) {
   next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
   my($n,$a,$data)=(hex($1),hex($2),$3); length($data)==$n*2 or die "bad HEX dump record\n";
   for my $i (0..$n-1) { $mem[$a+$i]=hex(substr($data,$i*2,2)); }
} return \@mem; }
sub find_executable {
   my($name)=@_; return abs_path($name) if $name =~ m{/} && -x $name;
   for my $dir (split(/:/,$ENV{PATH} // '')) { my $p=File::Spec->catfile($dir,$name); return abs_path($p) if -x $p; }
   return undef;
}
sub terminate_child {
   my($pid)=@_; return if !$pid; kill 'TERM',$pid;
   for (1..20) { my $d=waitpid($pid,WNOHANG); return if $d==$pid || $d==-1; select undef,undef,undef,0.05; }
   kill 'KILL',$pid; waitpid($pid,0);
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP [--stella]\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP [--stella]\n";
my $stella_mode=@ARGV && $ARGV[0] eq '--stella' ? shift(@ARGV) : '';
@ARGV and die "usage: $0 REPO TMP [--stella]\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $sim=File::Spec->catfile($repo,qw(simulator vcsc-sim));
my $disas=File::Spec->catfile($repo,qw(disassembler vcsc-disas));
my $roundtrip=File::Spec->catfile($repo,qw(disassembler roundtrip.pl));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $profile=File::Spec->catfile($vcs,qw(E0 mapper.c26));
my $bankcall=File::Spec->catfile($vcs,qw(E0 bankcall.s26));
my $entry=File::Spec->catfile($vcs,qw(E0 entry.s26));
my $example_dir=File::Spec->catdir($repo,qw(examples 09_bankswitching 11_e0));
my $source=File::Spec->catfile($example_dir,'e0_diagnostic.c26');
my $example_make=File::Spec->catfile($example_dir,'Makefile');
for ($driver,$sim,$disas,$roundtrip,$profile,$bankcall,$entry,$source,$example_make) { -e $_ or die "missing E0 support file $_\n"; }

my $pt=read_file($profile);
(()=$pt =~ /^bank\s+bank\d+\s*\{/mg)==8 or die "E0 profile must contain exactly eight physical banks\n";
$pt =~ /cartridge\s*\{.*?\$bankcall.*?\$signature:E0.*?\$vector_bridge_offset:0x0360.*?\$trampoline_offset:0x0370.*?\$trampoline_size:0x0070/s
   or die "E0 profile lost automatic-call transition corridor\n";
my @start=(0x1000,0x1400,0x1000,0x1400,0x1000,0x1400,0x1800,0x1c00);
my @desc=(0,0,1,1,2,2,0xff,0xff);
for my $b (0..7) {
   my $st=sprintf('0x%04x',$start[$b]); my $de=sprintf('0x%02x',$desc[$b]);
   $pt =~ /^bank\s+bank\Q$b\E\s*\{[^\n]*\$file_index:\Q$b\E[^\n]*\$link_start:\Q$st\E[^\n]*\$cpu_start:\Q$st\E[^\n]*\$bankcall_descriptor:\Q$de\E[^\n]*\};/m
      or die "E0 bank $b canonical address/descriptor drifted\n";
}
$pt =~ /^bank\s+bank7\s*\{[^\n]*\$startup[^\n]*\};/m or die "E0 startup must remain fixed bank 7\n";
$pt =~ /uint8_t\s+_vcsc_e0_state\s*:=\s*2\s*;/ or die "E0 dynamic canonical-state shadow must initialize to state 2\n";
$pt !~ /\$select_access:/ or die "E0 pair transitions must remain mapper-owned rather than fake per-bank selectors\n";

my $bc=read_file($bankcall);
$bc =~ /cpx\s+#\$ff/ && $bc =~ /op1C\s+\$1FE0,x/ && $bc =~ /op1C\s+\$1FE8,x/ &&
$bc =~ /lda\s+VCSC_BANKCALL_SELECTOR_BASE\s*\n\s*pha/s &&
$bc =~ /__vcsc_generic_bankcall_reserved_end\s*=\s*\$6070/
   or die "E0 trampoline lost resident sentinel, pair switching, dynamic-state save, or 112-byte reservation\n";
my $en=read_file($entry);
$en =~ /__vcsc_mapper_entry_begin:\s*\n__vcsc_mapper_entry_end:/s or die "E0 entry should be empty because hardware starts [4,5,6,7]\n";

my $src=read_file($source);
for my $s (0..7) { for my $d (0..7) {
   $src =~ /bank\Q$s\E void source\Q$s\E\(void\).*?probe\Q$d\E\(\)/s or die "E0 diagnostic lost ordered call $s->$d\n";
}}
$src =~ /bank6 void resident_from_state0\(void\).*?probe2\(\).*?probe1\(\)/s &&
$src =~ /bank7 void resident_from_state1\(void\).*?probe4\(\).*?probe3\(\)/s
   or die "E0 diagnostic lost resident-bank nested state-restoration edges\n";
$src =~ /wide_probe\(\)\s*!=\s*0xbeef/ or die "E0 diagnostic lost A:X return preservation check\n";
$src =~ /_vcsc_e0_state\s*!=\s*2/ or die "E0 diagnostic lost final canonical-state shadow check\n";
$src =~ /bank4 void draw_result\(void\)/ && $src =~ /bank6 void component_init\(void\)/ && $src =~ /bank6 void component_vblank\(void\)/
   or die "E0 visible diagnostic must use state-2 canonical banks 4/5/6/7\n";
my $status_font=read_file(File::Spec->catfile($example_dir,'status_font.c26'));
my $cart_font=read_file(File::Spec->catfile($example_dir,'cart_type_font.c26'));
$status_font =~ /bank5 const uint8_t status_glyphs\[128\]/ && $cart_font =~ /bank5 const uint8_t cart_type_glyphs\[24\]/
   or die "E0 visible glyphs must live in canonical state-2 bank 5\n";
my $mk=read_file($example_make);
$mk =~ /FONT_SUBSET_FLAGS := --license examples\/LICENSE\.txt --bank bank5 --no-page/ &&
$mk =~ /^\s*stella\s+-bs\s+E0\s+\$\(TARGET\)/m
   or die "E0 Makefile lost bank5 font generation or forced Stella mapper\n";

my $bin=File::Spec->catfile($tmp,'e0.bin'); my $map_path=File::Spec->catfile($tmp,'e0.map');
my(undef,$build_err)=require_ok('build E0 simulator diagnostic',$driver,'-I',$vcs,'-I',$example_dir,'-DSIMULATOR_TEST=1','-Map',$map_path,$source,'-o',$bin);
$build_err eq '' or die "E0 simulator build wrote stderr:\n$build_err";
-s $bin==8192 or die "E0 output size is not exactly 8K\n";
my $rom=read_file($bin); substr($rom,-8,4) eq "E0\0\0" or die "E0 signature missing from fixed final bank\n";
for my $fb (0..6) { substr($rom,$fb*1024+1016,4) ne "E0\0\0" or die "E0 signature duplicated into physical bank $fb\n"; }
my $map=read_file($map_path);
for my $b (0..7) {
   my $cpu=sprintf('%04X',$start[$b]);
   $map =~ /^\s+bank\Q$b\E\s+file-index=\Q$b\E\b.*cpu=\$\Q$cpu\E/m or die "E0 map lost canonical bank $b identity\n";
}
$map =~ /^\s+bank7\s+file-index=7\b.*startup=yes/m or die "E0 map lost fixed startup bank 7\n";
$map =~ /^\s+common-offset=\$370\s+reserved=\$070\s+used=\$070.*generic-jsr=\$070/m or die "E0 map lost 112-byte replicated transition corridor\n";
my %sym=map { $_=>map_symbol($map,$_) } ('simulator_done','failure',(map {"hits$_"} 0..7),'_vcsc_e0_state');
my($sim_out,$sim_err)=require_ok('simulate complete E0 ordered call matrix',$sim,'--map',$map_path,sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$sim_err eq '' or die "E0 simulator wrote stderr:\n$sim_err";
my $mem=parse_hex_dump($sim_out);
$mem->[$sym{failure}]==0 or die sprintf("E0 matrix failed: failure=\$%02X\n",$mem->[$sym{failure}]);
my @expected=(8,9,9,9,9,8,8,8);
for my $i (0..7) { $mem->[$sym{"hits$i"}]==$expected[$i] or die "E0 probe $i count was $mem->[$sym{\"hits$i\"}] expected $expected[$i]\n"; }
$mem->[$sym{_vcsc_e0_state}]==2 or die "E0 matrix did not restore hardware/startup state 2\n";

my $visible=File::Spec->catfile($tmp,'e0-visible.bin'); my $visible_map=File::Spec->catfile($tmp,'e0-visible.map');
my(undef,$visible_err)=require_ok('build visible E0 diagnostic',$driver,'-I',$vcs,'-I',$example_dir,'-Map',$visible_map,$source,'-o',$visible);
$visible_err eq '' or die "visible E0 build wrote stderr:\n$visible_err";
my $vmap=read_file($visible_map);
$vmap =~ /CODE\.bank4\.__vcsc_function\$draw_result.*bank=bank4/s &&
$vmap =~ /RODATA\.bank5\.__vcsc_object\$status_glyphs.*bank=bank5/s &&
$vmap =~ /RODATA\.bank5\.__vcsc_object\$cart_type_glyphs.*bank=bank5/s &&
$vmap =~ /CODE\.bank6\.__vcsc_function\$component_init.*bank=bank6/s
   or die "visible E0 diagnostic lost legal state-2 cross-bank placement\n";

# Direct ROM data is legal only inside a guaranteed simultaneous E0 state.
my $bad=File::Spec->catfile($tmp,'e0-bad-cross-state.c26');
open(my $bf,'>',$bad) or die "write $bad: $!\n";
print {$bf} <<'BAD';
include "E0/mapper.c26"
bank2 const uint8_t remote := 0x55;
bank0 uint8_t illegal(void) { return remote; }
bank7 void main(void) { illegal(); while (1) { } }
BAD
close($bf);
my($brc,$bsig,$bout,$berr)=capture($driver,'-I',$vcs,$bad,'-o',File::Spec->catfile($tmp,'bad.bin'));
$brc!=0 && !$bsig or die "E0 cross-state bank0->bank2 ROM data reference unexpectedly linked\n";
$berr =~ /(contradictory pins|cross-bank ROM)/ or die "E0 cross-state rejection used unexpected diagnostic:\n$berr";

my $timing_source=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $mos_dir=File::Spec->catdir($repo,qw(simulator mos6502)); my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp'); my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_e0');
require_ok('compile E0 frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic','-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);
my($timing_out,$timing_err)=require_ok('time E0 PASS/FAIL frames',$timing,$visible,'50','--no-audio','--raw-lines','264');
$timing_out eq "vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n" or die "E0 frame timing was not exactly 262 scanlines:\n$timing_out";
$timing_err eq '' or die "E0 frame timing wrote stderr:\n$timing_err";

my $s26=File::Spec->catfile($tmp,'e0-visible.s26'); require_ok('disassemble E0 diagnostic',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: E0 \(high confidence;/m &&
$dis =~ /^; reset\/power-on bank: 7 \(E0 fixed vector bank\)$/m &&
$dis =~ /^; E0 segments: \$1000-\$13FF, \$1400-\$17FF, \$1800-\$1BFF are independently banked 1K windows; \$1C00-\$1FFF is fixed physical bank 7$/m
   or die "vcsc-disas did not recognize E0 semantics\n$dis";
my $rt_in=File::Spec->catdir($tmp,'roundtrip-in'); my $rt_out=File::Spec->catdir($tmp,'roundtrip-out'); make_path($rt_in,$rt_out);
copy($visible,File::Spec->catfile($rt_in,'e0-visible.bin')) or die "copy E0 roundtrip input: $!\n";
require_ok('round-trip E0 cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'e0-visible.bin')) eq read_file($visible) or die "E0 disassembler round trip is not byte-exact\n";

if ($stella_mode) {
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella or die "E0 Stella certification requires Stella\n";
   my $xvfb=find_executable('Xvfb') or die "E0 Stella certification requires Xvfb\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   my $snap=File::Spec->catdir($tmp,'stella-snap'); my $user=File::Spec->catdir($tmp,'stella-user');
   make_path($snap,$user); unlink glob(File::Spec->catfile($snap,'*.png'));
   my $display_num=180+($$%40); $display_num++ while -e "/tmp/.X11-unix/X$display_num";
   my $display=':'.$display_num;
   my $xpid=fork(); defined($xpid) or die "fork Xvfb: $!\n";
   if ($xpid==0) { open(STDOUT,'>',File::Spec->catfile($tmp,'xvfb.log')) or die $!; open(STDERR,'>&STDOUT') or die $!; exec($xvfb,$display,'-ac','-screen','0','1024x768x24'); die "exec Xvfb: $!\n"; }
   select undef,undef,undef,0.20;
   my $xdg=File::Spec->catdir($tmp,'xdg'); make_path($xdg);
   local $ENV{DISPLAY}=$display; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp;
   local $ENV{XDG_CONFIG_HOME}=$xdg; local $ENV{SDL_AUDIODRIVER}='dummy';
   my $pid=fork(); defined($pid) or die "fork Stella: $!\n";
   if ($pid==0) {
      open(STDOUT,'>',File::Spec->catfile($tmp,'stella.log')) or die $!; open(STDERR,'>&STDOUT') or die $!;
      exec($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','E0',
           '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
           '-exitlauncher','0','-confirmexit','0','-userdir',$user,$visible);
      die "exec Stella: $!\n";
   }
   select undef,undef,undef,0.35;
   require_ok('snapshot E0 in Stella',$^X,$keys);
   my @png; for (1..40) { @png=grep { -s $_ } glob(File::Spec->catfile($snap,'*.png')); last if @png==1; select undef,undef,undef,0.05; }
   terminate_child($pid); terminate_child($xpid);
   @png==1 or die "Stella E0 produced ".scalar(@png)." snapshots\n";
   require_ok('grade E0 Stella frame',$^X,$grade,$png[0],'pass','E0');
}

print "E0 diagnostics passed: constrained three-state complete matrix\n";
