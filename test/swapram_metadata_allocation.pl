#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: swapram metadata allocation ok
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

sub require_fail {
   my ($label, $fragment, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   ($exit != 0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n";
   index($err, $fragment) >= 0
      or die "$label stderr missing '$fragment'\nstdout:\n$out\nstderr:\n$err";
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');

my $src = File::Spec->catfile($tmp, 'swapram.c26');
my $bin = File::Spec->catfile($tmp, 'swapram.bin');
my $map = File::Spec->catfile($tmp, 'swapram.map');
write_file($src, <<'SRC');
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)

swapram uint8_t first[768];
swapram uint8_t second[512];
swapram uint32_t third;

bank3 void main(void) { while (1) { } }
SRC

require_ok('swapram allocation link', $vcsc, '-I', $vcs,
           '-Map', $map, '--no-sym', '--no-list', '--no-cfg',
           '-o', $bin, $src);
my $text = slurp($map);
$text =~ /^\s*swapram\s+logical_size=\$40000 type=rw swapram=yes bank_size=\$0400 banks=256\b/m
   or die "swapram memory metadata missing from map\n$text";
$text !~ /^\s*swapram\s+.*\bstart=\$/m
   or die "swapram map incorrectly reports an ordinary CPU start address\n$text";
$text =~ /^\s*BSS\.swapram\.__vcsc_object\$first logical=\$00000 swapram-bank=0 swapram-offset=\$0000 size=\$0300$/m
   or die "first object placement was not bank 0 offset 0\n$text";
$text =~ /^\s*BSS\.swapram\.__vcsc_object\$second logical=\$00400 swapram-bank=1 swapram-offset=\$0000 size=\$0200$/m
   or die "second object did not skip the unusable tail of bank 0\n$text";
$text =~ /^\s*BSS\.swapram\.__vcsc_object\$third logical=\$00300 swapram-bank=0 swapram-offset=\$0300 size=\$0004$/m
   or die "third object did not reuse the remaining bank 0 hole\n$text";
$text !~ /^(?:COPY|ZERO)\s+.*\.swapram(?:\.|\s)/m
   or die "swapram incorrectly generated ordinary CPU startup initialization records\n$text";

my $too_big = File::Spec->catfile($tmp, 'too_big.c26');
write_file($too_big, <<'SRC');
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)
swapram uint8_t huge[1025];
bank3 void main(void) { while (1) { } }
SRC
require_fail('oversized swapram object',
             "region 'swapram' bank_size is only \$0400",
             $vcsc, '-I', $vcs, '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'too_big.bin'), $too_big);

# Prove the allocator and map carry more than 16 logical address bits.  This is
# deliberately a linker/allocation fixture, so define the 65K of storage in
# assembly rather than asking the C startup initializer to zero 65 separate
# objects.  Keep each definition in its own object because the O26 packed BSS
# namespace remains 16-bit per translation unit/object.  Bank 64 starts at
# logical $10000, which was unreachable with the original 16-bit swapram handle.
my $wide_bin = File::Spec->catfile($tmp, 'wide.bin');
my $wide_map = File::Spec->catfile($tmp, 'wide.map');
my $wide_c = File::Spec->catfile($tmp, 'wide_main.c26');
my $wide_keep = File::Spec->catfile($tmp, 'wide_keep.s26');
my @wide_sources = ($wide_c);
write_file($wide_c, <<'SRC');
instantiate "3E/mapper.c26" as mapper (VCS_3E_BANKS:=4)
bank0 void wide_keepalive(void);
bank3 void main(void) { wide_keepalive(); while (1) { } }
SRC
for my $bank (0 .. 64) {
   my $wide_s = File::Spec->catfile($tmp, "wide_$bank.s26");
   write_file($wide_s, qq{.export fill$bank\n.segment "BSS.swapram.__vcsc_object\$fill$bank"\nfill$bank:\n    .res 1024\n});
   push @wide_sources, $wide_s;
}
my $keep_asm = ".export wide_keepalive\n";
for my $bank (0 .. 64) { $keep_asm .= ".import fill$bank\n"; }
$keep_asm .= ".segment \"CODE.bank0.__vcsc_function\$wide_keepalive\"\nwide_keepalive:\n    rts\n";
for my $bank (0 .. 64) {
   $keep_asm .= "    .word fill$bank\n    .byte ^fill$bank\n";
}
write_file($wide_keep, $keep_asm);
push @wide_sources, $wide_keep;
require_ok('wide swapram allocation link', $vcsc, '-I', $vcs,
           '-Map', $wide_map, '--no-sym', '--no-list', '--no-cfg',
           '-o', $wide_bin, @wide_sources);
my $wide_text = slurp($wide_map);
$wide_text =~ /^\s*BSS\.swapram\.__vcsc_object\$fill64 logical=\$10000 swapram-bank=64 swapram-offset=\$0000 size=\$0400$/m
   or die "swapram allocation did not cross the 64K logical boundary\n$wide_text";
$wide_text =~ /^\s*swapram\s+used=66560 bytes .* objects=66560 bytes hardware-stack=0 bytes$/m
   or die "swapram usage accounting did not include all 65K of allocated objects\n$wide_text";
$wide_text =~ /^\s*\$[0-9A-Fa-f]{4}\s+wide_keepalive\b/m
   or die "wide swapram keepalive code was discarded\n$wide_text";

my @invalid = (
   [ 'bank_size_without_swapram',
     'mem bad { $size:0x8000 $bank_size:0x0400 $rw };',
     'may use $bank_size only with $swapram' ],
   [ 'swapram_with_cpu_start',
     'mem bad { $start:0x1000 $size:0x8000 $bank_size:0x0400 $rw $swapram };',
     'with no CPU address' ],
   [ 'swapram_without_bank_size',
     'mem bad { $size:0x8000 $rw $swapram };',
     'must declare $size, $bank_size, exactly $rw, and $swapram' ],
   [ 'swapram_bad_divisor',
     'mem bad { $size:0x8100 $bank_size:0x0400 $rw $swapram };',
     'requires nonzero $bank_size that evenly divides $size' ],
   [ 'swapram_too_many_banks',
     'mem bad { $size:0x40400 $bank_size:0x0400 $rw $swapram };',
     'has more than 256 banks' ],
);
for my $case (@invalid) {
   my ($name, $decl, $fragment) = @$case;
   my $bad = File::Spec->catfile($tmp, "$name.c26");
   write_file($bad, qq{include "vcs.c26"\n$decl\nvoid main(void) { while (1) { } }\n});
   require_fail($name, $fragment,
                $vcsc, '-I', $vcs, '--no-sym', '--no-list', '--no-cfg',
                '-o', File::Spec->catfile($tmp, "$name.bin"), $bad);
}

print "swapram metadata allocation ok\n";
