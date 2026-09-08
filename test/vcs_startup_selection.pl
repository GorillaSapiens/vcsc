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
forbid_re($simple->{sym}, qr/^__vcsc_startup_data\s+/m, 'DATA startup in compact case');
forbid_re($simple->{sym}, qr/^__vcsc_startup_full\s+/m, 'full startup in compact case');
require_re($simple->{map}, qr/^\s+policy=compact-riot-clear$/m, 'compact startup map policy');
require_re($simple->{map}, qr/^\s+\(not generated for compact startup\)$/m,
           'suppressed generic startup tables');
require_re($simple->{map}, qr/hardware-stack=0 bytes/, 'zero main-entry stack reserve');
forbid_re($simple->{sym}, qr/^__(?:copy|zero|init)_table\s+/m,
          'generic startup table symbol in compact case');

my $noinit_riot = build_case('noinit_riot', <<'SOURCE');
include "vcs.c26"
noinit uint8_t preserved;
uint8_t cleared;
void main(void) {
   preserved := preserved + 1;
   cleared := 1;
}
SOURCE
require_re($noinit_riot->{sym}, qr/^__vcsc_startup_full\s+/m,
           'full startup for RIOT noinit');
forbid_re($noinit_riot->{sym}, qr/^__vcsc_startup_simple\s+/m,
          'compact startup for RIOT noinit');
forbid_re($noinit_riot->{sym}, qr/^__vcsc_startup_data\s+/m,
          'DATA startup for RIOT noinit');
require_re($noinit_riot->{map},
           qr/BSS\.__vcsc_noinit\$\.__vcsc_object\$preserved run=\$[0-9A-Fa-f]{4} size=\$0001/m,
           'RIOT noinit layout marker');
require_re($noinit_riot->{map},
           qr/ZERO BSS\.__vcsc_object\$cleared\s+read=\$[0-9A-Fa-f]{4} write=\$[0-9A-Fa-f]{4} size=\$0001/m,
           'ordinary RIOT BSS zero record beside noinit');
forbid_re($noinit_riot->{map},
          qr/ZERO .*__vcsc_noinit.*preserved/m,
          'RIOT noinit zero record');

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
require_re($data->{sym}, qr/^__vcsc_startup_data\s+/m, 'DATA startup for initialized DATA');
forbid_re($data->{sym}, qr/^__vcsc_startup_simple\s+/m, 'compact startup for DATA');
forbid_re($data->{sym}, qr/^__vcsc_startup_full\s+/m, 'full/noinit startup for ordinary DATA');
require_re($data->{map},
           qr/^\s+policy=compact-riot-clear data=copy-through-write-alias init=table$/m,
           'DATA startup policy');
require_re($data->{sym}, qr/^__copy_table\s+/m, 'copy table for DATA startup');
require_re($data->{sym}, qr/^__init_table\s+/m, 'init table for DATA startup');
forbid_re($data->{sym}, qr/^__zero_table\s+/m, 'ZERO table for DATA startup');

my $split_data = build_case('split_data', <<'SOURCE');
include "4KSC/mapper.c26"
cartram uint8_t initialized := 7;
uint8_t cleared;
void main(void) { cleared := initialized; }
SOURCE
require_re($split_data->{sym}, qr/^__vcsc_startup_data\s+/m,
           'DATA startup for initialized split cartridge RAM');
forbid_re($split_data->{sym}, qr/^__vcsc_startup_full\s+/m,
          'full startup for initialized split cartridge RAM without split BSS');
require_re($split_data->{map},
           qr/COPY DATA\.cartram\.__vcsc_object\$initialized\s+load=\$[0-9A-Fa-f]{4} read=\$F080 write=\$F000 size=\$0001 split=yes/m,
           'split cartridge DATA copy through write alias');
forbid_re($split_data->{sym}, qr/^__zero_table\s+/m,
          'ZERO table for split DATA startup');

my $runtime_init = build_case('runtime_init', <<'SOURCE');
include "vcs.c26"
uint8_t seed;
uint8_t twice(uint8_t value) { return value + value; }
uint8_t initialized := twice(seed);
void main(void) { }
SOURCE
require_re($runtime_init->{sym}, qr/^__vcsc_startup_data\s+/m,
           'DATA startup for runtime initializer');
forbid_re($runtime_init->{sym}, qr/^__vcsc_startup_full\s+/m,
          'full/noinit startup for ordinary runtime initializer');

my $cartram = build_case('cartram', <<'SOURCE');
include "4KSC/mapper.c26"
noinit cartram uint8_t preserved;
cartram uint8_t persistent;
void main(void) {
   preserved := preserved + 1;
}
SOURCE
require_re($cartram->{sym}, qr/^__vcsc_startup_full\s+/m,
           'full startup for cartridge RAM BSS');
forbid_re($cartram->{sym}, qr/^__vcsc_startup_simple\s+/m,
          'compact startup for cartridge RAM BSS');
forbid_re($cartram->{sym}, qr/^__vcsc_startup_data\s+/m,
          'DATA startup for noinit cartridge RAM');
require_re($cartram->{map},
           qr/BSS\.cartram\.__vcsc_noinit\$\.__vcsc_object\$preserved run=\$F080 write=\$F000 size=\$0001/m,
           'cartridge RAM noinit layout marker');
require_re($cartram->{map},
           qr/ZERO BSS\.cartram\.__vcsc_object\$persistent\s+read=\$F081 write=\$F001 size=\$0001 split=yes/m,
           'cartridge RAM startup zero record');
forbid_re($cartram->{map},
          qr/ZERO .*__vcsc_noinit.*preserved/m,
          'cartridge RAM noinit zero record');

my $split_bss = build_case('split_bss', <<'SOURCE');
include "4KSC/mapper.c26"
cartram uint8_t persistent;
void main(void) { persistent := 1; }
SOURCE
require_re($split_bss->{sym}, qr/^__vcsc_startup_full\s+/m,
           'full startup for split cartridge BSS');
forbid_re($split_bss->{sym}, qr/^__vcsc_startup_data\s+/m,
          'DATA startup for split cartridge BSS');
require_re($split_bss->{map},
           qr/ZERO BSS\.cartram\.__vcsc_object\$persistent\s+read=\$F080 write=\$F000 size=\$0001 split=yes/m,
           'split cartridge BSS ZERO record');

my $data_noinit = build_case('data_noinit', <<'SOURCE');
include "vcs.c26"
noinit uint8_t preserved;
uint8_t initialized := 7;
void main(void) { preserved := preserved + initialized; }
SOURCE
require_re($data_noinit->{sym}, qr/^__vcsc_startup_full\s+/m,
           'full startup for DATA plus noinit');
forbid_re($data_noinit->{sym}, qr/^__vcsc_startup_data\s+/m,
          'DATA startup for DATA plus noinit');
require_re($data_noinit->{sym}, qr/^__copy_table\s+/m,
           'copy table for DATA plus noinit');
require_re($data_noinit->{sym}, qr/^__zero_table\s+/m,
           'ZERO table for DATA plus noinit');

# Both non-simple stock paths must tail-enter main.
my $data_main = sym_addr($data->{sym}, 'main');
my $data_tail_jmp = pack('C*', 0x4c, $data_main & 0xff, ($data_main >> 8) & 0xff);
index($data->{bin}, $data_tail_jmp) >= 0
   or die "DATA startup does not tail-JMP to main\n";
my $full_main = sym_addr($data_noinit->{sym}, 'main');
my $full_tail_jmp = pack('C*', 0x4c, $full_main & 0xff, ($full_main >> 8) & 0xff);
index($data_noinit->{bin}, $full_tail_jmp) >= 0
   or die "full startup does not tail-JMP to main\n";

print "startup selection tests passed\n";
