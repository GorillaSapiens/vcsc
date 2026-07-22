#!/usr/bin/perl

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh) or die "could not close $path: $!\n";
   return defined($d)?$d:'';
}
sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>:raw',$path) or die "could not create $path: $!\n";
   print {$fh} $text;
   close($fh) or die "could not close $path: $!\n";
}
sub require_re {
   my ($text,$re,$why)=@_;
   $text =~ $re or die "$why\n";
}
sub symbol_addr {
   my ($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\s+/m
      or die "map is missing symbol $name\n";
   return hex($1);
}
sub timing_safe_playfield {
   my ($addr,$which)=@_;
   my $low=$addr & 0xff;
   $low <= 0xd0
      or die sprintf("%s playfield at \$%04X crosses a page; low byte \$%02X exceeds \$D0\n",
                     $which,$addr,$low);
}
sub build_smoke {
   my ($driver,$vcs,$cfg,$src,$bin,$map)=@_;
   my @sources=ref($src) eq 'ARRAY' ? @$src : ($src);
   my $label=join(',',@sources);
   my ($exit,$sig,$out,$err)=run_capture(
      $driver,'-I',$vcs,'-Wa,--illegals','-T',$cfg,'-Map',$map,@sources,'-o',$bin);
   die "contract smoke build $label exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
      if $exit || $sig;
   die "contract smoke build $label wrote stdout:\n$out" if $out ne '';
   die "contract smoke build $label wrote stderr:\n$err" if $err ne '';
   -s $bin == 4096 or die "contract smoke cartridge $label is not 4096 bytes\n";
   return read_file($map);
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $profile=File::Spec->catdir($vcs,'kernels','standard_4k_ntsc');
my $module=File::Spec->catfile($profile,'standard_4k_ntsc.c26');
my $cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $readme=File::Spec->catfile($profile,'README.md');
my $module_text=read_file($module);
my $cfg_text=read_file($cfg);
my $readme_text=read_file($readme);

require_re($module_text,qr/alias\s+VCS_STANDARD_APPLICATION_DISPLAY_RAM_BYTES\s+23\b/,
   'application-visible display-state contract is not 23 bytes');
require_re($module_text,qr/alias\s+VCS_STANDARD_PRIVATE_RAM_BYTES\s+15\b/,
   'private workspace contract is not 15 bytes');
require_re($module_text,qr/alias\s+VCS_STANDARD_MODULE_RAM_BYTES\s+38\b/,
   'mandatory module RAM-byte contract is not 38');
require_re($module_text,qr/alias\s+VCS_STANDARD_PLAYFIELD\s+vcs_standard_playfield\b/,
   'application-provided playfield symbol alias is missing');
require_re($module_text,qr/alias\s+VCS_STANDARD_PLAYFIELD_COLUMNS\s+32\b/,
   '32-column playfield geometry is missing');
require_re($module_text,qr/alias\s+VCS_STANDARD_PLAYFIELD_ROWS\s+12\b/,
   '12-row playfield geometry is missing');
require_re($module_text,qr/alias\s+VCS_STANDARD_DEFAULT_ROW_SCANLINES\s+16\b/,
   'default 16-scanline row height is missing');
require_re($module_text,qr/alias\s+VCS_STANDARD_HIDDEN_STACK_BYTES\s+2\b/,
   'module hidden-stack contract is not two bytes');
require_re($module_text,qr/uint8_t\s+vcs_standard_object_x\s*\[\s*VCS_STANDARD_OBJECT_COUNT\s*\]\s*;/,
   'five-object horizontal-position adjacency group is missing');
require_re($module_text,qr/uint8_t\s+vcs_standard_pointer_workspace\s*\[\s*VCS_STANDARD_POINTER_WORKSPACE_BYTES\s*\]\s*;/,
   'twelve-byte pointer/transient adjacency group is missing');
$module_text !~ /(?:const\s+)?uint8_t\s+vcs_standard_playfield\s*\[/
   or die "kernel module still allocates the application playfield\n";
$module_text !~ /\*\s*vcs_standard_playfield|vcs_standard_playfield\s*\*/
   or die "kernel module introduced a runtime playfield pointer\n";
require_re($module_text,qr/extern\s+void\s+vcs_standard_kernel_drawscreen\s*\(\s*void\s*\)\s*;/,
   'drawscreen entry declaration is missing');
$module_text !~ /\b(?:absolute\s+)?ref\b[^;]*(?:0x|\$)[0-9A-Fa-f]+/
   or die "source contract introduced a fixed RAM ref\n";

my @required_readme=(
   'Selected configuration', 'Frame ownership', 'State ownership and RAM cost',
   'What the 48-byte playfield represents', 'Demonstrable placement constraints',
   'Register, flag, and hardware-register clobbers', 'Hidden hardware-stack use',
   'ROM and feature-cost ledger', 'Retained-source boundary used by the normalizer',
   '262-scanline', 'vertical reflection', 'multisprite', 'status bar', 'Superchip',
   'callstack_extra = $0002', 'Mandatory module-declared RAM', '38',
   'fixed ROM playfield', 'mutable RAM playfield', '32 independently controlled bits',
   '16 scanlines', '$00..$D0', 'runtime playfield',
   '88-byte default score table'
);
for my $phrase (@required_readme) {
   index($readme_text,$phrase) >= 0 or die "contract README is missing '$phrase'\n";
}
require_re($cfg_text,qr/RAM:.*callstack\s*=\s*callgraph.*callstack_extra\s*=\s*\$0002/s,
   'profile cfg does not reserve the exact hidden two-byte stack allowance');

my $ram_src=File::Spec->catfile($repo,'test','vcs_standard_kernel_contract_smoke.c26');
my $rom_src=File::Spec->catfile($repo,'test','vcs_standard_kernel_contract_rom_smoke.c26');
my $rom_playfield=File::Spec->catfile($repo,'test','vcs_standard_kernel_contract_rom_playfield.s');
my $ram_src_text=read_file($ram_src);
my $rom_src_text=read_file($rom_src);
require_re($ram_src_text,qr/^uint8_t\s+vcs_standard_playfield\s*\[\s*48\s*\]\s*;/m,
   'RAM smoke does not provide a mutable 48-byte playfield');
require_re($rom_src_text,qr/^extern\s+const\s+uint8_t\s+vcs_standard_playfield\s*\[\s*48\s*\]\s*;/m,
   'ROM smoke does not import a constant 48-byte playfield');
my $rom_playfield_text=read_file($rom_playfield);
require_re($rom_playfield_text,qr/^\s*\.align\s+256\s*$/m,
   'ROM smoke playfield is not temporarily page-aligned');
$rom_src_text !~ /alignment_pad|\[97\]/ or die "ROM smoke padding array returned\n";

my $ram_map=build_smoke(
   $driver,$vcs,$cfg,$ram_src,
   File::Spec->catfile($tmp,'standard_kernel_contract_ram.bin'),
   File::Spec->catfile($tmp,'standard_kernel_contract_ram.map'));
my $rom_map=build_smoke(
   $driver,$vcs,$cfg,[$rom_playfield,$rom_src],
   File::Spec->catfile($tmp,'standard_kernel_contract_rom.bin'),
   File::Spec->catfile($tmp,'standard_kernel_contract_rom.map'));

for my $map_text ($ram_map,$rom_map) {
   require_re($map_text,qr/RAM\s+start=\$0080\s+size=\$007A\s+type=rw/,
      'profile did not shrink RAM by four call-graph bytes plus two hidden bytes');
   require_re($map_text,qr/region=RAM\s+depth=2\s+bytes=\$0006\s+physical=\$00FA-\$00FF\s+extra=\$0002/,
      'map does not report the profile hidden-stack allowance');
   symbol_addr($map_text,'__call_stack_extra') == 2
      or die "__call_stack_extra is not two\n";

   my $object_x=symbol_addr($map_text,'vcs_standard_object_x');
   my $player0_y=symbol_addr($map_text,'vcs_standard_player0_y');
   my $score_color=symbol_addr($map_text,'vcs_standard_score_color');
   my $workspace=symbol_addr($map_text,'vcs_standard_pointer_workspace');
   my $playfield_pos=symbol_addr($map_text,'vcs_standard_playfield_position');
   my $scratch=symbol_addr($map_text,'vcs_standard_kernel_scratch');
   $player0_y == $object_x + 5 or die "object_x is not a five-byte adjacency group\n";
   $workspace == $score_color + 1 or die "private workspace does not follow application display state\n";
   $playfield_pos == $workspace + 12 or die "pointer workspace is not twelve contiguous bytes\n";
   $scratch == $playfield_pos + 1 or die "private playfield position/scratch layout is not contiguous\n";
   $scratch + 2 - $object_x == 38 or die "mandatory module state span is not 38 bytes\n";
   $object_x != 0x80 or die "module state was forced back to the old fixed RAM base\n";
}

my $ram_pf=symbol_addr($ram_map,'vcs_standard_playfield');
my $rom_pf=symbol_addr($rom_map,'vcs_standard_playfield');
$ram_pf >= 0x0080 && $ram_pf <= 0x00ff
   or die sprintf("RAM playfield linked outside RIOT RAM at \$%04X\n",$ram_pf);
$rom_pf >= 0xf000
   or die sprintf("ROM playfield linked outside cartridge ROM at \$%04X\n",$rom_pf);
timing_safe_playfield($ram_pf,'RAM');
timing_safe_playfield($rom_pf,'ROM');

my $ram_object=symbol_addr($ram_map,'vcs_standard_object_x');
$ram_object == $ram_pf + 48
   or die "mutable playfield is not one contiguous 48-byte application object\n";
my $ram_free=symbol_addr($ram_map,'__stack_start');
my $rom_free=symbol_addr($rom_map,'__stack_start');
$ram_free - $rom_free == 48
   or die sprintf("ROM playfield did not recover exactly 48 RIOT bytes (RAM free \$%04X, ROM free \$%04X)\n",
                  $ram_free,$rom_free);

my $bad_cfg=File::Spec->catfile($tmp,'bad_callstack_extra.cfg');
(my $bad_text=$cfg_text) =~ s/callstack\s*=\s*callgraph/callstack = no/;
write_file($bad_cfg,$bad_text);
my ($bad_exit,$bad_sig,$bad_out,$bad_err)=run_capture(
   $driver,'-I',$vcs,'-T',$bad_cfg,$ram_src,'-o',File::Spec->catfile($tmp,'bad.bin'));
$bad_exit != 0 && !$bad_sig or die "callstack_extra without callgraph unexpectedly linked\n";
$bad_out eq '' or die "bad profile wrote unexpected stdout:\n$bad_out";
$bad_err =~ /sets callstack_extra but does not request callstack=callgraph/
   or die "bad profile did not report the callstack_extra contract error:\n$bad_err";

print "vcs_standard_kernel_contract ok\n";
