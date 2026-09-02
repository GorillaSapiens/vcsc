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
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','09_ua');
my $example_make=File::Spec->catfile($example_dir,'Makefile');
my $common_source=File::Spec->catfile($example_dir,'ua_diagnostic_common.c26');

my $mk=read_file($example_make);
my $common=read_file($common_source);
for my $src_bank (0..1) {
   $common =~ /bank$src_bank\s+void\s+source_entry$src_bank\s*\(void\)\s*\{(.*?)\n\}/s
      or die "UA/UASW diagnostic is missing source_entry$src_bank\n";
   my $body=$1;
   for my $dst_bank (0..1) {
      $body =~ /call_target$dst_bank\s*\(\)/
         or die "UA/UASW diagnostic source_entry$src_bank does not call target $dst_bank\n";
   }
}
$mk =~ /^play-ua:\s*ua_diagnostic\.bin\s*$/m &&
$mk =~ /^\s*stella\s+-bs\s+UA\s+ua_diagnostic\.bin\s*$/m &&
$mk =~ /^play-uasw:\s*uasw_diagnostic\.bin\s*$/m &&
$mk =~ /^\s*stella\s+-bs\s+UASW\s+uasw_diagnostic\.bin\s*$/m
   or die "UA/UASW play targets must force their exact Stella mapper\n";

my @variants=(
   {
      name=>'ua', mapper=>'UA', profile=>'UA/mapper.c26',
      source=>'ua_diagnostic.c26', signature=>"UA\0\0",
      bank0=>0x0220, bank1=>0x0240, desc0=>0x20, desc1=>0x40, alias0=>0x02A0, alias1=>0x02C0,
      selector_comment=>qr/^; UA selectors: \(A & \$1260\)==\$0220->\$0, ==\$0240->\$1; aliases include \$02A0\/\$02C0; bank 0 powers up$/m,
   },
   {
      name=>'uasw', mapper=>'UASW', profile=>'UASW/mapper.c26',
      source=>'uasw_diagnostic.c26', signature=>'UASW',
      bank0=>0x0240, bank1=>0x0220, desc0=>0x40, desc1=>0x20, alias0=>0x02C0, alias1=>0x02A0,
      selector_comment=>qr/^; UASW selectors: UA alias decoder with swapped association \(\$0220->\$1, \$0240->\$0\); bank 0 powers up$/m,
   },
);

for my $v (@variants) {
   my $profile=File::Spec->catfile($vcs,$v->{profile});
   my $source=File::Spec->catfile($example_dir,$v->{source});
   my $pt=read_file($profile);
   my $sig=$v->{mapper} eq 'UA' ? 'UA' : 'UASW';
   my $select0=sprintf('%04x',$v->{bank0});
   my $select1=sprintf('%04x',$v->{bank1});
   my $desc0=sprintf('%02x',$v->{desc0});
   my $desc1=sprintf('%02x',$v->{desc1});
   $pt =~ /\$signature:\Q$sig\E\b/ &&
   $pt =~ /cartridge\s*\{\s*\$bankcall/s &&
   index($pt,'VCSC_INLINE_BANKCALL') < 0 &&
   $pt =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x\Q$select0\E\s+\$bankcall_descriptor:0x\Q$desc0\E\s+\$startup/s &&
   $pt =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x\Q$select1\E\s+\$bankcall_descriptor:0x\Q$desc1\E/s
      or die "$v->{mapper} descriptor profile topology/startup contract is wrong\n";

   my $bin=File::Spec->catfile($tmp,"$v->{name}.bin");
   my $map=File::Spec->catfile($tmp,"$v->{name}.map");
   require_ok("build $v->{mapper} simulator diagnostic",$driver,'-I',$vcs,'-DSIMULATOR_TEST','-Map',$map,$source,'-o',$bin);
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
   my $lst=$bin; $lst =~ s/\.bin\z/.lst/; $lst=read_file($lst);
   my @descriptor=($v->{desc0},$v->{desc1});
   for my $destination (0..1) {
      my $desc=sprintf('%02x',$descriptor[$destination]);
      my $count=()=$lst =~ /^\s*\d+\s+[0-9a-f]{4}\s+[0-9a-f]{2}\s+[0-9a-f]{2}\s+\Q$desc\E\s+; \.banktarget call_target\Q$destination\E\b/gmi;
      $count==1
         or die "$v->{mapper} destination bank $destination descriptor payload count is $count, expected 1\n";
   }
   my @trampoline=map { substr($rom,$_ * 4096 + 0x0f00,0x48) } 0..1;
   my @source_diff=grep {
      my $off=$_;
      ord(substr($trampoline[0],$off,1)) != ord(substr($trampoline[1],$off,1));
   } 0..0x47;
   @source_diff==1
      or die "$v->{mapper} descriptor trampoline copies do not differ at exactly one source-descriptor byte\n";
   for my $bank (0..1) {
      ord(substr($trampoline[$bank],$source_diff[0],1))==$descriptor[$bank]
         or die sprintf("%s bank %d baked source descriptor is not \$%02X\n",$v->{mapper},$bank,$descriptor[$bank]);
      (()=$trampoline[$bank] =~ /\x1C\x00\x02/sg)>=2 &&
      index($trampoline[$bank],pack('C*',0x99,0x00,0x02))<0 &&
      index($trampoline[$bank],pack('C*',0x9D,0x00,0x02))<0
         or die "$v->{mapper} inline bank-call block does not use read-only descriptor selectors from \$0200\n";
   }

   $lst =~ /\[bank bank0\] \| call_return := call_target0\(\);\n[^\n]*; JSR call_target0[^\n]*\n(?![^\n]*\.banktarget)/ &&
   $lst =~ /\[bank bank0\] \| call_return := call_target1\(\);\n[^\n]*; JSR call_target1[^\n]*\n[^\n]*; \.banktarget call_target1/ &&
   $lst =~ /\[bank bank1\] \| call_return := call_target0\(\);\n[^\n]*; JSR call_target0[^\n]*\n[^\n]*; \.banktarget call_target0/ &&
   $lst =~ /\[bank bank1\] \| call_return := call_target1\(\);\n[^\n]*; JSR call_target1[^\n]*\n(?![^\n]*\.banktarget)/
      or die "$v->{mapper} diagnostic did not keep same-bank calls as ordinary JSRs and cross-bank calls as inline bundles\n";

   my $m=read_file($map);
   $m =~ /^\s+bank0\s+file-index=0\b.*mode=selector\s+select-access=\$[0-9A-Fa-f]{4}\s+startup=yes/m &&
   $m =~ /^\s+bank1\s+file-index=1\b.*mode=selector\s+select-access=\$[0-9A-Fa-f]{4}/m &&
   $m =~ /^TRAMPOLINES$/m &&
   $m =~ /generic-jsr=\$048\b.*\bentries=0\s+jmp=0\s+jsr=0\b/ &&
   $m !~ /JSR entry=/
      or die "$v->{mapper} map topology/inline-trampoline contract is wrong\n$m";
   my %sym=map { $_=>map_symbol($m,$_) } qw(simulator_done failure call_count nested_count);
   for my $start (0..1) {
      my($out,$err)=require_ok("simulate $v->{mapper} from physical bank $start",$sim,'--map',$map,
         "--start-bank=$start",sprintf('--stop-pc=0x%04X',$sym{simulator_done}),
         '--dump-on-stop',$bin);
      $err eq '' or die "$v->{mapper} simulator start bank $start wrote stderr:\n$err";
      my $mem=parse_hex_dump($out);
      $mem->[$sym{failure}]==0
         or die sprintf("%s self-test from bank %d failed: failure=\$%02X\n",$v->{mapper},$start,$mem->[$sym{failure}]);
      $mem->[$sym{call_count}]==4 && $mem->[$sym{nested_count}]==1
         or die "$v->{mapper} full ordered call matrix/nested return failed from physical bank $start\n";
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
   my($aout,$aerr)=require_ok("simulate $v->{mapper} alias read/write",$sim,'--map',$map,
      '--start-bank=0','--stop-pc=0xF00D','--dump-on-stop',$alias_bin);
   $aerr eq '' or die "$v->{mapper} alias simulator wrote stderr:\n$aerr";
   my $amem=parse_hex_dump($aout);
   $amem->[0x0082]==0xC0 && $amem->[$v->{alias1}]==0x5A
      or die "$v->{mapper} alias read/write switching or underlying write-through failed\n";

   my $visible=File::Spec->catfile($tmp,"$v->{name}-visible.bin");
   require_ok("build visible $v->{mapper} PASS/FAIL cartridge",$driver,'-I',$vcs,$source,'-o',$visible);
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
