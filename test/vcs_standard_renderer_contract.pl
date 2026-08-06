#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_standard_renderer_contract ok
# expectexit: 0


use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub without_cartridge_usage {
   my ($out) = @_;
   $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//;
   return $out;
}

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
      $driver,'-I',$vcs,'-T',$cfg,'-Map',$map,@sources,'-o',$bin);
   die "contract smoke build $label exited $exit signal $sig\nstdout:\n$out\nstderr:\n$err"
      if $exit || $sig;
   die "contract smoke build $label wrote stdout:\n$out" if without_cartridge_usage($out) ne '';
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
my $profile=File::Spec->catdir($vcs,'renderers','standard_4k_ntsc');
my $module=File::Spec->catfile($profile,'standard_4k_ntsc.c26');
my $renderer=File::Spec->catfile($profile,'standard_4k_ntsc_renderer.s26');
my $cfg=File::Spec->catfile($vcs,'vcs.cfg');
my $profile_c26=File::Spec->catfile($vcs,'vcs_4k.c26');
my $compat_cfg=File::Spec->catfile($profile,'vcs_standard_4k_ntsc.cfg');
my $readme=File::Spec->catfile($profile,'README.md');
my $module_text=read_file($module);
my $cfg_text=read_file($cfg);
my $compat_cfg_text=read_file($compat_cfg);
my $renderer_text=read_file($renderer);
my $readme_text=read_file($readme);

require_re($module_text,qr/alias\s+VCS_STANDARD_APPLICATION_DISPLAY_RAM_BYTES\s+23\b/,
   'application-visible display-state contract is not 23 bytes');
require_re($module_text,qr/alias\s+VCS_STANDARD_PRIVATE_RAM_BYTES\s+57\b/,
   'private workspace contract is not 57 bytes');
require_re($module_text,qr/alias\s+VCS_STANDARD_MODULE_RAM_BYTES\s+80\b/,
   'mandatory module RAM-byte contract is not 80');
require_re($module_text,qr/alias\s+VCS_STANDARD_PLAYFIELD\s+vcs_standard_playfield\b/,
   'application-provided playfield symbol alias is missing');
require_re($module_text,qr/alias\s+VCS_STANDARD_PLAYFIELD_COLUMNS\s+32\b/,
   '32-column playfield geometry is missing');
require_re($module_text,qr/alias\s+VCS_STANDARD_PLAYFIELD_ROWS\s+12\b/,
   '12-row playfield geometry is missing');
require_re($module_text,qr/alias\s+VCS_STANDARD_DEFAULT_ROW_SCANLINES\s+16\b/,
   'default 16-scanline row height is missing');
require_re($module_text,qr/alias\s+VCS_STANDARD_HIDDEN_STACK_BYTES\s+4\b/,
   'module supplementary hidden-stack contract is not four bytes');
require_re($module_text,qr/uint8_t\s+vcs_standard_object_x\s*\[\s*VCS_STANDARD_OBJECT_COUNT\s*\]\s*;/,
   'five-object horizontal-position adjacency group is missing');
require_re($module_text,qr/uint8_t\s+vcs_standard_pointer_workspace\s*\[\s*VCS_STANDARD_POINTER_WORKSPACE_BYTES\s*\]\s*;/,
   'twelve-byte pointer/transient adjacency group is missing');
$module_text !~ /(?:const\s+)?uint8_t\s+vcs_standard_playfield\s*\[/
   or die "renderer module still allocates the application playfield\n";
$module_text !~ /\*\s*vcs_standard_playfield|vcs_standard_playfield\s*\*/
   or die "renderer module introduced a runtime playfield pointer\n";
require_re($module_text,qr/extern\s+void\s+vcs_standard_overscan_hook\s*\(\s*void\s*\)\s*;/,
   'void overscan-hook declaration is missing');
require_re($module_text,qr/extern\s+void\s+vcs_standard_renderer_drawscreen\s*\(\s*void\s*\)\s*;/,
   'drawscreen entry declaration is missing');
$module_text !~ /\b(?:absolute\s+)?ref\b[^;]*(?:0x|\$)[0-9A-Fa-f]+/
   or die "source contract introduced a fixed RAM ref\n";

my @required_readme=(
   'Selected configuration', 'Frame ownership', 'State ownership and RAM cost',
   'What the 48-byte playfield represents', 'Demonstrable placement constraints',
   'Register, flag, and hardware-register clobbers', 'Hidden hardware-stack use',
   'ROM and feature-cost ledger', 'Retained-source boundary used by the normalizer',
   '262-scanline', 'vertical reflection', 'multisprite', 'status bar', 'Superchip',
   '.callstackextra 4', 'Mandatory module-declared RAM', '80',
   'vcs_standard_overscan_hook', 'weak no-op', '**next** frame',
   'fixed ROM playfield', 'mutable playfield', '32 independently controlled bits',
   '16 scanlines', '$00..$D0', 'runtime playfield',
   '88-byte default score table'
);
for my $phrase (@required_readme) {
   index($readme_text,$phrase) >= 0 or die "contract README is missing '$phrase'\n";
}
require_re($renderer_text,qr/^\.segmentregion\s+"RENDERER_CODE",\s*startup\s*$/m,
   'renderer object does not own its code-region contract');
require_re($renderer_text,qr/^\.segmentalign\s+"RENDERER_CODE",\s*256\s*$/m,
   'renderer object does not own its code alignment');
require_re($renderer_text,qr/^\.segmentprivate\s+"RENDERER_CODE"\s*$/m,
   'renderer code route is not object-private');
require_re($renderer_text,qr/^\.segmentregion\s+"RENDERER_RODATA",\s*startup\s*$/m,
   'renderer object does not own its RODATA-region contract');
require_re($renderer_text,qr/^\.segmentalign\s+"RENDERER_RODATA",\s*256\s*$/m,
   'renderer object does not own its RODATA alignment');
require_re($renderer_text,qr/^\.callstackextra\s+4\s*$/m,
   'renderer object does not own its four-byte hidden-stack requirement');
$compat_cfg_text !~ /callstack_extra|RENDERER_CODE|RENDERER_RODATA/
   or die "compatibility cfg still contains renderer-specific constraints
";
require_re($cfg_text,qr/ram:.*callstack\s*=\s*callgraph/is,
   'generic VCS cfg lost call-graph stack policy');

my $ram_src=File::Spec->catfile($repo,'test','vcs_standard_renderer_contract_smoke.c26');
my $rom_src=File::Spec->catfile($repo,'test','vcs_standard_renderer_contract_rom_smoke.c26');
my $ram_src_text=read_file($ram_src);
my $rom_src_text=read_file($rom_src);
require_re($ram_src_text,qr/^uint8_t\s+vcs_standard_playfield\s*\[\s*48\s*\]\s*;/m,
   'RAM smoke does not provide a mutable 48-byte playfield');
require_re($rom_src_text,qr/^page\s+const\s+uint8_t\s+vcs_standard_playfield\s*\[\s*48\s*\]\s*:=/m,
   'ROM smoke does not define a page-contained constant 48-byte playfield');
$rom_src_text !~ /alignment_pad|\[97\]/ or die "ROM smoke padding array returned\n";

my ($ram_exit,$ram_sig,$ram_out,$ram_err)=run_capture(
   $driver,'-I',$vcs,'-T',$cfg,
   $profile_c26,$ram_src,$renderer,'-o',File::Spec->catfile($tmp,'standard_renderer_contract_ram.bin'));
$ram_exit != 0 && !$ram_sig or die "mutable-playfield smoke unexpectedly linked\n";
without_cartridge_usage($ram_out) eq '' or die "mutable-playfield smoke wrote stdout:\n$ram_out";
$ram_err =~ /does not fit|overflow|out of memory|RAM/i
   or die "mutable-playfield failure did not report RIOT RAM exhaustion:\n$ram_err";

my $rom_map=build_smoke(
   $driver,$vcs,$cfg,[$profile_c26,$rom_src,$renderer],
   File::Spec->catfile($tmp,'standard_renderer_contract_rom.bin'),
   File::Spec->catfile($tmp,'standard_renderer_contract_rom.map'));

require_re($rom_map,qr/ram\s+start=\$0080\s+size=\$0076\s+type=rw/,
   'profile did not reserve six call-graph bytes plus four supplementary bytes');
require_re($rom_map,qr/region=ram\s+depth=3\s+bytes=\$000A\s+physical=\$00F6-\$00FF\s+extra=\$0004/,
   'map does not report the hook-aware four-byte supplementary allowance');
symbol_addr($rom_map,'__call_stack_depth') == 3
   or die "__call_stack_depth does not include drawscreen -> overscan hook\n";
symbol_addr($rom_map,'__call_stack_extra') == 4
   or die "__call_stack_extra is not four\n";
symbol_addr($rom_map,'__weak_vcs_standard_overscan_hook') >= 0xf000
   or die "default weak overscan hook did not link in cartridge ROM\n";

my $object_x=symbol_addr($rom_map,'vcs_standard_object_x');
my $player0_y=symbol_addr($rom_map,'vcs_standard_player0_y');
my $score_color=symbol_addr($rom_map,'vcs_standard_score_color');
my $workspace=symbol_addr($rom_map,'vcs_standard_pointer_workspace');
my $playfield_pos=symbol_addr($rom_map,'vcs_standard_playfield_position');
my $masks=symbol_addr($rom_map,'vcs_standard_object_masks');
$player0_y == $object_x + 5 or die "object_x is not a five-byte adjacency group\n";
$workspace == $score_color + 1 or die "private workspace does not follow application display state\n";
$playfield_pos == $workspace + 12 or die "pointer workspace is not twelve contiguous bytes\n";
$masks == $playfield_pos + 1 or die "object masks do not follow playfield position\n";
$masks + 44 - $object_x == 80 or die "mandatory module state span is not 80 bytes\n";
$object_x != 0x80 or die "module state was forced back to the old fixed RAM base\n";

my $rom_pf=symbol_addr($rom_map,'vcs_standard_playfield');
$rom_pf >= 0xf000
   or die sprintf("ROM playfield linked outside cartridge ROM at \$%04X\n",$rom_pf);
timing_safe_playfield($rom_pf,'ROM');

require_re($rom_map,qr/RENDERER_CODE\s+load=\$[0-9A-F]{4}.*component-region=\@startup.*component-align=\$0100.*component-private=yes/,
   'map does not report object-owned renderer code constraints');
require_re($rom_map,qr/RENDERER_RODATA\s+load=\$[0-9A-F]{4}.*component-region=\@startup.*component-align=\$0100.*component-private=yes/,
   'map does not report object-owned renderer RODATA constraints');
my $renderer_code=symbol_addr($rom_map,'vcs_standard_renderer_drawscreen');
($renderer_code & 0xff) < 0x100
   or die "renderer draw entry is outside the aligned renderer layout
";

# Reconstruct the pre-item-27 cfg and strip the new object metadata.  The old
# cfg-owned build must remain byte-identical to the new component-owned build.
my $legacy_cfg=File::Spec->catfile($tmp,'legacy_standard_renderer.cfg');
my $legacy_cfg_text=$compat_cfg_text;
$legacy_cfg_text =~ s/callstack\s*=\s*callgraph/callstack = callgraph, callstack_extra = \$0004/;
$legacy_cfg_text =~ s/(\s+RODATA:.*?;
)/$1 . "    RENDERER_CODE:   load = ROM, type = ro, define = yes, align = \$0100;\n" .
   "    RENDERER_RODATA: load = ROM, type = ro, define = yes, align = \$0100;\n"/e;
write_file($legacy_cfg,$legacy_cfg_text);
my $legacy_renderer=File::Spec->catfile($tmp,'standard_renderer_legacy_constraints.s26');
(my $legacy_renderer_text=$renderer_text) =~ s/^\.(?:segmentregion|segmentalign|segmentprivate|callstackextra)[^
]*
//mg;
my $legacy_macros=File::Spec->catfile($profile,'standard_4k_ntsc_macros.inc');
$legacy_renderer_text =~ s/^\.include\s+"standard_4k_ntsc_macros\.inc"/.include "$legacy_macros"/m;
write_file($legacy_renderer,$legacy_renderer_text);
my $legacy_bin=File::Spec->catfile($tmp,'standard_renderer_legacy_constraints.bin');
my $legacy_map_path=File::Spec->catfile($tmp,'standard_renderer_legacy_constraints.map');
my $legacy_map=build_smoke($driver,$vcs,$legacy_cfg,[$rom_src,$legacy_renderer],
   $legacy_bin,$legacy_map_path);
read_file($legacy_bin) eq read_file(File::Spec->catfile($tmp,'standard_renderer_contract_rom.bin'))
   or die "component-owned renderer image differs from the legacy cfg-owned image
";
require_re($legacy_map,qr/region=ram\s+depth=3\s+bytes=\$000A.*extra=\$0004/,
   'legacy differential build did not preserve stack accounting');

# A compatibility cfg may duplicate the component contract only when it agrees.
my $duplicate_bin=File::Spec->catfile($tmp,'standard_renderer_duplicate_contract.bin');
my $duplicate_map=File::Spec->catfile($tmp,'standard_renderer_duplicate_contract.map');
build_smoke($driver,$vcs,$legacy_cfg,[$rom_src,$renderer],$duplicate_bin,$duplicate_map);
read_file($duplicate_bin) eq read_file($legacy_bin)
   or die "matching cfg/object constraints changed the renderer image
";

# Conflicting retained cfg constraints must fail deterministically.
my $bad_align_cfg=File::Spec->catfile($tmp,'bad_renderer_alignment.cfg');
(my $bad_align_text=$legacy_cfg_text) =~ s/RENDERER_CODE:(.*)align\s*=\s*\$0100/RENDERER_CODE:$1align = \$0080/;
write_file($bad_align_cfg,$bad_align_text);
my ($align_exit,$align_sig,$align_out,$align_err)=run_capture(
   $driver,'-I',$vcs,'-T',$bad_align_cfg,$rom_src,$renderer,
   '-o',File::Spec->catfile($tmp,'bad_renderer_alignment.bin'));
$align_exit != 0 && !$align_sig or die "conflicting renderer alignment unexpectedly linked
";
without_cartridge_usage($align_out) eq '' or die "bad alignment wrote stdout:
$align_out";
$align_err =~ /requires alignment \$0100 but cfg requires \$0080/
   or die "alignment conflict diagnostic is missing:
$align_err";

my $bad_stack_cfg=File::Spec->catfile($tmp,'bad_renderer_stack.cfg');
(my $bad_stack_text=$legacy_cfg_text) =~ s/callstack_extra\s*=\s*\$0004/callstack_extra = \$0002/;
write_file($bad_stack_cfg,$bad_stack_text);
my ($stack_exit,$stack_sig,$stack_out,$stack_err)=run_capture(
   $driver,'-I',$vcs,'-T',$bad_stack_cfg,$rom_src,$renderer,
   '-o',File::Spec->catfile($tmp,'bad_renderer_stack.bin'));
$stack_exit != 0 && !$stack_sig or die "conflicting hidden-stack requirement unexpectedly linked
";
without_cartridge_usage($stack_out) eq '' or die "bad stack cfg wrote stdout:
$stack_out";
$stack_err =~ /hidden-stack requirement \$0004 conflicts with cfg callstack_extra \$0002/
   or die "hidden-stack conflict diagnostic is missing:
$stack_err";

my $bad_cfg=File::Spec->catfile($tmp,'bad_callstack_policy.cfg');
(my $bad_text=$compat_cfg_text) =~ s/callstack\s*=\s*callgraph/callstack = no/;
write_file($bad_cfg,$bad_text);
my ($bad_exit,$bad_sig,$bad_out,$bad_err)=run_capture(
   $driver,'-I',$vcs,'-T',$bad_cfg,$rom_src,$renderer,
   '-o',File::Spec->catfile($tmp,'bad_callstack_policy.bin'));
$bad_exit != 0 && !$bad_sig or die "hidden-stack component without callgraph policy unexpectedly linked
";
without_cartridge_usage($bad_out) eq '' or die "bad profile wrote unexpected stdout:
$bad_out";
$bad_err =~ /hidden-stack metadata requires a MEMORY region with callstack=callgraph/
   or die "missing-callgraph diagnostic is absent:
$bad_err";

print "vcs_standard_renderer_contract ok\n";
