#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: WD diagnostic passed
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
sub read_file {
   my($p)=@_; open(my $fh,'<:raw',$p) or die "read $p: $!\n"; local $/;
   my $d=<$fh>; close($fh); return $d // '';
}
sub write_file {
   my($p,$d)=@_; open(my $fh,'>:raw',$p) or die "write $p: $!\n";
   print {$fh} $d; close($fh) or die "close $p: $!\n";
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
my $cfg=File::Spec->catfile($vcs,'WD/mapper.cfg');
my $profile=File::Spec->catfile($vcs,'WD/mapper.c26');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','15_wd');
my $source=File::Spec->catfile($example_dir,'wd_diagnostic.c26');
my $example_make=File::Spec->catfile($example_dir,'Makefile');

my $src=read_file($source);
my $font=read_file(File::Spec->catfile($example_dir,'diagnostic_font.c26'));
$src =~ /instantiate "six_glyph_component\.c26" as status \(compact_font:=0, external_pointers:=1, mutable_color:=1\)/ &&
$src =~ /instantiate "six_glyph_component\.c26" as cart_type \(compact_font:=0, external_pointers:=1\)/ &&
$src =~ /bank2 void draw_result\(void\)/ &&
$src =~ /asm lda \$39;\s*asm jmp \@ready;/s &&
$src =~ /asm lda \$33;\s*asm jmp \@ready;/s &&
$font =~ /bank0 const uint8_t wd_glyphs\[80\]/
   or die "WD visible diagnostic lost its compact PASS\/FAIL + WD presentation or released selector idiom\n";

my $mk=read_file($example_make);
$mk =~ /^play:\s*\$\(TARGET\)\s*$/m && $mk =~ /^\s*stella\s+-bs\s+WD\s+\$\(TARGET\)\s*$/m
   or die "WD play target must force Stella -bs WD\n";
my $pt=read_file($profile);
$pt =~ /alias\s+VCS_TIA_USE_40_MIRROR\s+1/ &&
(()=$pt =~ /\bbank\s+bank\d+\s*\{/g)==8 &&
$pt =~ /\$signature:WD\b/ && $pt !~ /\$select_access:/ &&
$pt =~ /bank\s+bank3\s*\{.*?\$file_index:3.*?\$link_start:0xfc00.*?\$cpu_start:0x1c00.*?\$startup/s &&
$pt =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$cpu_start:0x1000/s &&
$pt =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$cpu_start:0x1400/s &&
$pt =~ /bank\s+bank2\s*\{.*?\$file_index:2.*?\$cpu_start:0x1800/s &&
$pt =~ /mem\s+cartram\s*\{.*?\$read_start:0xf000.*?\$write_start:0xf040.*?\$size:0x0040/s
   or die "WD C26 profile does not describe corrected 8x1K plus split 64-byte RAM topology\n";
my $ct=read_file($cfg);
$ct =~ /mapper\s*=\s*WD/ && (()=$ct =~ /size\s*=\s*\$0400/g)==8 &&
$ct =~ /BANK3:.*fileindex\s*=\s*3.*startup\s*=\s*yes/is &&
$ct =~ /cartram:.*read_start\s*=\s*\$F000.*write_start\s*=\s*\$F040.*size\s*=\s*\$0040/is
   or die "WD simulator cfg does not describe eight 1K chunks and split RAM\n";

my $bin=File::Spec->catfile($tmp,'wd.bin');
my $map_path=File::Spec->catfile($tmp,'wd.map');
require_ok('build WD simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST',
   '-T',$generic,'-Map',$map_path,$source,'-o',$bin);
-s $bin==8192 or die "WD output size is not corrected 8K\n";
my $rom=read_file($bin);
substr($rom,8192-8,4) eq "WD\0\0" or die "WD signature is missing from physical chunk 7\n";
for my $fb (0..6) {
   substr($rom,$fb*1024+1016,4) ne "WD\0\0" or die "WD signature duplicated into physical chunk $fb\n";
}
index($rom,"\xA5\x39\x4C")>=0 or die "WD ROM lacks released-cart LDA \$39 / JMP selector signature\n";
my $map=read_file($map_path);
$map =~ /^\s+bank3\s+file-index=3\b.*cpu=\$1C00.*mode=wd-segmented.*startup=yes/m &&
$map !~ /^TRAMPOLINES$/m &&
$map =~ /BSS\.cartram\.__vcsc_object\$wd_ram run=\$F000 write=\$F040 size=\$0040/
   or die "WD map lost segmented topology or split RAM\n$map";
for my $i (qw(0 1 2 4 7)) { map_symbol($map,"bank${i}_probe"); }
my %sym=map { $_=>map_symbol($map,$_) } qw(simulator_done failure call_count wd_ram);
my($out,$err)=require_ok('simulate WD arrangements and RAM',$sim,'-T',$cfg,
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$err eq '' or die "WD simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($out);
$mem->[$sym{failure}]==0 or die sprintf("WD self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{call_count}]==8 or die "WD did not execute all expected physical-chunk probes\n";
$mem->[0xF000]==0x5A && $mem->[0xF03F]==0xA5
   or die "WD split cartridge RAM boundary bytes did not persist\n";

# Delay fixture: selector code executes in segment 1, where arrangement 0 maps
# physical chunk 0 and arrangement 1 maps chunk 1. The full JMP following
# LDA $39 must still be fetched from chunk 0; chunk 1 has a different JMP at
# the same offset, making an early switch observable without relying on HLT.
my $delay=File::Spec->catfile($tmp,'wd-delay.bin');
my $r=("\xFF" x 8192);
# chunk 3 / $1D00: enter segment-1 code; success/failure/stop remain in fixed chunk 3
substr($r,3*1024+0x100,3)=pack('C*',0x4C,0x00,0x15); # JMP $1500
substr($r,3*1024+0x110,7)=pack('C*',0xA9,0xAA,0x85,0x80,0x4C,0x30,0x1D);
substr($r,3*1024+0x120,7)=pack('C*',0xA9,0xEE,0x85,0x80,0x4C,0x30,0x1D);
# config 0 segment 1 == chunk 0: canonical released selector then success JMP
substr($r,0*1024+0x100,5)=pack('C*',0xA5,0x39,0x4C,0x10,0x1D);
# config 1 segment 1 == chunk 1: poison the post-selector JMP if switching is immediate
substr($r,1*1024+0x102,3)=pack('C*',0x4C,0x20,0x1D);
substr($r,3*1024+0x3fc,2)=pack('C*',0x00,0x1D);
write_file($delay,$r);
my($dout,$derr)=require_ok('simulate WD delayed arrangement latch',$sim,'-T',$cfg,
   '--stop-pc=0x1D30','--dump-on-stop',$delay);
$derr eq '' or die "WD delayed-latch fixture wrote stderr:\n$derr";
my $dmem=parse_hex_dump($dout);
$dmem->[0x0080]==0xAA
   or die sprintf("WD selector became visible too early: marker=\$%02X\n",$dmem->[0x0080]);

my $visible=File::Spec->catfile($tmp,'wd-visible.bin');
my $visible_map=File::Spec->catfile($tmp,'wd-visible.map');
require_ok('build visible WD PASS/FAIL cartridge',$driver,'-I',$vcs,'-T',$generic,
   '-Map',$visible_map,$source,'-o',$visible);
my $vrom=read_file($visible);
length($vrom)==8192 && substr($vrom,-8,4) eq "WD\0\0"
   or die "visible WD diagnostic lost its corrected 8K/signature layout\n";
my $vmap=read_file($visible_map);
$vmap =~ /CODE\.bank2\.__vcsc_function\$draw_result.*bank=bank2/s &&
$vmap =~ /RODATA\.bank0\.__vcsc_object\$wd_glyphs.*bank=bank0/s
   or die "visible WD diagnostic is not deliberately split across arrangement-1 chunks\n";
my $s26=File::Spec->catfile($tmp,'wd-visible.s26');
require_ok('disassemble WD cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: WD \(high confidence;/m &&
$dis =~ /^; reset\/power-on bank: 3 \(WD configuration-0 vector bank\)$/m &&
$dis =~ /^; WD cartridge RAM: read \$1000-\$103F, write \$1040-\$107F \(64 bytes\)$/m &&
$dis =~ /^; WD selector reads: TIA \$30-\$3F choose one of eight four-segment 1K arrangements$/m
   or die "vcsc-disas did not recognize corrected WD semantics\n$dis";
my $rt_in=File::Spec->catdir($tmp,'roundtrip-in');
my $rt_out=File::Spec->catdir($tmp,'roundtrip-out');
make_path($rt_in,$rt_out);
copy($visible,File::Spec->catfile($rt_in,'wd-visible.bin')) or die "copy WD roundtrip input: $!\n";
require_ok('round-trip WD cartridge',$^X,$roundtrip,$rt_in,$rt_out);
read_file(File::Spec->catfile($rt_out,'wd-visible.bin')) eq $vrom
   or die "WD disassembler round trip is not byte-exact\n";

if ($stella_mode) {
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella or die "WD Stella certification requires Stella\n";
   my $xvfb=find_executable('Xvfb') or die "WD Stella certification requires Xvfb\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   my $snap=File::Spec->catdir($tmp,'stella-snap'); my $user=File::Spec->catdir($tmp,'stella-user');
   make_path($snap,$user); unlink glob(File::Spec->catfile($snap,'*.png'));
   my $display_num=180+($$%40); $display_num++ while -e "/tmp/.X11-unix/X$display_num";
   my $display=':'.$display_num;
   my $xpid=fork(); defined($xpid) or die "fork Xvfb: $!\n";
   if ($xpid==0) { open(STDOUT,'>',File::Spec->catfile($tmp,'xvfb.log')) or die $!; open(STDERR,'>&STDOUT') or die $!; exec($xvfb,$display,'-ac','-screen','0','1600x1200x24'); die "exec Xvfb: $!\n"; }
   select undef,undef,undef,0.20;
   my $xdg=File::Spec->catdir($tmp,'xdg'); make_path($xdg);
   local $ENV{DISPLAY}=$display; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$tmp;
   local $ENV{XDG_CONFIG_HOME}=$xdg; local $ENV{SDL_AUDIODRIVER}='dummy';
   my $pid=fork(); defined($pid) or die "fork Stella: $!\n";
   if ($pid==0) {
      open(STDOUT,'>',File::Spec->catfile($tmp,'stella.log')) or die $!; open(STDERR,'>&STDOUT') or die $!;
      exec($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs','WD',
           '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
           '-exitlauncher','0','-confirmexit','0','-userdir',$user,$visible);
      die "exec Stella: $!\n";
   }
   select undef,undef,undef,0.35;
   require_ok('snapshot WD in Stella',$^X,$keys);
   my @png; for (1..40) { @png=grep { -s $_ } glob(File::Spec->catfile($snap,'*.png')); last if @png==1; select undef,undef,undef,0.05; }
   terminate_child($pid); terminate_child($xpid);
   @png==1 or die "Stella WD produced ".scalar(@png)." snapshots\n";
   require_ok('grade WD Stella frame',$^X,$grade,$png[0],'pass','WD');
}

print "WD diagnostic passed\n";
