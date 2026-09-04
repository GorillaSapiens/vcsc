#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 180
# expectstdout: 3EX max diagnostic passed: 512K ROM, 256K RAM, 65535 ROM calls, complete 256-bank RAM walk, 262-line display
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
   my($so,$se)=('','');
   my $out_fd=fileno($out);
   my $sel=IO::Select->new($out,$err);
   while ($sel->count) {
      for my $fh ($sel->can_read) {
         my $buf='';
         my $n=sysread($fh,$buf,8192);
         if (defined($n) && $n>0) {
            if (fileno($fh)==$out_fd) { $so.=$buf; } else { $se.=$buf; }
         } else {
            $sel->remove($fh);
            close($fh);
         }
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
sub map_symbol {
   my($map,$name)=@_; $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map missing $name\n"; return hex($1);
}

sub require_ok_logged {
   my($label,$stdout_path,$stderr_path,@cmd)=@_;
   open(my $saveout, '>&', \*STDOUT) or die "dup stdout: $!\n";
   open(my $saveerr, '>&', \*STDERR) or die "dup stderr: $!\n";
   open(STDOUT, '>', $stdout_path) or die "write $stdout_path: $!\n";
   open(STDERR, '>', $stderr_path) or die "write $stderr_path: $!\n";
   system @cmd;
   my($rc,$sig)=($? >> 8,$? & 127);
   open(STDOUT, '>&', $saveout) or die "restore stdout: $!\n";
   open(STDERR, '>&', $saveerr) or die "restore stderr: $!\n";
   close($saveout); close($saveerr);
   return if $rc==0 && !$sig;
   my $out=read_file($stdout_path);
   my $err=read_file($stderr_path);
   die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $dir=File::Spec->catdir($repo,qw(examples 09_bankswitching 20_3ex_max));
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $bin=File::Spec->catfile($tmp,'3ex_max.bin');
my $map_path=File::Spec->catfile($tmp,'3ex_max.map');
my $objdir=File::Spec->catdir($tmp,'obj');
for ($dir,$driver,$vcs) { -e $_ or die "missing 3EX max support $_\n"; }

# Build independent translation units in parallel, then link the complete
# maximum image.  This is also the regression for the startup-table placement
# estimator: swapram BSS must not be mistaken for CPU startup-zero records.
require_ok_logged('build 3EX max diagnostic',
   File::Spec->catfile($tmp,'build.stdout'),File::Spec->catfile($tmp,'build.stderr'),
   'make','-C',$dir,'-j8','VCSC='.$driver,'VCS_DIR='.$vcs,
   'BUILD_DIR='.$objdir,'TARGET='.$bin,'MAP='.$map_path);
-s $bin==524288 or die "3EX max output is not exactly 512K\n";
my $rom=read_file($bin);
my $marker_count=()=$rom =~ /3EX/g;
$marker_count==2 or die "3EX max ROM contains $marker_count detector markers, expected exactly 2\n";
# Mirror Stella's CartDetector::searchForBytes stride exactly: after a match it
# skips the signature bytes and the for-loop then advances one more byte.
# Adjacent 3EX3EX therefore counts as only one hit in Stella.
my $stella_marker_hits=0;
for (my $i=0; $i < length($rom)-3; ++$i) {
   if (substr($rom,$i,3) eq '3EX') {
      ++$stella_marker_hits;
      last if $stella_marker_hits==2;
      $i += 3;
   }
}
$stella_marker_hits==2
   or die "3EX max detector markers are not independently visible to Stella\n";
ord(substr($rom,-6,1))==0xff or die "3EX max size-6 RAM-bank-count metadata is not 255\n";

my $map=read_file($map_path);
my %file_index;
while ($map =~ /^\s+bank(\d+)\s+file-index=(\d+)\b/mg) { $file_index{$1}=0+$2; }
keys(%file_index)==256 or die "3EX max map does not contain 256 physical ROM banks\n";
for my $bank (0..255) {
   exists($file_index{$bank}) && $file_index{$bank}==$bank
      or die "3EX max map lost physical ROM bank $bank/file-index identity\n";
}
$map =~ /^\s+bank255\s+file-index=255\b.*cpu=\$1800.*startup=yes/m
   or die "3EX max fixed/startup ROM bank is not physical bank 255\n";
$map =~ /^\s+swapram\s+logical_size=\$40000\b.*bank_size=\$0400\s+banks=256\b/m
   or die "3EX max map lost 256 x 1K swapram geometry\n";
$map =~ /^\s+swapram\s+used=262144 bytes \(100\.00%\).*objects=262144 bytes/m
   or die "3EX max does not allocate the complete 256K swapram pool\n";

# Linker selection order is dependency driven, so ram_NNN names do not promise
# physical bank N.  What matters is a one-to-one allocation over every hardware
# selector value 0..255, with each object exactly one 1K bank at offset zero.
my (%logical_seen,%physical_seen);
while ($map =~ /^\s+BSS\.swapram\.__vcsc_object\$ram_(\d{3})\s+logical=\$([0-9A-Fa-f]+)\s+swapram-bank=(\d+)\s+swapram-offset=\$([0-9A-Fa-f]+)\s+size=\$([0-9A-Fa-f]+)\b/mg) {
   my($logical,$addr,$physical,$offset,$size)=(0+$1,hex($2),0+$3,hex($4),hex($5));
   $logical <= 255 or die "3EX max unexpected logical RAM object ram_$1\n";
   !$logical_seen{$logical}++ or die "3EX max duplicate logical RAM object $logical\n";
   !$physical_seen{$physical}++ or die "3EX max duplicate physical RAM bank $physical\n";
   $offset==0 && $size==1024 or die "3EX max RAM object $logical is not one aligned 1K bank\n";
   $addr < 0x40000 or die "3EX max RAM object $logical lies outside 256K logical swapram\n";
}
for my $bank (0..255) {
   $logical_seen{$bank} or die "3EX max map lost logical RAM object $bank\n";
   $physical_seen{$bank} or die "3EX max map does not exercise physical RAM bank $bank\n";
}
$map =~ /^\s*\$[0-9A-Fa-f]{4}\s+swapram_read1\b/m &&
$map =~ /^\s*\$[0-9A-Fa-f]{4}\s+swapram_write1\b/m
   or die "3EX max link lost compiler-selected swapram helpers\n";
$map !~ /^\s+ZERO\s+BSS\.swapram/m
   or die "3EX swapram BSS leaked into the CPU startup-zero table\n";

# Independently check the exact LFSR used by the 256K fill/readback oracle.
my $lfsr=0xACE1;
my $period=0;
do {
   $lfsr=(($lfsr >> 1) ^ (($lfsr & 1) ? 0xB400 : 0)) & 0xffff;
   ++$period;
   $period <= 65535 or die "3EX max LFSR exceeded maximal 16-bit period\n";
} while ($lfsr != 0xACE1);
$period==65535 or die "3EX max LFSR period is $period, expected 65535\n";
for (1..262144) {
   $lfsr=(($lfsr >> 1) ^ (($lfsr & 1) ? 0xB400 : 0)) & 0xffff;
}
$lfsr==0x1c4e or die sprintf("3EX max 256K LFSR endpoint changed to \$%04X\n",$lfsr);

my $timing_source=File::Spec->catfile($repo,qw(test vcs_frame_timing.cpp));
my $mos_dir=File::Spec->catdir($repo,qw(simulator mos6502));
my $mos_source=File::Spec->catfile($mos_dir,'mos6502.cpp');
my $timing=File::Spec->catfile($tmp,'vcs_frame_timing_3ex_max');
require_ok('compile 3EX max frame timing','g++','-O2','-std=c++17','-Wall','-Wextra','-Werror','-pedantic',
   '-DILLEGAL_OPCODES','-I'.$mos_dir,$timing_source,$mos_source,'-o',$timing);

# The visible cartridge deliberately throttles RAM work to fit VBLANK/overscan,
# so executing its full 256K fill+verify takes roughly 85,000 frames.  The
# fixed torture object therefore carries a regression-only fast entry that runs
# the exact same ROM matrix and compiler-lowered swapram scheduler without frame
# pacing.  Patch only a copy's RESET vector; the shipped diagnostic binary and
# all linked code/data remain byte-for-byte otherwise identical.
my %sym=map { $_=>map_symbol($map,$_) } qw(__vcsc_3ex_max_fast_entry __vcsc_3ex_max_fast_done failure torture_count ram_phase ram_bank ram_index ram_lfsr ram_failure_bank);
my $fast_bin=File::Spec->catfile($tmp,'3ex_max_fast.bin');
my $fast_rom=$rom;
substr($fast_rom,-4,2)=pack('v',$sym{__vcsc_3ex_max_fast_entry});
open(my $fast_fh,'>:raw',$fast_bin) or die "write $fast_bin: $!\n";
print {$fast_fh} $fast_rom or die "write $fast_bin: $!\n";
close($fast_fh) or die "close $fast_bin: $!\n";
my @memory_oracle=(
   '--expect-memory',sprintf('0x%04X',$sym{failure}),'0',
   '--expect-memory',sprintf('0x%04X',$sym{torture_count}),'0xff',
   '--expect-memory',sprintf('0x%04X',$sym{torture_count}+1),'0xff',
   '--expect-memory',sprintf('0x%04X',$sym{ram_phase}),'3',
   '--expect-memory',sprintf('0x%04X',$sym{ram_bank}),'0',
   '--expect-memory',sprintf('0x%04X',$sym{ram_index}),'0',
   '--expect-memory',sprintf('0x%04X',$sym{ram_index}+1),'0',
   '--expect-memory',sprintf('0x%04X',$sym{ram_lfsr}),'0x4e',
   '--expect-memory',sprintf('0x%04X',$sym{ram_lfsr}+1),'0x1c',
   '--expect-memory',sprintf('0x%04X',$sym{ram_failure_bank}),'0',
);
my($sim_out,$sim_err)=require_ok('execute complete 3EX max torture',$timing,$fast_bin,'10',
   '--stop-pc',sprintf('0x%04X',$sym{__vcsc_3ex_max_fast_done}),'--no-audio',@memory_oracle);
$sim_out =~ /^vcs_frame_timing stop ok: pc=\$[0-9a-fA-F]{4} after [1-9][0-9]* instructions\n\z/
   or die "3EX max fast oracle returned unexpected output:\n$sim_out";
$sim_err eq '' or die "3EX max fast oracle wrote stderr:\n$sim_err";

# Independently exercise thousands of scheduler-owned visible frames.  The
# complete state transition is certified above; this pass owns the display
# contract and catches any batch that steals a scanline while the torture runs.
my($timing_out,$timing_err)=require_ok('time 3EX max wait frames',$timing,$bin,'4000',
   '--no-audio','--raw-lines','264');
$timing_out eq "vcs_frame_timing ok: 3997 frames at 262 lines, 0 AUDV0 writes\n"
   or die "3EX max WAIT frame timing was not exactly 262 scanlines:\n$timing_out";
$timing_err eq '' or die "3EX max frame timing wrote stderr:\n$timing_err";

print "3EX max diagnostic passed: 512K ROM, 256K RAM, 65535 ROM calls, complete 256-bank RAM walk, 262-line display\n";
