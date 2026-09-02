#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: 3F/3E diagnostics passed
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
my $timing_source=File::Spec->catfile($repo,'test','vcs_frame_timing.cpp');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_3f_3e');
my $mos_dir=File::Spec->catdir($repo,'simulator','mos6502');
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $mos_obj=File::Spec->catfile($mos_dir,'mos6502.o');
require_ok('compile 3F/3E frame timing','g++','-std=c++17','-Wall','-Wextra','-Werror','-pedantic',
   '-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,(-f $mos_obj ? $mos_obj : $mos_source),'-o',$timing);

my @cases=(
   { mapper=>'3F', dir=>'12_3f', source=>'3f_diagnostic.c26', ram=>0 },
   { mapper=>'3E', dir=>'13_3e', source=>'3e_diagnostic.c26', ram=>1 },
);

for my $c (@cases) {
   my $m=$c->{mapper}; my $lc=lc($m);
   my $source=File::Spec->catfile($repo,'examples','09_bankswitching',$c->{dir},$c->{source});
   my $make=File::Spec->catfile($repo,'examples','09_bankswitching',$c->{dir},'Makefile');
   my $profile=File::Spec->catfile($vcs,$m,$m eq '3F' ? 'mapper.c26' : 'mapper_8k.c26');
   my $profile16=File::Spec->catfile($vcs,$m,$m eq '3F' ? 'mapper.c26' : 'mapper_16k.c26');
   for ($source,$make,$profile) { -f $_ or die "$m support file missing: $_\n"; }
   -f $profile16 or die "$m support file missing: $profile16\n";

   my $pt=read_file($profile); my $p16=read_file($profile16);
   if ($m eq '3F') {
      $pt =~ /parameter\s+VCS_3F_BANKS\s*;/ &&
      $pt =~ /cartridge\s*\{.*?\$bankcall.*?\$trampoline_offset:0x0780.*?\$vector_bridge_offset:0x07d0/s &&
      (()=$pt =~ /\bbank\s+bank\d+\s*\{/g)==512 &&
      $pt =~ /#if\s+VCS_3F_BANKS\s*>\s*4.*?bank\s+bank3\s*\{.*?\$file_index:3.*?\$link_start:0x1000.*?\$bankcall_descriptor:0x03.*?#elif\s+VCS_3F_BANKS\s*==\s*4.*?bank\s+bank3\s*\{.*?\$file_index:3.*?\$cpu_start:0x1800.*?\$startup.*?\$bankcall_descriptor:0xff/s &&
      $pt =~ /#elif\s+VCS_3F_BANKS\s*==\s*8.*?bank\s+bank7\s*\{.*?\$file_index:7.*?\$cpu_start:0x1800.*?\$startup.*?\$bankcall_descriptor:0xff/s
         or die "3F parameterized profile lost its canonical selectable/fixed topology ladder\n";
   } else {
      (()=$pt =~ /\bbank\s+bank\d+\s*\{/g)==4 && (()=$p16 =~ /\bbank\s+bank\d+\s*\{/g)==8
         or die "$m profiles do not expose certified 8K and 16K 2K-chunk shapes\n";
      $pt =~ /bank\s+bank3\s*\{.*?\$file_index:3.*?\$cpu_start:0x1800.*?\$startup/s
         or die "$m 8K profile lost fixed-final-2K topology\n";
      $p16 =~ /bank\s+bank7\s*\{.*?\$file_index:7.*?\$cpu_start:0x1800.*?\$startup/s
         or die "$m 16K profile lost fixed-final-2K topology\n";
   }
   $pt =~ /\$signature:\Q$m\E\b/ && $pt !~ /\$select_access:/ &&
   $p16 =~ /\$signature:\Q$m\E\b/ && $p16 !~ /\$select_access:/
      or die "$m profile lost signature/direct segmented topology\n";
   $pt =~ /alias\s+VCS_TIA_USE_40_MIRROR\s+1/ && $p16 =~ /alias\s+VCS_TIA_USE_40_MIRROR\s+1/
      or die "$m profiles must select the safe TIA \$40-\$7F mirror\n";

   my $mk=read_file($make);
   $mk =~ /^play:\s*\$\(TARGET\)\s*$/m && $mk =~ /^\s*stella\s+-bs\s+\Q$m\E\s+\$\(TARGET\)\s*$/m
      or die "$m play target must force Stella -bs $m\n";
   my $src=read_file($source);
   $src =~ /instantiate "six_glyph_big_wide_component\.c26" as status_result/ &&
   $src =~ /instantiate "six_glyph_component\.c26" as cart_type \(compact_font:=0\)/ &&
   $src =~ /bank3 void draw_result\(void\)/
      or die "$m visible diagnostic lost large PASS\/FAIL plus mapper label\n";
   if ($m eq '3F') {
      $src !~ /asm sta \$3f/ &&
      $src =~ /bank0 uint8_t bank0_calls_bank1\(void\).*?bank1_probe/s &&
      $src =~ /bank0 uint8_t bank0_calls_fixed\(void\).*?fixed_calls_bank2/s &&
      $src =~ /bank3 uint8_t fixed_calls_bank2\(void\).*?bank2_probe/s
         or die "3F diagnostic lost automatic fixed/lower nested bank-call coverage\n";
   } else {
      $src =~ /asm lda #0;\s*asm sta \$3e;.*?asm sta \$1400;.*?asm lda \$1000/s &&
      $src =~ /asm lda #1;\s*asm sta \$3e;.*?asm sta \$1400;.*?asm lda \$1000/s &&
      $src =~ /asm lda #2;\s*asm sta \$3f;.*?bank2_probe/s
         or die "3E diagnostic lost ROM/RAM/ROM and split RAM-port coverage\n";
   }

   my $bin=File::Spec->catfile($tmp,"$lc.bin");
   my $map_path=File::Spec->catfile($tmp,"$lc.map");
   require_ok("build $m simulator diagnostic",$driver,'-I',$vcs,'-DSIMULATOR_TEST','-Map',$map_path,$source,'-o',$bin);
   -s $bin==8192 or die "$m diagnostic output size is not 8K\n";
   my $rom=read_file($bin); substr($rom,-8,4) eq "$m\0\0" or die "$m signature missing\n";
   for my $fb (0..2) {
      substr($rom,$fb*2048+2040,4) ne "$m\0\0" or die "$m signature duplicated into physical bank $fb\n";
   }
   my $map=read_file($map_path);
   if ($m eq '3F') {
      $map =~ /^\s+bank3\s+file-index=3\b.*cpu=\$1800.*startup=yes/m &&
      $map =~ /^TRAMPOLINES$/m &&
      $map =~ /^\s+common-offset=\$780\s+reserved=\$050\s+used=\$050.*generic-jsr=\$050/m
         or die "3F map lost fixed-final descriptor-bankcall topology\n";
   } else {
      $map =~ /^\s+bank3\s+file-index=3\b.*cpu=\$1800.*startup=yes/m && $map !~ /^TRAMPOLINES$/m
         or die "$m map lost fixed-final/direct segmented topology\n";
   }
   for my $i (0..2) { map_symbol($map,"bank${i}_probe"); }
   my %sym=map { $_=>map_symbol($map,$_) } qw(simulator_done failure call_count);
   my($out,$err)=require_ok("simulate $m selectors",$sim,'--map',$map_path,
      sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
   $err eq '' or die "$m simulator wrote stderr:\n$err";
   my $mem=parse_hex_dump($out);
   $mem->[$sym{failure}]==0 or die sprintf("$m self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
   $mem->[$sym{call_count}]==($m eq '3F' ? 7 : 4) or die "$m did not execute the expected lower-bank probes\n";

   my $visible=File::Spec->catfile($tmp,"$lc-visible.bin");
   my $visible_map=File::Spec->catfile($tmp,"$lc-visible.map");
   require_ok("build visible $m cartridge",$driver,'-I',$vcs,'-Map',$visible_map,$source,'-o',$visible);
   my $vrom=read_file($visible); length($vrom)==8192 && substr($vrom,-8,4) eq "$m\0\0"
      or die "visible $m diagnostic lost its 8K/signature layout\n";
   my($timing_out,$timing_err)=require_ok("time $m visible frame",$timing,$visible,'50','--no-audio','--raw-lines','264');
   $timing_out eq "vcs_frame_timing ok: 47 frames at 262 lines, 0 AUDV0 writes\n"
      or die "$m frame timing was not exactly 262 scanlines:\n$timing_out";
   $timing_err eq '' or die "$m frame timing wrote stderr:\n$timing_err";
   my $s26=File::Spec->catfile($tmp,"$lc-visible.s26");
   require_ok("disassemble $m cartridge",$disas,'-o',$s26,$visible);
   my $dis=read_file($s26);
   $dis =~ /^; mapper: \Q$m\E \(high confidence;/m
      or die "vcsc-disas did not recognize $m with high confidence\n$dis";
   if ($m eq '3F') {
      $dis =~ /^; 3F segments: \$1000-\$17FF is a value-selected 2K bank; \$1800-\$1FFF is the fixed final physical 2K$/m
         or die "vcsc-disas did not recognize 3F segmented semantics\n$dis";
   } else {
      $dis =~ /^; reset\/power-on bank: 3 \(3E fixed final-2K vector bank; lower ROM bank 0 at power-on\)$/m
         or die "vcsc-disas did not recognize 3E fixed-final semantics\n$dis";
      $dis =~ /^; 3E cartridge RAM: /m
         or die "3E disassembly did not report banked RAM semantics\n";
   }
   $dis =~ /STA VSYNC \+ \$0040\s+; mirror of VSYNC \(\$0000\)/
      or die "$m disassembly did not preserve the required TIA mirror address\n";


   my $rt_in=File::Spec->catdir($tmp,"rt-$lc-in");
   my $rt_out=File::Spec->catdir($tmp,"rt-$lc-out"); make_path($rt_in,$rt_out);
   copy($visible,File::Spec->catfile($rt_in,"$lc.bin")) or die "copy $m roundtrip input: $!\n";
   require_ok("round-trip $m cartridge",$^X,$roundtrip,$rt_in,$rt_out);
   read_file(File::Spec->catfile($rt_out,"$lc.bin")) eq $vrom
      or die "$m disassembler round trip is not byte-exact\n";

   # Prove the second public size really emits eight 2K physical chunks.
   my $blank=File::Spec->catfile($tmp,"$lc-16.c26");
   open(my $bf,'>',$blank) or die $!;
   if ($m eq '3F') {
      print $bf qq{instantiate "3F/mapper.c26" as mapper (VCS_3F_BANKS:=8)\nbank7 void main(void) { while (1) { } }\n};
   } else {
      print $bf qq{include "3E/mapper_16k.c26"\nbank7 void main(void) { while (1) { } }\n};
   }
   close($bf);
   my $bin16=File::Spec->catfile($tmp,"$lc-16.bin");
   require_ok("build 16K $m profile",$driver,'-I',$vcs,$blank,'-o',$bin16);
   -s $bin16==16384 or die "$m 16K profile emitted the wrong size\n";
   substr(read_file($bin16),-8,4) eq "$m\0\0" or die "$m 16K signature missing from final bank\n";

   $c->{visible}=$visible;
}

if ($stella_mode) {
   my $stella=$ENV{VCSC_STELLA} || $ENV{STELLA} || find_executable('stella');
   defined($stella) && -x $stella or die "3F/3E Stella certification requires Stella\n";
   my $xvfb=find_executable('Xvfb') or die "3F/3E Stella certification requires Xvfb\n";
   my $keys=File::Spec->catfile($repo,'test','stella_snapshot_keys.pl');
   my $grade=File::Spec->catfile($repo,'test','stella_grade_bank_snapshot.pl');
   my $display_num=220+($$%20);
   for my $c (@cases) {
      my $m=$c->{mapper}; my $lc=lc($m);
      $display_num++ while -e "/tmp/.X11-unix/X$display_num";
      my $display=':'.$display_num++;
      my $root=File::Spec->catdir($tmp,"stella-$lc");
      my $snap=File::Spec->catdir($root,'snap'); my $user=File::Spec->catdir($root,'user'); my $xdg=File::Spec->catdir($root,'xdg');
      make_path($snap,$user,$xdg); unlink glob(File::Spec->catfile($snap,'*.png'));
      my $xpid=fork(); defined($xpid) or die "fork Xvfb: $!\n";
      if ($xpid==0) { open(STDOUT,'>',File::Spec->catfile($root,'xvfb.log')) or die $!; open(STDERR,'>&STDOUT') or die $!; exec($xvfb,$display,'-ac','-screen','0','1024x768x24'); die "exec Xvfb: $!\n"; }
      select undef,undef,undef,0.20;
      local $ENV{DISPLAY}=$display; local $ENV{XAUTHORITY}='/dev/null'; local $ENV{HOME}=$root;
      local $ENV{XDG_CONFIG_HOME}=$xdg; local $ENV{SDL_AUDIODRIVER}='dummy';
      my $pid=fork(); defined($pid) or die "fork Stella: $!\n";
      if ($pid==0) {
         open(STDOUT,'>',File::Spec->catfile($root,'stella.log')) or die $!; open(STDERR,'>&STDOUT') or die $!;
         exec($stella,'-video','software','-turbo','1','-audio.enabled','0','-bs',$m,
              '-snapsavedir',$snap,'-snapname','rom','-sssingle','1','-ss1x','1',
              '-exitlauncher','0','-confirmexit','0','-userdir',$user,$c->{visible});
         die "exec Stella: $!\n";
      }
      select undef,undef,undef,0.35;
      require_ok("snapshot $m in Stella",$^X,$keys);
      my @png; for (1..40) { @png=grep { -s $_ } glob(File::Spec->catfile($snap,'*.png')); last if @png==1; select undef,undef,undef,0.05; }
      terminate_child($pid); terminate_child($xpid);
      @png==1 or die "Stella $m produced ".scalar(@png)." snapshots\n";
      require_ok("grade $m Stella frame",$^X,$grade,$png[0],'pass',$m);
   }
}

print "3F/3E diagnostics passed\n";
