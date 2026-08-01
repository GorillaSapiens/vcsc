#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: function mem region placement enforced
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}
sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not read $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
}
sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub require_ok {
   my ($label, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit == 0 && !$sig
      or die "$label failed: exit=$exit signal=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out, $err);
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $src = File::Spec->catfile($tmp, 'banked.c26');
my $asm = File::Spec->catfile($tmp, 'banked.s26');
my $cfg = File::Spec->catfile($tmp, 'banked.cfg');
my $hex = File::Spec->catfile($tmp, 'banked.hex');
my $map = File::Spec->catfile($tmp, 'banked.map');
my $include = File::Spec->catfile($repo, 'test');

write_file($src, <<'SRC');
include "machine_6502.c26"
mem bank1 { $start:0xD100 $size:0x0F00 $ro };

bank1 page void placed(void) {
   asm nop;
}

void main(void) {
}
SRC

write_file($cfg, <<'CFG');
MEMORY {
   ZEROPAGE: start=$0000, size=$0080, type=rw;
   RAM:      start=$0080, size=$0080, type=rw;
   BANK1:    start=$D100, size=$0F00, type=ro;
   ROM:      start=$F000, size=$1000, type=ro;
}
SEGMENTS {
   ZEROPAGE:  load=ROM, run=ZEROPAGE, type=zp;
   CODE:      load=ROM, type=ro;
   CODE.bank1:load=BANK1, type=ro;
   RODATA:    load=ROM, type=ro;
   DATA:      load=ROM, run=RAM, type=data;
   BSS:       load=RAM, type=bss;
}
CFG

require_ok('function-region assembly emission', $vcsc, '-S', '-I', $include,
           '-o', $asm, $src);
my $assembly = slurp($asm);
$assembly =~ /\.segment "CODE\.bank1"\s+\.proc placed\s+\.pagecontain/s
   or die "placed function did not enter CODE.bank1 as a private page-contained procedure\n";
$assembly =~ /\.endproc\s+\.segment "CODE"\s+\.proc main/s
   or die "compiler did not restore CODE before emitting unpinned main\n";
$assembly =~ /__memmeta\$V1\$bank1\$SD100\$Z0F00\$Tro/
   or die "compiler omitted Superchip-sized bank1 metadata\n";

require_ok('function-region link', $vcsc, '-I', $include, '-T', $cfg,
           '-Map', $map, '-o', $hex, $src);
my $map_text = slurp($map);
$map_text =~ /CODE\.bank1\.__vcsc_function\$placed\s+load=\$D100\s+size=\$0002\s+page=hard/
   or die "map did not place the private function layout in BANK1 at D100\n$map_text";
$map_text =~ /CODE\.__vcsc_function\$main\s+load=\$F[0-9A-Fa-f]{3}\s+size=\$0001/
   or die "map did not place unpinned main in the ordinary home ROM region\n$map_text";
$map_text =~ /^\s*\$D100\s+placed\b/m
   or die "placed symbol did not resolve to D100\n";
$map_text =~ /^\s*\$F[0-9A-Fa-f]{3}\s+main\b/m
   or die "main symbol did not resolve in the F000 mirror\n";

print "function mem region placement enforced\n";
