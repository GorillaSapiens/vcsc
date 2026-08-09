#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: vcs_standard_renderer_banked ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub read_file {
   my($p)=@_; open(my $f,'<:raw',$p) or die "read $p: $!\n";
   local $/; my $d=<$f>; close($f) or die "close $p: $!\n"; return defined($d)?$d:'';
}
sub without_usage {
   my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out;
}
sub require_re { my($text,$re,$why)=@_; $text =~ $re or die "$why\n"; }
sub symbol_addr {
   my($map,$name)=@_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\s+/m or die "map missing $name\n";
   return hex($1);
}
sub build_variant {
   my($driver,$vcs,$cfg,$source,$renderer,$tmp,$name,$defs,$size)=@_;
   my $bin=File::Spec->catfile($tmp,"$name.bin");
   my $mapfile=File::Spec->catfile($tmp,"$name.map");
   my @cmd=($driver,'-I',$vcs,@$defs,'-T',$cfg,'-Map',$mapfile,$source,$renderer,'-o',$bin);
   my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$name build failed rc=$rc sig=$sig\n$out$err";
   without_usage($out) eq '' or die "$name build wrote stdout:\n$out";
   $err eq '' or die "$name build wrote stderr:\n$err";
   -s $bin == $size or die "$name image size is not $size\n";
   return ($bin,read_file($mapfile));
}
sub check_trampoline {
   my($bin,$banks,$source_low,$destination_low,$target)=@_;
   my $bytes=read_file($bin);
   my @expected=(0x20,0x07,0xff,0x8d,$source_low,0x1f,0x60,
                 0x8d,$destination_low,0x1f,0x6c,0x0d,0xff,
                 $target & 0xff,($target >> 8) & 0xff);
   for my $bank (0..$banks-1) {
      my @got=unpack('C15',substr($bytes,$bank*4096+0x0f00,15));
      join(',',@got) eq join(',',@expected)
         or die "bank $bank trampoline bytes differ\n";
   }
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $cfg=File::Spec->catfile($vcs,'vcs.cfg');
my $example=File::Spec->catdir($repo,qw(examples 09_bankswitching 02_standard_renderer));
my $source=File::Spec->catfile($example,'banked_standard_renderer.c26');
my $renderer=File::Spec->catfile($vcs,qw(renderers standard_4k_ntsc standard_4k_ntsc_renderer.s26));

my @spec=(
   ['4K',['-DUNBANKED_REFERENCE'],4096,1,1940+94,0,0,0],
   ['F8',['-DMAPPER_BANKS=2'],8192,2,1940,94,30,0],
   ['F6',['-DMAPPER_BANKS=4'],16384,4,1940,94,60,0],
   ['F4',['-DMAPPER_BANKS=8'],32768,8,1940,94,120,0],
   ['F8SC',['-DMAPPER_BANKS=2','-DSUPERCHIP_TEST'],8192,2,1940,123,30,1],
);
my %built;
for my $s (@spec) {
   my($name,$defs,$size,$banks)=@$s;
   my($bin,$map)=build_variant($driver,$vcs,$cfg,$source,$renderer,$tmp,lc($name),$defs,$size);
   $built{$name}={bin=>$bin,map=>$map,banks=>$banks};
}

# The component and every hard ROM datum used during the display phase stay in bank0.
for my $name (qw(F8 F6 F4 F8SC)) {
   my $map=$built{$name}{map};
   require_re($map,qr/RODATA\.bank0\.__vcsc_object\$vcs_standard_playfield .*page=hard.*bank=bank0.*placement=pinned/,
      "$name playfield is not hard-pinned in startup bank");
   require_re($map,qr/RODATA\.bank0\.__vcsc_object\$player0_graphics .*page=hard.*bank=bank0.*placement=pinned/,
      "$name player0 graphics are not pinned in startup bank");
   require_re($map,qr/RODATA\.bank0\.__vcsc_object\$player1_graphics .*page=hard.*bank=bank0.*placement=pinned/,
      "$name player1 graphics are not pinned in startup bank");
   require_re($map,qr/RENDERER_CODE .*bank=bank0.*component-region=\@startup.*component-align=\$0100.*component-private=yes/,
      "$name renderer code did not retain its component contract in bank0");
   require_re($map,qr/RENDERER_RODATA .*bank=bank0.*component-region=\@startup.*component-align=\$0100.*component-private=yes/,
      "$name renderer RODATA did not retain its component contract in bank0");
   require_re($map,qr/CODE\.bank1\.__vcsc_function\$banked_game_logic .*bank=bank1.*placement=pinned/,
      "$name game logic is not in bank1");
   require_re($map,qr/CODE\.bank1\.__vcsc_function\$vcs_standard_overscan_hook .*bank=bank1.*placement=pinned/,
      "$name overscan hook is not in bank1");
   require_re($map,qr/^\s*JSR entry=0 .*vcs_standard_overscan_hook source=bank0 .*destination=bank1 .*replicated-bytes=\$[0-9A-Fa-f]+/m,
      "$name has no bank0-to-bank1 overscan trampoline");
   require_re($map,qr/region=ram depth=4 bytes=\$000C .*extra=\$0004/,
      "$name hardware-stack accounting is not 12 bytes with four hidden bytes");
}

# Lock the measured ROM and bridge costs for this diagnostic.
for my $check (
   ['F8',1827,55,30], ['F6',1827,55,60], ['F4',1827,55,120], ['F8SC',1827,86,30]
) {
   my($name,$b0,$b1,$rep)=@$check; my $map=$built{$name}{map};
   require_re($map,qr/^\s*bank0\s+used=$b0 bytes/m,"$name bank0 usage changed");
   require_re($map,qr/^\s*bank1\s+used=$b1 bytes/m,"$name bank1 usage changed");
   require_re($map,qr/replicated-bytes=\$[0]*\Q@{[sprintf('%X',$rep)]}\E\b/i,
      "$name replicated bridge cost changed");
}
require_re($built{'F8'}{map},qr/^\s*ram\s+used=107 bytes .*objects=95 bytes hardware-stack=12 bytes/m,
   'F8 RIOT RAM accounting changed');
require_re($built{'F8SC'}{map},qr/^\s*ram\s+used=105 bytes .*objects=93 bytes hardware-stack=12 bytes/m,
   'F8SC RIOT RAM accounting changed');
require_re($built{'F8SC'}{map},qr/^\s*superchip\s+used=3 bytes .*objects=3 bytes hardware-stack=0 bytes/m,
   'F8SC non-critical game state is not three Superchip bytes');
require_re($built{'F8SC'}{map},qr/^\s*superchip\s+read_start=\$F080 write_start=\$F000 .*mode=shared/m,
   'F8SC Superchip region is not shared');
require_re($built{'F8SC'}{map},qr/COPY DATA\.superchip\.__vcsc_object\$banked_hook_signature .*read=\$F082 write=\$F002 .*split=yes/,
   'F8SC signature is not initialized through split aliases');
require_re($built{'F8SC'}{map},qr/ZERO BSS\.superchip\.__vcsc_object\$banked_hook_count .*read=\$F080 write=\$F000 .*split=yes/,
   'F8SC count is not initialized through split aliases');

# The generated JSR trampoline costs 37 cycles total, 25 above direct JSR/RTS.
my $trampoline_total_cycles=6+6+4+5+6+4+6;
$trampoline_total_cycles == 37 or die "internal trampoline cycle ledger changed\n";
$trampoline_total_cycles-(6+6) == 25 or die "internal trampoline overhead ledger changed\n";
for my $name (qw(F8 F6 F4 F8SC)) {
   my $map=$built{$name}{map};
   $map =~ /JSR entry=0 offset=\$F00 target=\$([0-9A-Fa-f]{4}) .*source=bank0 hotspot=\$1F([0-9A-Fa-f]{2}) destination=bank1 hotspot=\$1F([0-9A-Fa-f]{2})/
      or die "$name trampoline metadata is malformed\n";
   check_trampoline($built{$name}{bin},$built{$name}{banks},hex($2),hex($3),hex($1));
}

# Build and run one cycle/raster model against every profile.  It rejects any
# selector access outside VBLANK and any frame that begins outside the startup bank.
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $cpp=File::Spec->catfile($repo,qw(test vcs_standard_renderer_banked.cpp));
my $exe=File::Spec->catfile($tmp,'vcs_standard_renderer_banked');
my $mos_obj=File::Spec->catfile($mos,'mos6502.o');
my @mos_input=-f $mos_obj ? ($mos_obj) : (File::Spec->catfile($mos,'mos6502.cpp'));
my($rc,$sig,$out,$err)=capture($cxx,'-std=c++17','-O2','-DILLEGAL_OPCODES','-I',$mos,$cpp,@mos_input,'-o',$exe);
$rc==0 && !$sig or die "banked renderer harness build failed\n$out$err";
$out eq '' && $err eq '' or die "banked renderer harness build wrote output\n$out$err";
my %runtime;
for my $s (@spec) {
   my($name)=@$s; my $map=$built{$name}{map};
   my @addresses=(
      symbol_addr($map,'banked_hook_count'),
      symbol_addr($map,'banked_hook_epoch'),
      symbol_addr($map,'banked_hook_failure'),
      symbol_addr($map,'vcs_standard_object_x')+4,
      symbol_addr($map,'vcs_standard_score'),
      symbol_addr($map,'banked_hook_signature'),
   );
   my @args=map { sprintf('0x%04x',$_) } @addresses;
   ($rc,$sig,$out,$err)=capture($exe,$built{$name}{bin},$name,@args);
   $rc==0 && !$sig or die "$name runtime failed\n$out$err";
   $err eq '' or die "$name runtime stderr:\n$err";
   $out =~ /^mapper=\Q$name\E frames=8 period=20140 raster=([0-9a-f]{16}) events=(\d+) switches=(\d+) hook=8\n$/
      or die "$name unexpected runtime output: $out";
   $runtime{$name}=[$1,$2,$3];
}
for my $name (qw(F8 F6 F4 F8SC)) {
   $runtime{$name}[0] eq $runtime{'4K'}[0] or die "$name raster differs from unbanked reference\n";
   $runtime{$name}[1] eq $runtime{'4K'}[1] or die "$name visible-write count differs from unbanked reference\n";
   $runtime{$name}[2] == 8 or die "$name did not make exactly one round trip per frame\n";
}
$runtime{'4K'}[0] eq '0e7671c2c53a351b' or die "standard renderer raster digest changed\n";
$runtime{'4K'}[1] == 4988 or die "standard renderer visible-write count changed\n";
$runtime{'4K'}[2] == 0 or die "unbanked reference switched banks\n";

# Keep the public diagnostic consolidated: one source and one public F8 image.
my $make=read_file(File::Spec->catfile($example,'Makefile'));
$make =~ /^all:\s+f8\.bin\s*$/m or die "public example does not expose exactly the consolidated F8 image\n";
$make !~ /f6\.bin|f4\.bin|f8sc\.bin/ or die "public example multiplied mapper variants\n";

print "vcs_standard_renderer_banked ok\n";
