#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: vcs_all_five_banked ok
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
   my($driver,$vcs,$source,$tmp,$name,$defs,$size)=@_;
   my $bin=File::Spec->catfile($tmp,"$name.bin");
   my $mapfile=File::Spec->catfile($tmp,"$name.map");
   my @cmd=($driver,'-I',$vcs,@$defs,'-Map',$mapfile,$source,'-o',$bin);
   my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$name build failed rc=$rc sig=$sig\n$out$err";
   without_usage($out) eq '' or die "$name build wrote stdout:\n$out";
   $err eq '' or die "$name build wrote stderr:\n$err";
   -s $bin == $size or die "$name image size is not $size\n";
   return ($bin,read_file($mapfile));
}
my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repo\n";
$tmp=abs_path($tmp) // die "resolve tmp\n";
my $driver=File::Spec->catfile($repo,qw(driver vcsc));
my $vcs=File::Spec->catdir($repo,qw(libraries vcs));
my $example=File::Spec->catdir($repo,qw(examples 07_diagnostics/bankswitching all_five));
my $source=File::Spec->catfile($example,'banked_all_five.c26');

my @spec=(
   ['4K',['-DUNBANKED_REFERENCE'],4096,1],
   ['F8',['-DMAPPER_BANKS=2'],8192,2],
   ['F6',['-DMAPPER_BANKS=4'],16384,4],
   ['F4',['-DMAPPER_BANKS=8'],32768,8],
   ['F8SC',['-DMAPPER_BANKS=2','-DSUPERCHIP_TEST'],8192,2],
);
my %built;
for my $s (@spec) {
   my($name,$defs,$size,$banks)=@$s;
   my($bin,$map)=build_variant($driver,$vcs,$source,$tmp,lc($name),$defs,$size);
   $built{$name}={bin=>$bin,map=>$map,banks=>$banks};
}

# The unified component is inline in bank0. Every hard datum touched while the
# beam-critical bank is selected must resolve to bank0; only the game-logic
# callback is deliberately cross-bank.
for my $name (qw(F8 F6 F4 F8SC)) {
   my $map=$built{$name}{map};
   for my $object (qw(game_playfield player0_graphics player1_graphics game_reposition_table)) {
      require_re($map,qr/RODATA(?:\.bank0)?\.__vcsc_object\$\Q$object\E .*bank=bank0/,
         "$name $object is not resident in startup bank");
   }
   require_re($map,qr/CODE\.bank1\.__vcsc_function\$banked_game_logic .*bank=bank1.*placement=pinned/,
      "$name game logic is not in bank1");
   require_re($map,qr/^\s*common-offset=\$F00 .*target-passing=inline generic-jsr=\$048 entries=0 jmp=0 jsr=0/m,
      "$name does not use the public descriptor bankcall block");
   require_re($map,qr/^\s*EDGE main -> banked_game_logic slots=2 .*bank-bridge=yes/m,
      "$name has no bank0-to-bank1 game-logic bridge");
   require_re($map,qr/region=ram .*extra=\$0004/,
      "$name lost the all-five hidden-stack reservation");
}

# F8SC keeps non-critical callback state in cartridge RAM and must preserve the
# mapper's split read/write aliases. The renderer's ordinary RIOT state remains
# in zero page.
require_re($built{'F8SC'}{map},qr/^\s*cartram\s+used=3 bytes .*objects=3 bytes hardware-stack=0 bytes/m,
   'F8SC non-critical game state is not three Superchip bytes');
require_re($built{'F8SC'}{map},qr/^\s*cartram\s+read_start=\$F080 write_start=\$F000 .*mode=shared/m,
   'F8SC Superchip region is not shared');
require_re($built{'F8SC'}{map},qr/COPY DATA\.cartram\.__vcsc_object\$banked_hook_signature .*read=\$F082 write=\$F002 .*split=yes/,
   'F8SC signature is not initialized through split aliases');
require_re($built{'F8SC'}{map},qr/ZERO BSS\.cartram\.__vcsc_object\$banked_hook_count .*read=\$F080 write=\$F000 .*split=yes/,
   'F8SC count is not initialized through split aliases');

# The linker suites own descriptor-block byte-level certification. This test
# keeps only the renderer-specific composition contract: the call is recognized
# as a bank bridge, and runtime switching/restoration remains beam-safe.

# Run one cycle/raster model against every mapper. It rejects selector accesses
# outside VBLANK, verifies startup-bank restoration, and requires banked variants
# to produce the same visible TIA write stream as the unbanked reference.
my $cxx=$ENV{CXX} || 'c++';
my $mos=File::Spec->catdir($repo,qw(simulator mos6502));
my $cpp=File::Spec->catfile($repo,qw(test vcs_all_five_banked.cpp));
my $exe=File::Spec->catfile($tmp,'vcs_all_five_banked');
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
      symbol_addr($map,'game_object_x')+4,
      symbol_addr($map,'banked_hook_signature'),
   );
   my @args=map { sprintf('0x%04x',$_) } @addresses;
   ($rc,$sig,$out,$err)=capture($exe,$built{$name}{bin},$name,@args);
   $rc==0 && !$sig or die "$name runtime failed\n$out$err";
   $err eq '' or die "$name runtime stderr:\n$err";
   $out =~ /^mapper=\Q$name\E frames=8 period=20064 raster=([0-9a-f]{16}) events=(\d+) switches=(\d+) hook=8\n$/
      or die "$name unexpected runtime output: $out";
   $runtime{$name}=[$1,$2,$3];
}
for my $name (qw(F8 F6 F4 F8SC)) {
   $runtime{$name}[0] eq $runtime{'4K'}[0] or die "$name raster differs from unbanked reference\n";
   $runtime{$name}[1] eq $runtime{'4K'}[1] or die "$name visible-write count differs from unbanked reference\n";
   $runtime{$name}[2] == 8 or die "$name did not make exactly one round trip per frame\n";
}
$runtime{'4K'}[1] > 0 or die "unbanked reference emitted no visible TIA writes\n";
$runtime{'4K'}[2] == 0 or die "unbanked reference switched banks\n";

# Keep the public diagnostic consolidated: one source and one public F8 image.
my $make=read_file(File::Spec->catfile($example,'Makefile'));
$make =~ /^all:\s+f8\.bin\s*$/m or die "public example does not expose exactly the consolidated F8 image\n";
$make !~ /f6\.bin|f4\.bin|f8sc\.bin/ or die "public example multiplied mapper variants\n";
$make !~ /standard_4k_ntsc/ or die "public example still depends on the deleted legacy renderer\n";

print "vcs_all_five_banked ok\n";
