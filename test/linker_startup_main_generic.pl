#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: Generic startup-bank main placement passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my ($fh) = @_; local $/; return <$fh> // ''; }
sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   my $stdout = slurp_fh($out);
   my $stderr = slurp_fh($err);
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub require_ok {
   my ($label, @cmd) = @_;
   my ($rc, $sig, $out, $err) = run_capture(@cmd);
   $rc == 0 && !$sig
      or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out, $err);
}
sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "write $path: $!\n";
   print {$fh} $text or die "write $path: $!\n";
   close($fh) or die "close $path: $!\n";
}
sub read_file {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "read $path: $!\n";
   local $/;
   my $text = <$fh> // '';
   close($fh);
   return $text;
}

my ($repo, $tmp) = @ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $ld = File::Spec->catfile($repo, 'linker', 'vcsc-ld');
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $test_inc = File::Spec->catdir($repo, 'test');
my $cfg = File::Spec->catfile($tmp, 'fruit-banks.cfg');

# The names deliberately contain no BANK0/BANK1 convention.  CODE defaults to
# the non-startup bank, so the assembly fixture proves that unqualified main is
# pinned by startup=yes rather than by its configured fallback segment.
write_file($cfg, <<'CFG');
CARTRIDGE {
    mapper = F8;
    fillval = $FF;
    trampoline = $0F00;
    trampolinesize = $00E0;
    vectorbridge = $0FE0;
}
BANKS {
    PEAR:   start = $F000, size = $1000, hotspot = $1FF9, startup = yes;
    BANANA: start = $D000, size = $1000, hotspot = $1FF8, startup = no;
}
MEMORY {
    RAM: start = $0080, size = $0080, type = rw, define = yes, callstack = callgraph;

    orange_code:          start = $D000, size = $0F00, type = ro, define = yes, bank = BANANA;
    BANANA_TRAMPOLINE:    start = $DF00, size = $00E0,                         bank = BANANA;
    BANANA_VECTOR_BRIDGE: start = $DFE0, size = $0012,                         bank = BANANA;
    BANANA_TAIL:          start = $DFF2, size = $0008,                         bank = BANANA;
    BANANA_VECTORS:       start = $DFFA, size = $0006,                         bank = BANANA;

    pear_code:            start = $F000, size = $0F00, type = ro, define = yes, bank = PEAR;
    PEAR_TRAMPOLINE:      start = $FF00, size = $00E0,                         bank = PEAR;
    PEAR_VECTOR_BRIDGE:   start = $FFE0, size = $0012,                         bank = PEAR;
    PEAR_TAIL:            start = $FFF2, size = $0008,                         bank = PEAR;
    PEAR_VECTORS:         start = $FFFA, size = $0006,                         bank = PEAR;
}
SEGMENTS {
    ZEROPAGE:             load = pear_code, run = RAM, type = zp, define = yes;
    DATA:                 load = pear_code, run = RAM, type = data, define = yes;
    BSS:                  load = RAM, type = bss, define = yes;
    STARTUP:              load = pear_code, type = ro, define = yes;
    CODE:                 load = orange_code, type = ro, define = yes;
    CODE.pear_code:       load = pear_code, type = ro, define = yes;
    CODE.orange_code:     load = orange_code, type = ro, define = yes;
    RODATA:               load = pear_code, type = ro, define = yes;
    RODATA.pear_code:     load = pear_code, type = ro, define = yes;
    RODATA.orange_code:   load = orange_code, type = ro, define = yes;
    VECTORS:              load = PEAR_VECTORS, type = ro, start = $FFFA;
}
CFG

my $asm = File::Spec->catfile($tmp, 'plain-main.s26');
my $obj = File::Spec->catfile($tmp, 'plain-main.o26');
my $bin = File::Spec->catfile($tmp, 'plain-main.bin');
my $map_path = File::Spec->catfile($tmp, 'plain-main.map');
write_file($asm, <<'ASM');
.export __reset
.export __nmi
.export __irqbrk
.export main
.segment "STARTUP"
.proc __reset
   RTS
.endproc
.proc __nmi
   RTS
.endproc
.proc __irqbrk
   RTS
.endproc
.segment "CODE.__vcsc_function$main"
.proc main
   RTS
.endproc
ASM
require_ok('assemble arbitrary-name startup fixture', $as, '-o', $obj, $asm);
require_ok('link arbitrary-name startup fixture', $ld, '-T', $cfg,
           '-Map', $map_path, '--no-sym', '--no-list', '--no-cfg',
           '-o', $bin, $obj);
-s $bin == 8192 or die "arbitrary-name F8 image does not contain two 4K banks\n";
my $map = read_file($map_path);
$map =~ /^\s*PEAR\s+start=\$F000 size=\$1000 hotspot=\$1FF9 .*startup=yes/m &&
$map =~ /^\s*BANANA\s+start=\$D000 size=\$1000 hotspot=\$1FF8 /m
   or die "map lost arbitrary logical bank names\n$map";
$map =~ /^\s*automatic\s+CODE\.__vcsc_function\$main(?:\.__vcsc_function\$main)?\s+region=pear_code\b/m
   or die "unqualified main was not automatically placed in PEAR/pear_code\n$map";
$map !~ /^\s*(?:automatic|pinned)\s+CODE\.__vcsc_function\$main(?:\.__vcsc_function\$main)?\s+region=orange_code\b/m
   or die "unqualified main followed the non-startup CODE fallback\n$map";

# The compiler accepts a named region on main and leaves startup validation to
# the linker, which has the BANKS/MEMORY relationship needed to decide it.
my $bad_src = File::Spec->catfile($tmp, 'bad-main.c26');
write_file($bad_src, <<'SOURCE');
include "machine_6502.c26"
mem pear_code { $start:0xF000 $size:0x0F00 $ro };
mem orange_code { $start:0xD000 $size:0x0F00 $ro };
orange_code void main(void) {}
SOURCE
my ($bad_rc, $bad_sig, $bad_out, $bad_err) = run_capture(
   $driver, '-I', $test_inc, '-T', $cfg, $bad_src,
   '-o', File::Spec->catfile($tmp, 'bad-main.bin'));
$bad_rc != 0 && !$bad_sig
   or die "main explicitly placed in a non-startup region unexpectedly linked\n$bad_out\n$bad_err";
$bad_err =~ /entry function 'main' is placed in MEMORY region 'orange_code'/ &&
$bad_err =~ /non-startup bank 'BANANA'/ &&
$bad_err =~ /configured startup bank is 'PEAR'/
   or die "non-startup main diagnostic was not expressed through configured names\n$bad_err";
$bad_err !~ /bank0|BANK0|bank1|BANK1/
   or die "generic main diagnostic leaked conventional bank names\n$bad_err";

print "Generic startup-bank main placement passed\n";
