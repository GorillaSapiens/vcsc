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
my $profile=File::Spec->catfile($vcs,'WD/mapper.c26');
my $inline=File::Spec->catfile($vcs,'WD/inline_bankcall.s26');
my $example_dir=File::Spec->catdir($repo,'examples','09_bankswitching','15_wd');
my $source=File::Spec->catfile($example_dir,'wd_diagnostic.c26');
my $example_make=File::Spec->catfile($example_dir,'Makefile');

my $src=read_file($source);
my $status_font=read_file(File::Spec->catfile($example_dir,'status_font.c26'));
my $cart_font=read_file(File::Spec->catfile($example_dir,'cart_type_font.c26'));
$src =~ /instantiate "six_glyph_big_wide_component\.c26" as status_result \(initial_color:=0\)/ &&
$src =~ /instantiate "six_glyph_component\.c26" as cart_type \(compact_font:=0\)/ &&
$src =~ /bank0 void draw_result\(void\)/ &&
$src =~ /bank0 void main\(void\)/ &&
$src !~ /asm\s+lda\s+\$3[0-9a-f]/i &&
$status_font =~ /bank0 const uint8_t status_glyphs\[128\]/ &&
$cart_font =~ /bank0 const uint8_t cart_type_glyphs\[24\]/
   or die "WD visible diagnostic lost its big\/wide PASS\/FAIL plus small WD presentation or reintroduced manual selector reads\n";

my $mk=read_file($example_make);
$mk =~ /BIG_FONT := .*big_ascii\.c26/ &&
$mk =~ /SMALL_FONT := .*default_ascii\.c26/ &&
$mk =~ /status_font\.c26 status_glyphs ' pasFAIL'/ &&
$mk =~ /cart_type_font\.c26 cart_type_glyphs ' WD'/ &&
$mk =~ /^play:\s*\$\(TARGET\)\s*$/m && $mk =~ /^\s*stella\s+-bs\s+WD\s+\$\(TARGET\)\s*$/m
   or die "WD Makefile lost generated big PASS\/FAIL fonts, small WD font, or forced Stella mapper\n";

my $pt=read_file($profile);
$pt =~ /VCSC DELIBERATELY DOES NOT expose those eight hardware arrangements as eight\s+\/\/ compiler banks/s &&
$pt =~ /VCSC bank0 == WD state 1 == physical chunks 0,1,2,3/ &&
$pt =~ /VCSC bank1 == WD state 2 == physical chunks 4,5,6,7/ &&
$pt =~ /alias\s+VCS_TIA_USE_40_MIRROR\s+1/ &&
$pt =~ /\$inline_bankcall/ &&
(()=$pt =~ /\bbank\s+bank\d+\s*\{/g)==2 &&
$pt =~ /\$signature:WD\b/ &&
$pt =~ /bank\s+bank0\s*\{.*?\$image_size:0x1000\s+\$file_index:0\s+\$image_offset:0x0080.*?\$link_start:0xf080\s+\$cpu_start:0xf080\s+\$map_size:0x0f80.*?\$select_access:0x0039\s+\$bankcall_descriptor:0x01\s+\$startup/s &&
$pt =~ /bank\s+bank1\s*\{.*?\$image_size:0x1000\s+\$file_index:1\s+\$image_offset:0x0080.*?\$link_start:0xd080\s+\$cpu_start:0xf080\s+\$map_size:0x0f80.*?\$select_access:0x003a\s+\$bankcall_descriptor:0x02/s &&
$pt =~ /mem\s+cartram\s*\{.*?\$read_start:0xf000.*?\$write_start:0xf040.*?\$size:0x0040/s
   or die "WD C26 profile does not expose the deliberate two-logical-bank ABI plus always-live split RAM\n";
my $inline_text=read_file($inline);
$inline_text =~ /VCSC_BANKCALL_SELECTOR_BASE = \$0038/ &&
$inline_text =~ /VCSC_BANKCALL_SOURCE_DESCRIPTOR = \$01/ &&
(()=$inline_text =~ /lda VCSC_BANKCALL_SELECTOR_BASE,y/g)==2 &&
$inline_text =~ /__vcsc_generic_bankcall_reserved_end = \$6048/
   or die "WD descriptor trampoline source does not encode the delayed-selector two-bank ABI\n";

my $bin=File::Spec->catfile($tmp,'wd.bin');
my $map_path=File::Spec->catfile($tmp,'wd.map');
require_ok('build WD simulator diagnostic',$driver,'-I',$vcs,'-DSIMULATOR_TEST','-Map',$map_path,$source,'-o',$bin);
-s $bin==8192 or die "WD output size is not corrected 8K\n";
my $rom=read_file($bin);
substr($rom,8192-8,4) eq "WD\0\0" or die "WD signature is missing from physical chunk 7\n";
substr($rom,4096-8,4) ne "WD\0\0" or die "WD signature was duplicated into logical bank0 / physical chunk 3\n";

# The power-on state-0 top segment is physical chunk 3, exactly where logical
# bank0's bridge lives. Every replicated bridge first NOP-reads $39 (state 1)
# before jumping into the ordinary startup vector target.
my $bridge=substr($rom,0x0fe0,0x12);
substr($rom,4096+0x0fe0,0x12) eq $bridge
   or die "WD vector bridge differs between logical banks\n";
for my $off (0,6,12) {
   substr($bridge,$off,4) eq pack('C*',0x0c,0x39,0x00,0x4c)
      or die "WD vector bridge does not use NOP-read \$0039; JMP\n";
}

my $lst=$bin; $lst =~ s/\.bin\z/.lst/; $lst=read_file($lst);
my %descriptor=(bank0_nested_leaf=>'01',bank1_probe=>'02',bank1_nested=>'02');
for my $target (sort keys %descriptor) {
   my $desc=$descriptor{$target};
   my $count=()=$lst =~ /^\s*\d+\s+[0-9a-f]{4}\s+[0-9a-f]{2}\s+[0-9a-f]{2}\s+\Q$desc\E\s+; \.banktarget \Q$target\E\b/gmi;
   $count==1 or die "WD cross-bank target $target descriptor payload count is $count, expected 1\n";
}
$lst =~ /; JSR bank0_probe\b[^\n]*\n(?![^\n]*\.banktarget)/
   or die "WD same-bank bank0_probe call stopped being an ordinary JSR\n";

my @trampoline=map { substr($rom,$_ * 4096 + 0x0f00,0x48) } 0..1;
my @source_diff=grep {
   my $off=$_;
   ord(substr($trampoline[0],$off,1)) != ord(substr($trampoline[1],$off,1));
} 0..0x47;
@source_diff==1
   or die "WD descriptor trampoline copies do not differ at exactly one source-descriptor byte\n";
ord(substr($trampoline[0],$source_diff[0],1))==0x01 &&
ord(substr($trampoline[1],$source_diff[0],1))==0x02
   or die "WD logical-bank source descriptors are not 1 and 2\n";
for my $copy (@trampoline) {
   (()=$copy =~ /\xB9\x38\x00/sg)>=2
      or die "WD inline bank-call block does not use read-only indexed selectors from \$0038\n";
}

my $map=read_file($map_path);
$map =~ /^\s+bank0\s+file-index=0\b.*image-size=\$1000.*image-offset=\$0080.*link=\$F080.*cpu=\$F080.*mode=selector.*select-access=\$0039.*startup=yes/m &&
$map =~ /^\s+bank1\s+file-index=1\b.*image-size=\$1000.*image-offset=\$0080.*link=\$D080.*cpu=\$F080.*mode=selector.*select-access=\$003A/m &&
$map =~ /BSS\.cartram\.__vcsc_object\$wd_ram run=\$F000 write=\$F040 size=\$0040/ &&
$map =~ /^TRAMPOLINES$/m &&
$map =~ /generic-jsr=\$048\b.*\bentries=0\s+jmp=0\s+jsr=0\b/ &&
$map !~ /JSR entry=/
   or die "WD map lost two-logical-bank topology, split RAM, or fixed descriptor trampoline\n$map";
my %sym=map { $_=>map_symbol($map,$_) } qw(simulator_done failure call_count nested_count wd_ram);
my($out,$err)=require_ok('simulate WD logical-bank calls and RAM',$sim,'--map',$map_path,
   sprintf('--stop-pc=0x%04X',$sym{simulator_done}),'--dump-on-stop',$bin);
$err eq '' or die "WD simulator wrote stderr:\n$err";
my $mem=parse_hex_dump($out);
$mem->[$sym{failure}]==0 or die sprintf("WD self-test failed: failure=\$%02X\n",$mem->[$sym{failure}]);
$mem->[$sym{call_count}]==2 && $mem->[$sym{nested_count}]==2
   or die "WD descriptor calls did not preserve the bank0 -> bank1 -> bank0 nested return chain\n";
$mem->[0xF000]==0x5A && $mem->[0xF03F]==0xA5
   or die "WD always-live split cartridge RAM boundary bytes did not persist\n";

# Delayed-latch fixture: selector code executes in segment 1, where arrangement
# 0 maps physical chunk 0 and arrangement 1 maps chunk 1. The complete JMP after
# LDA $39 must still be fetched from chunk 0; chunk 1 poisons the same location
# so an incorrectly immediate switch is observable.
my $delay=File::Spec->catfile($tmp,'wd-delay.bin');
my $r=("\xFF" x 8192);
substr($r,3*1024+0x100,3)=pack('C*',0x4C,0x00,0x15); # top chunk3 -> $1500
substr($r,3*1024+0x110,7)=pack('C*',0xA9,0xAA,0x85,0x80,0x4C,0x30,0x1D);
substr($r,3*1024+0x120,7)=pack('C*',0xA9,0xEE,0x85,0x80,0x4C,0x30,0x1D);
substr($r,0*1024+0x100,5)=pack('C*',0xA5,0x39,0x4C,0x10,0x1D);
substr($r,1*1024+0x102,3)=pack('C*',0x4C,0x20,0x1D);
substr($r,3*1024+0x3fc,2)=pack('C*',0x00,0x1D);
write_file($delay,$r);
my($dout,$derr)=require_ok('simulate WD delayed arrangement latch',$sim,'--map',$map_path,
   '--stop-pc=0x1D30','--dump-on-stop',$delay);
$derr eq '' or die "WD delayed-latch fixture wrote stderr:\n$derr";
my $dmem=parse_hex_dump($dout);
$dmem->[0x0080]==0xAA
   or die sprintf("WD selector became visible too early: marker=\$%02X\n",$dmem->[0x0080]);

# The compiler ABI exposes only states 1 and 2, but the simulator still models
# all real WD hardware states for hand-written assembly. From power-on state 0,
# select state 3 ($3B), whose segment 0 is physical chunk 7, then execute there.
my $manual=File::Spec->catfile($tmp,'wd-state3.bin');
my $q=("\xFF" x 8192);
substr($q,3*1024+0x100,5)=pack('C*',0xA5,0x3B,0x4C,0x00,0x11); # select state3, jump $1100
substr($q,7*1024+0x100,7)=pack('C*',0xA9,0x3B,0x85,0x81,0x4C,0x30,0x1D);
substr($q,3*1024+0x130,3)=pack('C*',0x4C,0x30,0x1D);
substr($q,3*1024+0x3fc,2)=pack('C*',0x00,0x1D);
write_file($manual,$q);
my($mout,$merr)=require_ok('simulate manual WD state 3',$sim,'--map',$map_path,
   '--stop-pc=0x1D30','--dump-on-stop',$manual);
$merr eq '' or die "WD state-3 fixture wrote stderr:\n$merr";
my $mmem=parse_hex_dump($mout);
$mmem->[0x0081]==0x3B
   or die "WD simulator no longer exposes non-ABI hardware arrangement 3 to manual assembly\n";

my $visible=File::Spec->catfile($tmp,'wd-visible.bin');
my $visible_map=File::Spec->catfile($tmp,'wd-visible.map');
require_ok('build visible WD PASS/FAIL cartridge',$driver,'-I',$vcs,
   '-Map',$visible_map,$source,'-o',$visible);
my $vrom=read_file($visible);
length($vrom)==8192 && substr($vrom,-8,4) eq "WD\0\0"
   or die "visible WD diagnostic lost its corrected 8K/signature layout\n";
my $vmap=read_file($visible_map);
$vmap =~ /CODE\.bank0\.__vcsc_function\$draw_result.*bank=bank0/s &&
$vmap =~ /RODATA\.bank0\.__vcsc_object\$status_glyphs.*bank=bank0/s &&
$vmap =~ /RODATA\.bank0\.__vcsc_object\$cart_type_glyphs.*bank=bank0/s &&
$vmap =~ /generic-jsr=\$048\b.*\bentries=0\s+jmp=0\s+jsr=0\b/
   or die "visible WD diagnostic is not using bank0 display data plus the fixed descriptor ABI\n";
my $s26=File::Spec->catfile($tmp,'wd-visible.s26');
require_ok('disassemble WD cartridge',$disas,'-o',$s26,$visible);
my $dis=read_file($s26);
$dis =~ /^; mapper: WD \(high confidence;/m &&
$dis =~ /^; reset\/power-on bank: 3 \(WD configuration-0 vector bank\)$/m &&
$dis =~ /^; WD cartridge RAM: read \$1000-\$103F, write \$1040-\$107F \(64 bytes\)$/m &&
$dis =~ /^; WD selector reads: TIA \$30-\$3F choose one of eight four-segment 1K arrangements$/m
   or die "vcsc-disas did not retain the actual eight-arrangement WD hardware semantics\n$dis";
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
