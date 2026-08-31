#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: startup selection tests passed

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);

my ($repo, $tmp_root) = @ARGV;
die "usage: $0 repo tmp_root\n" if !defined $repo || !defined $tmp_root;

my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');
my $sc_cfg = File::Spec->catfile($vcs, '4KSC/mapper.cfg');
my $tmp = tempdir('VCSC_startup_selection_XXXXXX', DIR => $tmp_root, CLEANUP => 1);

sub write_text {
   my ($path, $text) = @_;
   open my $fh, '>', $path or die "write $path: $!";
   print {$fh} $text;
   close $fh;
}

sub slurp {
   my ($path, $raw) = @_;
   open my $fh, '<', $path or die "read $path: $!";
   binmode $fh if $raw;
   local $/;
   my $text = <$fh>;
   close $fh;
   return $text;
}

sub build_case {
   my ($name, $source, $cfg) = @_;
   my $src = File::Spec->catfile($tmp, "$name.c26");
   my $bin = File::Spec->catfile($tmp, "$name.bin");
   write_text($src, $source);
   my @cmd = ($driver, '-I', $vcs);
   push @cmd, ('-T', $cfg) if defined $cfg;
   push @cmd, ('-o', $bin, $src);
   system(@cmd) == 0 or die "build failed: @cmd\n";
   (my $stem = $bin) =~ s/\.bin$//;
   return {
      bin => slurp($bin, 1),
      map => slurp("$stem.map", 0),
      sym => slurp("$stem.sym", 0),
      list => slurp("$stem.lst", 0),
   };
}

sub require_re {
   my ($text, $re, $what) = @_;
   $text =~ $re or die "missing $what\n";
}

sub forbid_re {
   my ($text, $re, $what) = @_;
   $text !~ $re or die "unexpected $what\n";
}

sub sym_addr {
   my ($sym, $name) = @_;
   $sym =~ /^\Q$name\E\s+([0-9A-Fa-f]{4})\s*$/m
      or die "missing symbol $name\n";
   return hex($1);
}

my $simple = build_case('simple', <<'SOURCE');
include "vcs.c26"
uint8_t byte;
void main(void) {
   byte := 1;
   return;
}
SOURCE

require_re($simple->{sym}, qr/^__vcsc_startup_simple\s+/m, 'compact startup');
forbid_re($simple->{sym}, qr/^__vcsc_startup_full\s+/m, 'full startup in compact case');
require_re($simple->{map}, qr/^\s+policy=compact-riot-clear$/m, 'compact startup map policy');
require_re($simple->{map}, qr/^\s+\(not generated for compact startup\)$/m,
           'suppressed generic startup tables');
require_re($simple->{map}, qr/hardware-stack=0 bytes/, 'zero main-entry stack reserve');
forbid_re($simple->{sym}, qr/^__(?:copy|zero|init)_table\s+/m,
          'generic startup table symbol in compact case');

my $main = sym_addr($simple->{sym}, 'main');
my $reset = sym_addr($simple->{sym}, '__reset');
my $main_off = $main - 0xF000;
$main_off >= 0 && $main_off + 3 <= length($simple->{bin})
   or die "main outside 4K image\n";
substr($simple->{bin}, $main_off, 16) =~ /\x6c\xfc\xff/
   or die "main does not fall through/return through JMP (\$FFFC)\n";
my $reset_vector = unpack('v', substr($simple->{bin}, 0x0FFC, 2));
$reset_vector == $reset
   or die sprintf("RESET vector %04X does not point at __reset %04X\n", $reset_vector, $reset);
my $tail_jmp = pack('C*', 0x4c, $main & 0xff, ($main >> 8) & 0xff);
index($simple->{bin}, $tail_jmp) >= 0
   or die "compact startup does not tail-JMP to main\n";

my $data = build_case('data', <<'SOURCE');
include "vcs.c26"
uint8_t initialized := 7;
void main(void) { }
SOURCE
require_re($data->{sym}, qr/^__vcsc_startup_full\s+/m, 'full startup for DATA');
forbid_re($data->{sym}, qr/^__vcsc_startup_simple\s+/m, 'compact startup for DATA');
require_re($data->{map}, qr/^\s+policy=every-reset bss=zero data=copy-through-write-alias$/m,
           'full startup DATA policy');
require_re($data->{sym}, qr/^__copy_table\s+/m, 'copy table for full startup');

my $runtime_init = build_case('runtime_init', <<'SOURCE');
include "vcs.c26"
uint8_t seed;
uint8_t twice(uint8_t value) { return value + value; }
uint8_t initialized := twice(seed);
void main(void) { }
SOURCE
require_re($runtime_init->{sym}, qr/^__vcsc_startup_full\s+/m,
           'full startup for runtime initializer');

my $cartram = build_case('cartram', <<'SOURCE', $sc_cfg);
include "4KSC/mapper.c26"
cartram uint8_t persistent;
void main(void) { }
SOURCE
require_re($cartram->{sym}, qr/^__vcsc_startup_full\s+/m,
           'full startup for cartridge RAM BSS');
forbid_re($cartram->{sym}, qr/^__vcsc_startup_simple\s+/m,
          'compact startup for cartridge RAM BSS');
require_re($cartram->{map}, qr/ZERO BSS\.cartram\.__vcsc_object\$persistent\s+read=\$F080 write=\$F000 size=\$0001 split=yes/m,
           'cartridge RAM startup zero record');

# The full startup must also tail-enter main; DATA guarantees this case selected it.
my $full_main = sym_addr($data->{sym}, 'main');
my $full_tail_jmp = pack('C*', 0x4c, $full_main & 0xff, ($full_main >> 8) & 0xff);
index($data->{bin}, $full_tail_jmp) >= 0
   or die "full startup does not tail-JMP to main\n";

print "startup selection tests passed\n";
