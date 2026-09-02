#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: per-bank reset bridges verified
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
}
sub require_fail {
   my ($label, $fragment, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   ($exit != 0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n";
   index($err, $fragment) >= 0
      or die "$label stderr missing '$fragment'\nstdout:\n$out\nstderr:\n$err";
}
sub bank_start {
   my ($bank) = @_;
   return 0xF000 - $bank * 0x2000;
}
# Keep VCSC logical BANKn, physical/file chunk index, and selector hotspot
# distinct.  The first mapper hotspot selects file chunk 0.  VCSC writes BANK0
# last, so BANK0 uses the final hotspot in the mapper range.
sub mapper_info {
   my ($mapper) = @_;
   return (2, 0x1FF8) if $mapper eq 'F8';
   return (4, 0x1FF6) if $mapper eq 'F6';
   return (8, 0x1FF4) if $mapper eq 'F4';
   die "unknown mapper $mapper\n";
}
sub file_index_for_vcsc_bank {
   my ($count, $bank) = @_;
   return $count - 1 - $bank;
}
sub hotspot_for_vcsc_bank {
   my ($mapper, $bank) = @_;
   my ($count, $first_hotspot) = mapper_info($mapper);
   return $first_hotspot + file_index_for_vcsc_bank($count, $bank);
}
sub make_cfg {
   my ($mapper, $bridge) = @_;
   my ($count, $first_hotspot) = mapper_info($mapper);
   my $banks = '';
   my $memory = '';
   for my $bank (0 .. $count - 1) {
      my $start = bank_start($bank);
      my $hotspot = hotspot_for_vcsc_bank($mapper, $bank);
      $banks .= sprintf("   BANK%d: start=\$%04X, size=\$1000, hotspot=\$%04X, startup=%s;\n",
                        $bank, $start, $hotspot, $bank == 0 ? 'yes' : 'no');
      $memory .= sprintf("   BANK%d_TRAMPOLINE: start=\$%04X, size=\$00E0, bank=BANK%d;\n",
                         $bank, $start + 0x0F00, $bank);
      $memory .= sprintf("   BANK%d_VECTOR_BRIDGE: start=\$%04X, size=\$0012, bank=BANK%d;\n",
                         $bank, $start + 0x0FE0, $bank);
      $memory .= sprintf("   BANK%d_TAIL: start=\$%04X, size=\$0008, bank=BANK%d;\n",
                         $bank, $start + 0x0FF2, $bank);
      $memory .= sprintf("   BANK%d_VECTORS: start=\$%04X, size=\$0006, bank=BANK%d;\n",
                         $bank, $start + 0x0FFA, $bank);
   }
   return sprintf(<<'CFG', $mapper, $bridge, $banks, $memory);
CARTRIDGE {
   mapper = %s;
   fillval = $C3;
   trampoline = $0F00;
   trampolinesize = $00E0;
   vectorbridge = $%03X;
}
BANKS {
%s}
MEMORY {
   ZEROPAGE: start=$0000, size=$0080, type=rw;
   RAM: start=$0080, size=$0080, type=rw;
   ROM: start=$F000, size=$0F00, type=ro, bank=BANK0;
%s}
SEGMENTS {
   ZEROPAGE: load=ROM, run=ZEROPAGE, type=zp;
   DATA: load=ROM, run=RAM, type=data;
   BSS: load=RAM, type=bss;
   STARTUP: load=ROM, type=ro;
   CODE: load=ROM, type=ro;
   RODATA: load=ROM, type=ro;
   VECTORS: load=BANK0_VECTORS, type=ro, start=$FFFA;
}
CFG
}
sub symbol_addr {
   my ($map, $name) = @_;
   return hex($1) if $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m;
   my $weak = "__weak_$name";
   return hex($1) if $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$weak\E\b/m;
   die "map omitted $name\n$map";
}
sub chunk_offset_for_bank {
   my ($count, $bank) = @_;
   return file_index_for_vcsc_bank($count, $bank) * 0x1000;
}
sub cart_byte {
   my ($image, $count, $bank, $address) = @_;
   my $offset = chunk_offset_for_bank($count, $bank) + ($address & 0x0FFF);
   return ord(substr($image, $offset, 1));
}
sub hotspot_bank {
   my ($mapper, $address) = @_;
   my ($count, $first_hotspot) = mapper_info($mapper);
   my $cart_address = $address & 0x1FFF;
   my $file_index = $cart_address - $first_hotspot;
   return undef if $file_index < 0 || $file_index >= $count;
   return $count - 1 - $file_index;
   return undef;
}
sub vector_fetch {
   my ($image, $mapper, $count, $selected, $address) = @_;
   my @bytes;
   for my $a ($address, $address + 1) {
      push @bytes, cart_byte($image, $count, $selected, $a);
      my $new_bank = hotspot_bank($mapper, $a);
      $selected = $new_bank if defined $new_bank;
   }
   return ($bytes[0] | ($bytes[1] << 8), $selected);
}
sub simulate_vector_bridge {
   my ($image, $mapper, $count, $initial_bank, $vector_address,
       $expected_bridge, $expected_handler) = @_;
   my ($pc, $selected) = vector_fetch($image, $mapper, $count,
                                      $initial_bank, $vector_address);
   $pc == $expected_bridge
      or die "$mapper vector at \$" . sprintf('%04X', $vector_address) .
             " from BANK$initial_bank produced \$" . sprintf('%04X', $pc) .
             ", expected \$" . sprintf('%04X', $expected_bridge) . "\n";
   cart_byte($image, $count, $selected, $pc) == 0x0C
      or die "$mapper bridge did not begin with raw NMOS NOP absolute\n";
   my $hotspot = cart_byte($image, $count, $selected, $pc + 1) |
                 (cart_byte($image, $count, $selected, $pc + 2) << 8);
   my $new_bank = hotspot_bank($mapper, $hotspot);
   defined($new_bank) && $new_bank == 0
      or die "$mapper bridge selected hotspot \$" . sprintf('%04X', $hotspot) .
             " instead of BANK0\n";
   $selected = $new_bank;
   cart_byte($image, $count, $selected, $pc + 3) == 0x4C
      or die "$mapper bridge continuation was not fetched from BANK0 as JMP absolute\n";
   my $target = cart_byte($image, $count, $selected, $pc + 4) |
                (cart_byte($image, $count, $selected, $pc + 5) << 8);
   $target == $expected_handler
      or die "$mapper bridge target was \$" . sprintf('%04X', $target) .
             ", expected \$" . sprintf('%04X', $expected_handler) . "\n";
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $vcsc = File::Spec->catfile($repo, 'driver', 'vcsc');
my $include = File::Spec->catfile($repo, 'test');
my $src = File::Spec->catfile($tmp, 'reset.c26');
write_file($src, <<'SRC');
include "machine_6502.c26"
mem ZEROPAGE { $start:0x0000 $size:0x0080 $rw $priority:3 };
mem RAM { $start:0x0080 $size:0x0080 $rw $priority:2 };
mem ROM { $start:0xF000 $size:0x0F00 $ro $priority:2 };
void main(void) { asm nop; }
SRC

for my $mapper (qw(F8 F6 F4)) {
   my ($count, $first_hotspot) = mapper_info($mapper);
   my $bank0_hotspot = hotspot_for_vcsc_bank($mapper, 0);
   for my $bank (0 .. $count - 1) {
      my $file_index = file_index_for_vcsc_bank($count, $bank);
      my $hotspot = hotspot_for_vcsc_bank($mapper, $bank);
      $hotspot == $first_hotspot + $file_index
         or die "$mapper BANK$bank hotspot/file-index relation broke\n";
      hotspot_bank($mapper, $hotspot) == $bank
         or die "$mapper hotspot reverse lookup broke for BANK$bank\n";
   }
   my $cfg = File::Spec->catfile($tmp, lc($mapper) . '.cfg');
   my $bin = File::Spec->catfile($tmp, lc($mapper) . '.bin');
   my $map_path = File::Spec->catfile($tmp, lc($mapper) . '.map');
   write_file($cfg, make_cfg($mapper, 0x0FE0));
   require_ok("$mapper reset-bridge link", $vcsc, '-I', $include, '-DMACHINE_6502_NO_DEFAULT_ZEROPAGE', '-DMACHINE_6502_NO_DEFAULT_CPUSTACK', '-DMACHINE_6502_NO_DEFAULT_RAM', '-DMACHINE_6502_NO_DEFAULT_ROM',
              '-T', $cfg, '-Map', $map_path,
              '--no-sym', '--no-list', '--no-cfg', '-o', $bin, $src);
   my $image = slurp($bin);
   length($image) == $count * 0x1000
      or die "$mapper output length was " . length($image) . "\n";
   my $map = slurp($map_path);
   my $reset = symbol_addr($map, '__reset');
   my $nmi = symbol_addr($map, '__nmi');
   my $irqbrk = symbol_addr($map, '__irqbrk');
   my $main = symbol_addr($map, 'main');
   (($reset & 0xF000) == 0xF000 && ($nmi & 0xF000) == 0xF000 &&
    ($irqbrk & 0xF000) == 0xF000 && ($main & 0xF000) == 0xF000)
      or die "$mapper startup handlers or main escaped BANK0\n";

   my $expected_bridge = pack('C*',
      0x0C, $bank0_hotspot & 0xFF, $bank0_hotspot >> 8,
      0x4C, $nmi & 0xFF, $nmi >> 8,
      0x0C, $bank0_hotspot & 0xFF, $bank0_hotspot >> 8,
      0x4C, $reset & 0xFF, $reset >> 8,
      0x0C, $bank0_hotspot & 0xFF, $bank0_hotspot >> 8,
      0x4C, $irqbrk & 0xFF, $irqbrk >> 8);
   my $expected_vectors = pack('v3', 0xFFE0, 0xFFE6, 0xFFEC);

   for my $bank (0 .. $count - 1) {
      my $chunk = chunk_offset_for_bank($count, $bank);
      substr($image, $chunk + 0x0FE0, 18) eq $expected_bridge
         or die "$mapper BANK$bank bridge differs from common bridge image\n";
      substr($image, $chunk + 0x0FFA, 6) eq $expected_vectors
         or die "$mapper BANK$bank vectors differ from common vector image\n";
      simulate_vector_bridge($image, $mapper, $count, $bank,
                             0xFFFA, 0xFFE0, $nmi);
      simulate_vector_bridge($image, $mapper, $count, $bank,
                             0xFFFC, 0xFFE6, $reset);
      simulate_vector_bridge($image, $mapper, $count, $bank,
                             0xFFFE, 0xFFEC, $irqbrk);
   }
}

my $missing_cfg = File::Spec->catfile($tmp, 'missing-vectorbridge.cfg');
my $missing_text = make_cfg('F8', 0x0FE0);
$missing_text =~ s/^\s*vectorbridge\s*=.*\n//m;
write_file($missing_cfg, $missing_text);
require_fail('missing vectorbridge', 'requires CARTRIDGE vectorbridge',
             $vcsc, '-I', $include, '-DMACHINE_6502_NO_DEFAULT_ZEROPAGE', '-DMACHINE_6502_NO_DEFAULT_CPUSTACK', '-DMACHINE_6502_NO_DEFAULT_RAM', '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $missing_cfg,
             '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'missing.bin'), $src);

my $selector_cfg = File::Spec->catfile($tmp, 'selector-overlap.cfg');
write_file($selector_cfg, make_cfg('F8', 0x0FE8));
require_fail('vector bridge over selector', 'overlaps BANK0 selector hotspot $1FF9',
             $vcsc, '-I', $include, '-DMACHINE_6502_NO_DEFAULT_ZEROPAGE', '-DMACHINE_6502_NO_DEFAULT_CPUSTACK', '-DMACHINE_6502_NO_DEFAULT_RAM', '-DMACHINE_6502_NO_DEFAULT_ROM', '-T', $selector_cfg,
             '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'selector.bin'), $src);

print "per-bank reset bridges verified\n";
