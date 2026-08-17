#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: OMNI 32K direct profile passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
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
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $data=<$fh>; close($fh); return $data // '';
}
sub write_file {
   my($path,$data)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $data or die "write $path: $!\n"; close($fh) or die "close $path: $!\n";
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $cfg=File::Spec->catfile($vcs,'vcs.cfg');
my $profile=File::Spec->catfile($vcs,'vcs_omni_32k.c26');

my $profile_text=read_file($profile);
$profile_text =~ /No real hardware currently supports this configuration/ &&
$profile_text =~ /\$signature:OMNI/ &&
(()=$profile_text =~ /\$image_size:0x1000/g)==8 &&
(()=$profile_text =~ /\$select_access:/g)==0 &&
(()=$profile_text =~ /\$ro\b/g)==7 &&
(()=$profile_text =~ /\$rw\b/g)==1 &&
$profile_text =~ /mem\s+bank7\s*\{\s*\$start:0x1000\s+\$size:0x1000\s+\$rw\s*\}/s
   or die "OMNI profile topology/capability contract is wrong\n";

my $src=File::Spec->catfile($tmp,'omni.c26');
write_file($src,<<'SRC');
include "vcs_omni_32k.c26"
bank6 const uint8_t marker := 0x42;
bank6 uint8_t helper(void) { return marker; }
bank7 uint8_t ram_value := 0x5a;
bank7 uint8_t scratch;
void main(void) {
   scratch := helper();
   ram_value := scratch;
   COLUBK := ram_value;
   asm @forever:;
   asm jmp @forever;
}
SRC

my $bin=File::Spec->catfile($tmp,'omni.bin');
my $map=File::Spec->catfile($tmp,'omni.map');
require_ok('build OMNI direct profile',$driver,'-I',$vcs,'-T',$cfg,'-Map',$map,$src,'-o',$bin);
-s $bin==32768 or die "OMNI profile did not emit exactly 32K\n";
my $rom=read_file($bin);
my $m=read_file($map);

my @addr=(0xf000,0xd000,0xb000,0x9000,0x7000,0x5000,0x3000,0x1000);
for my $bank (0..7) {
   my $file=7-$bank;
   my $addr=sprintf('%04X',$addr[$bank]);
   $m =~ /^\s+bank\Q$bank\E\s+file-index=\Q$file\E\b.*link=\$\Q$addr\E\s+cpu=\$\Q$addr\E\b.*mode=direct/m
      or die "OMNI bank$bank topology/file order is wrong\n";
}
$m =~ /^\s+bank7\s+start=\$1000\s+size=\$1000\s+type=rw\b.*mode=direct/m &&
$m =~ /^\s+bank0\s+start=\$F000\s+size=\$0FF8\s+type=ro\s+priority=2\b.*mode=direct/m
   or die "OMNI RO/RW memory layout is wrong\n";
$m =~ /^\s+\$F000\s+main\b/m &&
$m =~ /^\s+\$3001\s+helper\b/m &&
$m =~ /^\s+\$3000\s+marker\b/m &&
$m =~ /^\s+\$1000\s+scratch\b/m &&
$m =~ /^\s+\$1001\s+ram_value\b/m
   or die "OMNI explicit code/data placement is wrong\n";
$m =~ /^\s+COPY\s+DATA\.bank7\.__vcsc_object\$ram_value\s+load=\$[0-9A-F]{4}\s+read=\$1001\s+write=\$1001\s+size=\$0001/m &&
$m =~ /^\s+ZERO\s+BSS\.bank7\.__vcsc_object\$scratch\s+read=\$1000\s+write=\$1000\s+size=\$0001/m
   or die "OMNI did not reuse normal initialized-DATA/BSS startup semantics\n";
$m !~ /^TRAMPOLINES$/m && $m !~ /^BANK PLACEMENT$/m && $m !~ /^VECTOR BRIDGES$/m
   or die "OMNI direct profile generated switched-bank machinery\n";

substr($rom,0,4096) eq ("\xFF" x 4096)
   or die "OMNI writable file chunk should remain cartridge fill; DATA initializes at startup\n";
substr($rom,0x7ff8,4) eq 'OMNI'
   or die "OMNI final-bank signature is missing\n";
for my $file_bank (0..6) {
   substr($rom,$file_bank*4096+0x0ff8,4) ne 'OMNI'
      or die "OMNI signature was duplicated into file chunk $file_bank\n";
}
index(substr($rom,7*4096),"\x20\x01\x30")>=0
   or die "OMNI cross-island helper call is not an ordinary JSR \$3001\n";
index($rom,"\xAD\x00\x30")>=0
   or die "OMNI helper did not emit an ordinary direct read from cross-island RODATA at \$3000\n";

print "OMNI 32K direct profile passed\n";
