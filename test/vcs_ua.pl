#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: UA/UASW diagnostics passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Copy qw(copy);
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

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $sim=File::Spec->catfile($repo,'simulator','vcsc-sim');
my $disas=File::Spec->catfile($repo,'disassembler','vcsc-disas');
my $roundtrip=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $generic=File::Spec->catfile($vcs,'vcs.cfg');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','09_ua');
my $example_make=File::Spec->catfile($example_dir,'Makefile');

my $mk=read_file($example_make);
$mk =~ /^play-ua:\s*ua_diagnostic\.bin\s*$/m &&
$mk =~ /^\s*stella\s+-bs\s+UA\s+ua_diagnostic\.bin\s*$/m &&
$mk =~ /^play-uasw:\s*uasw_diagnostic\.bin\s*$/m &&
$mk =~ /^\s*stella\s+-bs\s+UASW\s+uasw_diagnostic\.bin\s*$/m
   or die "UA/UASW play targets must force their exact Stella mapper\n";

my @variants=(
   {
      name=>'ua', mapper=>'UA', profile=>'UA/mapper.c26', cfg=>'UA/mapper.cfg',
      source=>'ua_diagnostic.c26', signature=>"UA\0\0",
      bank0=>0x0220, bank1=>0x0240, alias0=>0x02A0, alias1=>0x02C0,
      selector_comment=>qr/^; UA selectors: \(A & \$1260\)==\$0220->\$0, ==\$0240->\$1; aliases include \$02A0\/\$02C0; bank 0 powers up$/m,
   },
   {
      name=>'uasw', mapper=>'UASW', profile=>'UASW/mapper.c26', cfg=>'UASW/mapper.cfg',
      source=>'uasw_diagnostic.c26', signature=>'UASW',
      bank0=>0x0240, bank1=>0x0220, alias0=>0x02C0, alias1=>0x02A0,
      selector_comment=>qr/^; UASW selectors: UA alias decoder with swapped association \(\$0220->\$1, \$0240->\$0\); bank 0 powers up$/m,
   },
);

for my $v (@variants) {
   my $profile=File::Spec->catfile($vcs,$v->{profile});
   my $cfg=File::Spec->catfile($vcs,$v->{cfg});
   my $source=File::Spec->catfile($example_dir,$v->{source});
   my $pt=read_file($profile);
   my $sig=$v->{mapper} eq 'UA' ? 'UA' : 'UASW';
   $pt =~ /\$signature:\Q$sig\E\b/ &&
   $pt =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x[0-9a-fA-F]+\s+\$startup/s &&
   $pt =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x[0-9a-fA-F]+/s
      or die "$v->{mapper} profile topology/startup contract is wrong\n";
   my $ct=read_file($cfg);
   $ct =~ /mapper\s*=\s*\Q$v->{mapper}\E/ &&
   $ct =~ /BANK0:.*hotspot\s*=\s*\$[0-9A-Fa-f]+.*fileindex\s*=\s*0.*startup\s*=\s*yes/is &&
   $ct =~ /BANK1:.*hotspot\s*=\s*\$[0-9A-Fa-f]+.*fileindex\s*=\s*1/is
      or die "$v->{mapper} simulator cfg contract is wrong\n";

   my $bin=File::Spec->catfile($tmp,"$v->{name}.bin");
   my $map=File::Spec->catfile($tmp,"$v->{name}.map");
   require_ok("build $v->{mapper} simulator diagnostic",$driver,'-I',$vcs,'-DSIMULATOR_TEST',
      '-T',$generic,'-Map',$map,$source,'-o',$bin);
   -s $bin==8192 or die "$v->{mapper} output size is not 8K\n";
   my $rom=read_file($bin);
   substr($rom,4096+0x0ff8,4) eq $v->{signature}
      or die "$v->{mapper} signature is missing from final physical bank\n";
   substr($rom,0x0ff8,4) ne $v->{signature}
      or die "$v->{mapper} signature was duplicated into physical bank 0\n";

   # Reset/NMI/IRQ bridge must be identical in both physical banks and select
   # physical bank 0 with the non-destructive below-window absolute-NOP read.
   my $bridge=substr($rom,0x0fe0,0x12);
   substr($rom,4096+0x0fe0,0x12) eq $bridge
      or die "$v->{mapper} vector bridge differs between physical banks\n";
   for my $off (0,6,12) {
      my $lo=$v->{bank0}&0xff; my $hi=($v->{bank0}>>8)&0xff;
      substr($bridge,$off,4) eq pack('C*',0x0c,$lo,$hi,0x4c)
         or die sprintf("%s vector bridge does not use NOP-read \$%04X; JMP\n",$v->{mapper},$v->{bank0});
   }
   my $tramp=substr($rom,0x0f00,0x00e0) . substr($rom,4096+0x0f00,0x00e0);
   for my $sel ($v->{bank0},$v->{bank1}) {
      my($lo,$hi)=($sel&0xff,($sel>>8)&0xff);
      index($tramp,pack('C*',0x0c,$lo,$hi))>=0
         or die sprintf("%s trampolines never read selector \$%04X\n",$v->{mapper},$sel);
      index($tramp,pack('C*',0x8d,$lo,$hi))<0
         or die sprintf("%s trampolines write below-window selector \$%04X\n",$v->{mapper},$sel);
   }

   my $m=read_file($map);
   $m =~ /^\s+bank0\s+file-index=0\b.*mode=selector\s+select-access=\$[0-9A-Fa-f]{4}\s+startup=yes/m &&
   $m =~ /^\s+bank1\s+file-index=1\b.*mode=selector\s+select-access=\$[0-9A-Fa-f]{4}/m &&
   $m =~ /^TRAMPOLINES$/m
      or die "$v->{mapper} map topology/trampoline contract is wrong\n$m";
   my %sym=map { $_=>map_symbol($m,$_) } qw(simulator_done failure trace call_count);
   for my $start (0..1) {
      my($out,$err)=require_ok("simulate $v->{mapper} from physical bank $start",$sim,'-T',$cfg,
         "--start-bank=$start",sprintf('--stop-pc=0x%04X',$sym{simulator_done}),
         '--dump-on-stop',$bin);
      $err eq '' or die "$v->{mapper} simulator start bank $start wrote stderr:\n$err";
      my $mem=parse_hex_dump($out);
      $mem->[$sym{failure}]==0
         or die sprintf("%s self-test from bank %d failed: failure=\$%02X\n",$v->{mapper},$start,$mem->[$sym{failure}]);
      $mem->[$sym{trace}]==3 && $mem->[$sym{call_count}]==2
         or die "$v->{mapper} nested selector/return trace failed from physical bank $start\n";
   }

   # Alias certification: write through the alias that selects bank 1, then in
   # bank 1 perform a read through the opposite alias to select bank 0 again.
   # The write must also reach the underlying console address, proving mapper
   # decode doesn't swallow the TIA/RIOT-side transaction.
   my $alias_bin=File::Spec->catfile($tmp,"$v->{name}-aliases.bin");
   my $raw=("\xFF" x 8192);
   my($a1lo,$a1hi)=($v->{alias1}&0xff,($v->{alias1}>>8)&0xff);
   my($a0lo,$a0hi)=($v->{alias0}&0xff,($v->{alias0}>>8)&0xff);
   substr($raw,0,5)=pack('C*',0xA9,0x5A,0x8D,$a1lo,$a1hi);
   substr($raw,4096+5,3)=pack('C*',0xAD,$a0lo,$a0hi);
   substr($raw,8,8)=pack('C*',0xA9,0xC0,0x8D,0x82,0x00,0x4C,0x0D,0xF0);
   for my $fb (0..1) { substr($raw,$fb*4096+0x0ffc,2)=pack('C*',0x00,0xF0); }
   write_file($alias_bin,$raw);
   my($aout,$aerr)=require_ok("simulate $v->{mapper} alias read/write",$sim,'-T',$cfg,
      '--start-bank=0','--stop-pc=0xF00D','--dump-on-stop',$alias_bin);
   $aerr eq '' or die "$v->{mapper} alias simulator wrote stderr:\n$aerr";
   my $amem=parse_hex_dump($aout);
   $amem->[0x0082]==0xC0 && $amem->[$v->{alias1}]==0x5A
      or die "$v->{mapper} alias read/write switching or underlying write-through failed\n";

   my $visible=File::Spec->catfile($tmp,"$v->{name}-visible.bin");
   require_ok("build visible $v->{mapper} PASS/FAIL cartridge",$driver,'-I',$vcs,'-T',$generic,$source,'-o',$visible);
   my $vrom=read_file($visible);
   length($vrom)==8192 && substr($vrom,4096+0x0ff8,4) eq $v->{signature}
      or die "$v->{mapper} visible diagnostic lost its signature/layout\n";

   my $s26=File::Spec->catfile($tmp,"$v->{name}-visible.s26");
   require_ok("disassemble $v->{mapper} cartridge",$disas,'-o',$s26,$visible);
   my $dis=read_file($s26);
   $dis =~ /^; mapper: \Q$v->{mapper}\E \(high confidence;/m &&
   $dis =~ /^; reset\/power-on bank: 0 \(UA hardware default\)$/m &&
   $dis =~ $v->{selector_comment}
      or die "vcsc-disas did not recognize $v->{mapper} semantics\n$dis";

   my $rt_in=File::Spec->catdir($tmp,"roundtrip-$v->{name}-in");
   my $rt_out=File::Spec->catdir($tmp,"roundtrip-$v->{name}-out");
   make_path($rt_in,$rt_out);
   copy($visible,File::Spec->catfile($rt_in,"$v->{name}-visible.bin"))
      or die "copy $v->{mapper} roundtrip input: $!\n";
   require_ok("round-trip $v->{mapper} cartridge",$^X,$roundtrip,$rt_in,$rt_out);
   read_file(File::Spec->catfile($rt_out,"$v->{name}-visible.bin")) eq $vrom
      or die "$v->{mapper} disassembler round trip is not byte-exact\n";
}

print "UA/UASW diagnostics passed\n";
