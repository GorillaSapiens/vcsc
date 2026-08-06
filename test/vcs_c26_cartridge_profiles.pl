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
my $generic_cfg=File::Spec->catfile($vcs,'vcs.cfg');
my $blank=File::Spec->catfile($repo,'examples','01_basic','01_blank_screen','blank_screen.c26');

my @profiles=(
   ['2K',   'vcs_2k.c26',       undef,              1, 0, 0,  2048],
   ['4K',   'vcs_4k.c26',       'vcs_4k.cfg',       1, 0, 0,  4096],
   ['F8',   'vcs_8k_f8.c26',    'vcs_8k_f8.cfg',    2, 1, 0,  8192],
   ['F6',   'vcs_16k_f6.c26',   'vcs_16k_f6.cfg',   4, 1, 0, 16384],
   ['F4',   'vcs_32k_f4.c26',   'vcs_32k_f4.cfg',   8, 1, 0, 32768],
   ['F8SC', 'vcs_8k_f8sc.c26',  'vcs_8k_f8sc.cfg',  2, 1, 1,  8192],
   ['F6SC', 'vcs_16k_f6sc.c26', 'vcs_16k_f6sc.cfg', 4, 1, 1, 16384],
   ['F4SC', 'vcs_32k_f4sc.c26', 'vcs_32k_f4sc.cfg', 8, 1, 1, 32768],
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
      $text =~ /include\s+"superchip\.c26"/ &&
      $text =~ /\$image_offset:0x0100/ &&
      $text =~ /\$cpu_start:0xf100/ &&
      $text =~ /\$size:0x0e00/
         or die "$profile_name does not encode the Superchip prefix and shared RAM profile\n";
   } else {
      $text !~ /include\s+"superchip\.c26"/
         or die "$profile_name unexpectedly includes Superchip memory\n";
   }

   my $stem=lc($name); $stem =~ s/[^a-z0-9]+/_/g;
   my $generic_bin=File::Spec->catfile($tmp,"$stem.generic.bin");
   my $generic_map=File::Spec->catfile($tmp,"$stem.generic.map");
   require_ok("build $name from C26 topology and reduced cfg",
      $driver,'-I',$vcs,'-T',$generic_cfg,
      '-Map',$generic_map,$profile,$blank,'-o',$generic_bin);
   -s $generic_bin==$output_size
      or die "$name C26 profile emitted ".(-s $generic_bin)." bytes, expected $output_size\n";

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
         $profile,$blank,'-o',$legacy_bin);
      read_file($generic_bin) eq read_file($legacy_bin)
         or die "$name C26 profile and legacy cfg do not emit identical cartridges
";
   }

   my $map=read_file($generic_map);
   $map =~ /^C26 CARTRIDGE TOPOLOGY$/m
      or die "$name map does not report C26 topology\n";
   $map =~ /output-size=\$[0-9A-F]{8}/
      or die "$name map does not report topology output size\n";
   for my $logical (0..$banks-1) {
      my $file_index=$banks-1-$logical;
      $map =~ /^\s+bank\Q$logical\E\s+file-index=\Q$file_index\E\b/m
         or die "$name map does not preserve bank$logical file ordering\n";
   }
   if ($selector) {
      $map =~ /^CARTRIDGE\n\s+mapper=C26\b/m && $map =~ /mode=selector/
         or die "$name did not derive selector-controlled linker machinery from C26\n";
   } else {
      $map =~ /mode=direct/ && $map !~ /^TRAMPOLINES$/m
         or die "$name direct profile unexpectedly generated switching machinery\n";
   }
   if ($sc) {
      $map =~ /^\s+superchip\s+.*output-bank=<none> mode=shared\b/m
         or die "$name does not retain Superchip as shared memory\n";
      my $rom=read_file($generic_bin);
      for my $file_bank (0..$banks-1) {
         substr($rom,$file_bank*4096,256) eq ("\xFF" x 256)
            or die "$name file bank $file_bank does not retain the reserved Superchip prefix\n";
      }
   }
}

# The driver default is now the same explicit 4K C26 profile plus reduced cfg.
my $default_bin=File::Spec->catfile($tmp,'default.bin');
my $explicit_bin=File::Spec->catfile($tmp,'explicit4k.bin');
require_ok('build implicit default 4K profile',$driver,'-I',$vcs,$blank,'-o',$default_bin);
require_ok('build explicit default 4K profile',$driver,'-I',$vcs,
   '-T',$generic_cfg,File::Spec->catfile($vcs,'vcs_4k.c26'),$blank,'-o',$explicit_bin);
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
require_ok('build direct two-chunk C26 package',$driver,'-I',$vcs,
   '-T',$generic_cfg,'-Map',$direct_map,$direct_src,'-o',$direct_bin);
-s $direct_bin==8192 or die "direct profile did not emit two physical 4K chunks\n";
my $direct=read_file($direct_bin);
my $dmap=read_file($direct_map);
$dmap =~ /^\s+bank1\s+file-index=0\b.*mode=direct/m &&
$dmap =~ /^\s+bank0\s+file-index=1\b.*mode=direct/m &&
$dmap =~ /^\s+\$3001\s+helper\b/m &&
$dmap =~ /^\s+\$3000\s+marker\b/m &&
$dmap !~ /^TRAMPOLINES$/m && $dmap !~ /^BANK PLACEMENT$/m
   or die "direct profile map does not show ordinary direct ownership\n";
index(substr($direct,4096),"\x20\x01\x30")>=0
   or die "direct profile did not emit an ordinary JSR to the first file chunk\n";
index($direct,"\xAD\xF8\x1F")==-1 && index($direct,"\xAD\xF9\x1F")==-1
   or die "direct profile emitted selector-hotspot reads\n";
substr($direct,0x12,4096-0x12) eq ("\xFF" x (4096-0x12))
   or die "direct profile did not fill the unused first chunk with the cartridge fill value\n";

print "C26 cartridge profiles passed\n";
