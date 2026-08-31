#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 240
# expectstdout: C26 cartridge profiles passed
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
my $testlib=File::Spec->catdir($repo,'test');
my $generic_cfg=File::Spec->catfile($vcs,'vcs.cfg');
my $blank=File::Spec->catfile($repo,'examples','01_basic','01_blank_screen','blank_screen.c26');

my @profiles=(
   ['2K',   '2K/mapper.c26',       undef,              1, 0, 0,  2048],
   ['CV',   'CV/mapper.c26',    'CV/mapper.cfg',    1, 0, 0,  2048],
   ['4K',   '4K/mapper.c26',       '4K/mapper.cfg',       1, 0, 0,  4096],
   ['4KSC', '4KSC/mapper.c26',    undef,              1, 0, 1,  4096],
   ['F8',   'F8/mapper.c26',    'F8/mapper.cfg',    2, 1, 0,  8192],
   ['0840', '0840/mapper.c26',  undef,               2, 1, 0,  8192],
   ['UA',   'UA/mapper.c26',    undef,               2, 1, 0,  8192],
   ['UASW', 'UASW/mapper.c26',  undef,               2, 1, 0,  8192],
   ['0FA0', '0FA0/mapper.c26',  undef,               2, 1, 0,  8192],
   ['E0',   'E0/mapper.c26',    undef,              8, 0, 0,  8192],
   ['FE',   'FE/mapper.c26',    undef,    2, 0, 0,  8192],
   ['WD',   'WD/mapper.c26',    undef,    8, 0, 0,  8192],
   ['3F',   '3F/mapper_8k.c26',    undef,    4, 0, 0,  8192],
   ['3E',   '3E/mapper_8k.c26',    undef,    4, 0, 0,  8192],
   ['F6',   'F6/mapper.c26',   'F6/mapper.cfg',   4, 1, 0, 16384],
   ['JANE', 'JANE/mapper.c26', undef,               4, 1, 0, 16384],
   ['F4',   'F4/mapper.c26',   'F4/mapper.cfg',   8, 1, 0, 32768],
   ['FA',   'FA/mapper.c26',    'FA/mapper.cfg',    3, 1, 0, 12288],
   ['FA2',  'FA2/mapper_28k.c26',   undef,                7, 1, 0, 28672],
   ['F8SC', 'F8SC/mapper.c26',  'F8SC/mapper.cfg',  2, 1, 1,  8192],
   ['F6SC', 'F6SC/mapper.c26', 'F6SC/mapper.cfg', 4, 1, 1, 16384],
   ['F4SC', 'F4SC/mapper.c26', 'F4SC/mapper.cfg', 8, 1, 1, 32768],
   ['OMNI', 'OMNI/mapper.c26', undef,              8, 0, 0, 32768],
);

-f $generic_cfg or die "generic VCS compatibility cfg is missing\n";
my $cfg_text=read_file($generic_cfg);
$cfg_text =~ /callstack\s*=\s*callgraph/ && $cfg_text !~ /\b(?:CARTRIDGE|BANKS|SEGMENTS)\s*\{/s
   or die "vcs.cfg is not the reduced operational compatibility cfg\n";

for my $p (@profiles) {
   my($name,$profile_name,$legacy_name,$banks,$selector,$sc,$output_size)=@$p;
   my $profile=File::Spec->catfile($vcs,$profile_name);
   my $legacy=defined($legacy_name) ? File::Spec->catfile($vcs,$legacy_name) : undef;
   -f $profile or die "$profile_name is missing\n";
   defined($legacy_name) && !-f $legacy and die "$legacy_name compatibility profile is missing\n";
   my $text=read_file($profile);
   $text =~ /include\s+"vcs\.c26"/ && $text =~ /\bcartridge\s*\{/ && $text =~ /\bbank\s+bank0\s*\{/s
      or die "$profile_name is not a complete inspectable C26 cartridge profile\n";
   my $bank_decls=()=$text =~ /\bbank\s+bank\d+\s*\{/g;
   $bank_decls==$banks or die "$profile_name declares $bank_decls banks, expected $banks\n";
   my $selectors=()=$text =~ /\$select_access:/g;
   $selectors==($selector ? $banks : 0)
      or die "$profile_name selector count is wrong\n";
   if ($sc) {
      $text =~ /include\s+"4KSC\/ram\.c26"/ &&
      $text =~ /\$image_offset:0x0100/ &&
      $text =~ /\$cpu_start:0xf100/
         or die "$profile_name does not encode the Superchip prefix and shared RAM profile\n";
      if ($name eq '4KSC') {
         $text =~ /\$size:0x0ef8/
            or die "4KSC does not reserve vectors inside its direct ROM window\n";
      } else {
         $text =~ /\$size:0x0e00/
            or die "$profile_name banked SC ROM size is wrong\n";
      }
   } else {
      $text !~ /include\s+"4KSC\/ram\.c26"/
         or die "$profile_name unexpectedly includes Superchip memory\n";
   }

   my $stem=lc($name); $stem =~ s/[^a-z0-9]+/_/g;
   my $generic_bin=File::Spec->catfile($tmp,"$stem.generic.bin");
   my $generic_map=File::Spec->catfile($tmp,"$stem.generic.map");
   my $build_source=$blank;
   if ($text =~ /alias\s+VCS_TIA_USE_40_MIRROR\s+1/) {
      $build_source=File::Spec->catfile($tmp,"blank_screen_${stem}.c26");
      my $blank_text=read_file($blank);
      $blank_text =~ s/include\s+"vcs\.c26"/alias VCS_TIA_USE_40_MIRROR 1\ninclude "vcs.c26"/;
      open(my $fh,'>',$build_source) or die "open $build_source: $!\n";
      print $fh $blank_text; close($fh);
   }
   require_ok("build $name from C26 topology and reduced cfg",
      $driver,'-I',$vcs,'-T',$generic_cfg,
      '-Map',$generic_map,$profile,$build_source,'-o',$generic_bin);
   -s $generic_bin==$output_size
      or die "$name C26 profile emitted ".(-s $generic_bin)." bytes, expected $output_size\n";

   if ($name =~ /^(?:CV|4KSC|F8|0840|UA|UASW|0FA0|E0|FE|WD|3F|3E|F6|JANE|F4|FA|FA2|F8SC|F6SC|F4SC|OMNI)$/) {
      my $rom=read_file($generic_bin);
      my $want=$name . ("\0" x (4-length($name)));
      substr($rom,-8,4) eq $want
         or die "$name final-bank signature is not NUL-padded at \$xFF8-\$xFFB\n";
      if ($banks > 1) {
         my $bank_size = int($output_size / $banks);
         for my $file_bank (0..$banks-2) {
            substr($rom,$file_bank*$bank_size+$bank_size-8,4) ne $want
               or die "$name signature was duplicated into file bank $file_bank\n";
         }
      }
      $text =~ /\$signature:\Q$name\E\b/
         or die "$name profile does not declare its cartridge signature\n";
   }

   if ($name eq '2K') {
      my $rom=read_file($generic_bin);
      my @vectors=unpack('v3',substr($rom,-6));
      !grep { $_ < 0xf800 } @vectors
         or die "2K vectors are not linked into the canonical \$F800-\$FFFF mapping\n";
   }

   if (defined $legacy_name) {
      my $legacy_bin=File::Spec->catfile($tmp,"$stem.legacy.bin");
      require_ok("differential build $name with legacy cfg",
         $driver,'-I',$vcs,'-T',$legacy,
         $profile,$build_source,'-o',$legacy_bin);
      read_file($generic_bin) eq read_file($legacy_bin)
         or die "$name C26 profile and legacy cfg do not emit identical cartridges
";
   }

   my $map=read_file($generic_map);
   $map =~ /^C26 CARTRIDGE TOPOLOGY$/m
      or die "$name map does not report C26 topology\n";
   $map =~ /output-size=\$[0-9A-F]{8}/
      or die "$name map does not report topology output size\n";
   my @file_order = $name =~ /^(?:E0|WD)$/ ? (0..7) : $name =~ /^(?:3F|3E|FA2|JANE)$/ ? (0..$banks-1) : $name =~ /^(?:0840|UA|UASW|FE)$/ ? (0,1) : reverse(0..$banks-1);
   for my $logical (0..$banks-1) {
      my $file_index=$file_order[$logical];
      $map =~ /^\s+bank\Q$logical\E\s+file-index=\Q$file_index\E\b/m
         or die "$name map does not preserve bank$logical file ordering\n";
   }
   if ($selector) {
      $map =~ /^CARTRIDGE\n\s+mapper=C26\b/m && $map =~ /mode=selector/
         or die "$name did not derive selector-controlled linker machinery from C26\n";
   } elsif ($name eq 'FE') {
      $map =~ /mode=fe-delayed/ && $map !~ /^TRAMPOLINES$/m
         or die "FE profile did not preserve delayed-latch topology\n";
   } elsif ($name eq 'WD') {
      $map =~ /mode=wd-segmented/ && $map !~ /^TRAMPOLINES$/m
         or die "WD profile did not preserve segmented arrangement topology\n";
   } else {
      $map =~ /mode=direct/ && $map !~ /^TRAMPOLINES$/m
         or die "$name direct profile unexpectedly generated switching machinery\n";
   }
   if ($sc) {
      $map =~ /^\s+cartram\s+.*output-bank=<none> mode=shared\b/m
         or die "$name does not retain Superchip as shared memory\n";
      my $rom=read_file($generic_bin);
      for my $file_bank (0..$banks-1) {
         substr($rom,$file_bank*4096,256) eq ("\xFF" x 256)
            or die "$name file bank $file_bank does not retain the reserved Superchip prefix\n";
      }
   }
   if ($name eq 'CV') {
      $text =~ /include\s+"CV\/ram\.c26"/ &&
      $text =~ /\$image_size:0x0800/ &&
      $text =~ /\$cpu_start:0xf800/
         or die "CV profile does not encode the fixed 2K ROM shape\n";
      $map =~ /^\s+cartram\s+read_start=\$F000 write_start=\$F400 size=\$0400 type=rw shared=yes\b/m
         or die "CV map does not retain split-address cartridge RAM\n";
   }
   if ($name eq 'JANE') {
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x1ff0/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x1ff1\s+\$startup/s &&
      $text =~ /bank\s+bank2\s*\{.*?\$file_index:2.*?\$select_access:0x1ff8/s &&
      $text =~ /bank\s+bank3\s*\{.*?\$file_index:3.*?\$select_access:0x1ff9/s
         or die "JANE profile does not preserve logical/physical identity and startup bank1\n";
      $map =~ /^\s+bank0\s+file-index=0\b.*select-access=\$1FF0/m &&
      $map =~ /^\s+bank1\s+file-index=1\b.*select-access=\$1FF1.*startup=yes/m
         or die "JANE map does not preserve logical/physical identity and startup bank1\n";
   }
   if ($name eq '0840') {
      $text =~ /\$vector_bridge_offset:0x0fe0\s+\$vector_bridge_size:0x0012/ &&
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x0800\s+\$startup/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x0840/s
         or die "0840 profile does not preserve below-window selectors/startup bank\n";
      $map =~ /^\s+bank0\s+file-index=0\b.*select-access=\$0800.*startup=yes/m &&
      $map =~ /^\s+bank1\s+file-index=1\b.*select-access=\$0840/m
         or die "0840 map does not preserve selector/file order\n";
   }
   if ($name eq 'UA') {
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x0220\s+\$startup/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x0240/s
         or die "UA profile does not preserve alias-family selectors/startup bank\n";
      $map =~ /^\s+bank0\s+file-index=0\b.*select-access=\$0220.*startup=yes/m &&
      $map =~ /^\s+bank1\s+file-index=1\b.*select-access=\$0240/m
         or die "UA map does not preserve selector/file order\n";
   }
   if ($name eq 'UASW') {
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x0240\s+\$startup/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x0220/s
         or die "UASW profile does not preserve swapped selectors/startup bank\n";
      $map =~ /^\s+bank0\s+file-index=0\b.*select-access=\$0240.*startup=yes/m &&
      $map =~ /^\s+bank1\s+file-index=1\b.*select-access=\$0220/m
         or die "UASW map does not preserve swapped selector/file order\n";
   }
   if ($name eq '0FA0') {
      $text =~ /\$vector_bridge_offset:0x0fe0\s+\$vector_bridge_size:0x0012/ &&
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:1.*?\$select_access:0x0fc0\s+\$startup/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$file_index:0.*?\$select_access:0x0fa0/s &&
      $text =~ /\(A & \$16E0\)/
         or die "0FA0 profile does not preserve masked selectors/startup bank\n";
      $map =~ /^\s+bank0\s+file-index=1\b.*select-access=\$0FC0.*startup=yes/m &&
      $map =~ /^\s+bank1\s+file-index=0\b.*select-access=\$0FA0/m
         or die "0FA0 map does not preserve selector/file order\n";
   }

   if ($name eq 'E0') {
      $text =~ /bank\s+bank7\s*\{.*?\$file_index:7.*?\$cpu_start:0x1c00.*?\$startup/s &&
      $text =~ /bank\s+bank0\s*\{.*?\$cpu_start:0x1000/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$cpu_start:0x1400/s &&
      $text =~ /bank\s+bank2\s*\{.*?\$cpu_start:0x1800/s &&
      $text !~ /\$select_access:/
         or die "E0 profile does not preserve segmented 8x1K topology/fixed bank 7\n";
      $map =~ /^\s+bank7\s+file-index=7\b.*cpu=\$1C00.*startup=yes/m &&
      $map !~ /^TRAMPOLINES$/m
         or die "E0 map does not preserve fixed top bank/no fake whole-window trampolines\n";
   }

   if ($name eq 'FE') {
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$link_start:0xf000.*?\$cpu_start:0xf000.*?\$startup/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$link_start:0xd000.*?\$cpu_start:0xd000/s &&
      $text !~ /\$select_access:/
         or die "FE profile does not preserve the released two-bank delayed-latch topology\n";
      $map =~ /^\s+bank0\s+file-index=0\b.*cpu=\$F000.*mode=fe-delayed.*startup=yes/m &&
      $map =~ /^\s+bank1\s+file-index=1\b.*cpu=\$D000.*mode=fe-delayed/m &&
      $map !~ /^TRAMPOLINES$/m
         or die "FE map does not preserve startup/file order or delayed mode\n";
   }

   if ($name eq 'WD') {
      $text =~ /bank\s+bank3\s*\{.*?\$file_index:3.*?\$link_start:0xfc00.*?\$cpu_start:0x1c00.*?\$startup/s &&
      $text =~ /bank\s+bank7\s*\{.*?\$file_index:7.*?\$link_start:0xd000.*?\$cpu_start:0x1000/s &&
      $text !~ /\$select_access:/ &&
      $text =~ /alias\s+VCS_TIA_USE_40_MIRROR\s+1/ &&
      $text =~ /mem\s+cartram\s*\{.*?\$read_start:0xf000.*?\$write_start:0xf040.*?\$size:0x0040/s
         or die "WD profile does not preserve corrected 8x1K arrangement plus 64-byte split RAM topology\n";
      $map =~ /^\s+bank3\s+file-index=3\b.*cpu=\$1C00.*mode=wd-segmented.*startup=yes/m &&
      $map =~ /^\s+bank7\s+file-index=7\b.*cpu=\$1000.*mode=wd-segmented/m &&
      $map =~ /^\s+cartram\s+read_start=\$F000 write_start=\$F040 size=\$0040 type=rw shared=yes\b/m &&
      $map !~ /^TRAMPOLINES$/m
         or die "WD map does not preserve corrected chunk order, startup mapping, or split RAM\n";
   }

   if ($name =~ /^(?:3F|3E)$/) {
      $text =~ /bank\s+bank3\s*\{.*?\$file_index:3.*?\$cpu_start:0x1800.*?\$startup/s &&
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$cpu_start:0x1000/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$cpu_start:0x1000/s &&
      $text =~ /bank\s+bank2\s*\{.*?\$file_index:2.*?\$cpu_start:0x1000/s &&
      $text !~ /\$select_access:/
         or die "$name profile does not preserve selectable-lower/fixed-final 2K topology\n";
      $map =~ /^\s+bank3\s+file-index=3\b.*cpu=\$1800.*startup=yes/m &&
      $map !~ /^TRAMPOLINES$/m
         or die "$name map does not preserve fixed final bank/no fake trampolines\n";
      $text =~ /alias\s+VCS_TIA_USE_40_MIRROR\s+1/
         or die "$name profile does not select the safe TIA mirror binding\n";
   }

   if ($name eq 'JANE') {
      $text =~ /\$vector_bridge_offset:0x0ee0\s+\$vector_bridge_size:0x0012/ &&
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$select_access:0x1ff0/s &&
      $text =~ /bank\s+bank1\s*\{.*?\$file_index:1.*?\$select_access:0x1ff1\s+\$startup/s &&
      $text =~ /bank\s+bank2\s*\{.*?\$file_index:2.*?\$select_access:0x1ff8/s &&
      $text =~ /bank\s+bank3\s*\{.*?\$file_index:3.*?\$select_access:0x1ff9/s
         or die "JANE profile does not preserve logical/physical identity and startup bank1\n";
   }
   if ($name eq 'FA2') {
      $text =~ /include\s+"FA\/ram\.c26"/ &&
      $text =~ /bank\s+bank0\s*\{.*?\$file_index:0.*?\$image_offset:0x0200.*?\$select_access:0x1ff5\s+\$startup/s &&
      $text =~ /bank\s+bank6\s*\{.*?\$file_index:6.*?\$select_access:0x1ffb/s
         or die "FA2 profile does not encode six/seven-bank RAM-port topology\n";
      $map =~ /^\s+cartram\s+read_start=\$F100 write_start=\$F000 size=\$0100 type=rw shared=yes\b/m
         or die "FA2 map does not retain split-address cartridge RAM\n";
      my $rom=read_file($generic_bin);
      for my $file_bank (0..6) {
         substr($rom,$file_bank*4096,512) eq ("\xFF" x 512)
            or die "FA2 file bank $file_bank does not retain the reserved RAM-port prefix\n";
      }
   }
   if ($name eq 'FA') {
      $text =~ /include\s+"FA\/ram\.c26"/ &&
      $text =~ /\$image_offset:0x0200/ &&
      $text =~ /\$cpu_start:0xf200/ &&
      $text =~ /\$size:0x0d00/
         or die "FA profile does not encode the 512-byte RAM-port prefix\n";
      $map =~ /^\s+cartram\s+read_start=\$F100 write_start=\$F000 size=\$0100 type=rw shared=yes\b/m
         or die "FA map does not retain split-address cartridge RAM\n";
      my $rom=read_file($generic_bin);
      for my $file_bank (0..2) {
         substr($rom,$file_bank*4096,512) eq ("\xFF" x 512)
            or die "FA file bank $file_bank does not retain the reserved RAM-port prefix\n";
      }
   }
}

# The driver default is now the same explicit 4K C26 profile plus reduced cfg.
my $default_bin=File::Spec->catfile($tmp,'default.bin');
my $explicit_bin=File::Spec->catfile($tmp,'explicit4k.bin');
require_ok('build implicit default 4K profile',$driver,'-I',$vcs,$blank,'-o',$default_bin);
require_ok('build explicit default 4K profile',$driver,'-I',$vcs,
   '-T',$generic_cfg,File::Spec->catfile($vcs,'4K/mapper.c26'),$blank,'-o',$explicit_bin);
read_file($default_bin) eq read_file($explicit_bin)
   or die "implicit and explicit 4K C26 profile builds differ\n";

# A direct-only package proves file order, fill, absolute cross-chunk calls, and no hotspots.
my $direct_src=File::Spec->catfile($tmp,'direct.c26');
write_file($direct_src,<<'SRC');
include "vcs_direct_8k.c26"
bank1 const uint8_t marker := 0x42;
bank1 uint8_t helper(void) { return marker; }
void main(void) {
   uint8_t value := helper();
   COLUBK := value;
   asm @forever:;
   asm jmp @forever;
}
SRC
my $direct_bin=File::Spec->catfile($tmp,'direct.bin');
my $direct_map=File::Spec->catfile($tmp,'direct.map');
require_ok('build direct two-chunk C26 package',$driver,'-I',$vcs,'-I',$testlib,
   '-T',$generic_cfg,'-Map',$direct_map,$direct_src,'-o',$direct_bin);
-s $direct_bin==8192 or die "direct profile did not emit two physical 4K chunks\n";
my $direct=read_file($direct_bin);
my $dmap=read_file($direct_map);
$dmap =~ /^\s+bank1\s+file-index=0\b.*mode=direct/m &&
$dmap =~ /^\s+bank0\s+file-index=1\b.*mode=direct/m &&
$dmap =~ /^\s+\$3001\s+helper\b/m &&
$dmap =~ /^\s+\$3000\s+marker\b/m &&
$dmap =~ /^BANK PLACEMENT$/m && $dmap !~ /^TRAMPOLINES$/m &&
$dmap =~ /pinned\s+CODE\.__vcsc_function\$main\s+region=bank0/m &&
$dmap =~ /pinned\s+CODE\.bank1\.__vcsc_function\$helper\s+region=bank1/m
   or die "direct profile map does not show ordinary direct ownership/placement\n";
index(substr($direct,4096),"\x20\x01\x30")>=0
   or die "direct profile did not emit an ordinary JSR to the first file chunk\n";
index($direct,"\xAD\xF8\x1F")==-1 && index($direct,"\xAD\xF9\x1F")==-1
   or die "direct profile emitted selector-hotspot reads\n";
substr($direct,0x12,4096-0x12) eq ("\xFF" x (4096-0x12))
   or die "direct profile did not fill the unused first chunk with the cartridge fill value\n";

# Unqualified direct code must use both directly addressed regions when the
# startup/home region cannot hold every whole function.  The large functions
# are generated here rather than carrying thousands of NOPs in a source file.
my $spill_src=File::Spec->catfile($tmp,'direct_spill.c26');
my $nops = join('', map { "   asm nop;\n" } 1..2000);
write_file($spill_src,
   "include \"vcs_direct_8k.c26\"\n" .
   "uint8_t first(void) {\n$nops   return 1;\n}\n" .
   "uint8_t second(void) {\n$nops   return 2;\n}\n" .
   "void main(void) {\n   COLUBK := first() + second();\n" .
   "   asm \@forever:;\n   asm jmp \@forever;\n}\n");
my $spill_bin=File::Spec->catfile($tmp,'direct_spill.bin');
my $spill_map=File::Spec->catfile($tmp,'direct_spill.map');
require_ok('build automatic direct-region spill',$driver,'-I',$vcs,'-I',$testlib,
   '-T',$generic_cfg,'-Map',$spill_map,$spill_src,'-o',$spill_bin);
my $smap=read_file($spill_map);
$smap =~ /pinned\s+CODE\.__vcsc_function\$main\s+region=bank0/m
   or die "direct automatic placement did not keep main in the startup/home region\n$smap";
$smap =~ /automatic\s+CODE\.__vcsc_function\$(?:first|second)\s+region=bank1/m &&
$smap =~ /automatic\s+CODE\.__vcsc_function\$(?:first|second)\s+region=bank0/m
   or die "direct automatic placement did not spill whole unqualified functions across both regions\n$smap";
$smap !~ /^TRAMPOLINES$/m && $smap !~ /^VECTOR BRIDGES$/m
   or die "direct automatic spill generated switched-bank machinery\n$smap";

print "C26 cartridge profiles passed\n";
