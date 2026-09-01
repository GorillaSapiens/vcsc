#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: directional ref cross-bank call verified
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
   my ($exit, $signal, $stdout, $stderr) = run_capture(@cmd);
   $exit == 0 && !$signal
      or die "$label failed: exit=$exit signal=$signal\n@cmd\nstdout:\n$stdout\nstderr:\n$stderr";
   return ($stdout, $stderr);
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $cc1 = File::Spec->catfile($repo, 'compiler', 'vcsc-cc1');
my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $include = File::Spec->catfile($repo, 'libraries', 'vcs');
my $src = File::Spec->catfile($tmp, 'directional_ref_cross_bank.c26');
my $asm = File::Spec->catfile($tmp, 'directional_ref_cross_bank.s26');
my $bin = File::Spec->catfile($tmp, 'directional_ref_cross_bank.bin');
my $map = File::Spec->catfile($tmp, 'directional_ref_cross_bank.map');

write_file($src, <<'SRC');
include "F8/mapper.c26"

uint8_t input @[0x0280/none];
uint8_t output @[none/0x0380];

bank1 void remote(ref const uint8_t source, ref writeonly uint8_t sink) {
   sink := source;
}

void main(void) {
   remote(input, output);
}
SRC

require_ok('compile cross-bank directional ref source',
           $cc1, '-I', $include, '-o', $asm, $src);
my $asm_text = slurp($asm);
$asm_text =~ /modeQ3DrefQ28accessQ3DconstQ29/
   or die "const ref capability missing from compiler ABI metadata\n";
$asm_text =~ /modeQ3DrefQ28accessQ3DwriteonlyQ29/
   or die "writeonly ref capability missing from compiler ABI metadata\n";
$asm_text =~ /lda #<\{\$0280 \+ 0\}.*?sta\s+remote\$source\b.*?sta\s+remote\$source \+ 1/s
   or die "caller did not pass the readable binding address to remote source\n$asm_text";
$asm_text =~ /lda #<\{\$0380 \+ 0\}.*?sta\s+remote\$sink\b.*?sta\s+remote\$sink \+ 1/s
   or die "caller did not pass the writable binding address to remote sink\n$asm_text";

require_ok('link cross-bank directional ref cartridge',
           $vcsc, '-I', $include, '-Map', $map, '-o', $bin, $src);
length(slurp($bin)) == 8192
   or die "directional-ref F8 cartridge was not 8K\n";
my $map_text = slurp($map);
$map_text =~ /JSR entry=.*source=bank0 hotspot=\$1FF9 destination=bank1 hotspot=\$1FF8/
   or die "directional-ref call did not use a BANK0-to-BANK1 JSR bridge\n$map_text";
$map_text =~ /entries=1 jmp=0 jsr=1/
   or die "directional-ref cross-bank call did not produce exactly one JSR trampoline\n$map_text";

print "directional ref cross-bank call verified\n";
