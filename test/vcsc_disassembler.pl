#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcsc-disas regression suite ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);
use File::Spec;

my $repo = abs_path($ARGV[0] // die "missing repo\n");
my $tmp = $ARGV[1] // die "missing temp directory\n";
make_path($tmp) if !-d $tmp;

my $disas = File::Spec->catfile($repo, 'disassembler', 'vcsc-disas');
my $roundtrip = File::Spec->catfile($repo, 'disassembler', 'roundtrip.pl');
my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
-f $disas or die "missing $disas\n";
-f $roundtrip or die "missing $roundtrip\n";
-f $as or die "missing $as\n";

sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not open $path: $!\n";
   local $/;
   my $x = <$fh>;
   close($fh);
   return $x;
}

sub write_bin {
   my ($path, $bytes) = @_;
   open(my $fh, '>:raw', $path) or die "could not create $path: $!\n";
   print {$fh} $bytes;
   close($fh);
}

sub put16 {
   my ($sref, $off, $v) = @_;
   substr($$sref, $off, 2, pack('v', $v));
}

sub make_rom {
   my ($size, $origin, $code_off, $code) = @_;
   my $rom = chr(0xEA) x $size;
   substr($rom, $code_off, length($code), $code);
   my $bank_size = $size == 2048 ? 2048 : ($size >= 4096 && ($size % 4096) == 0 ? 4096 : $size);
   my $banks = int($size / $bank_size);
   for my $b (0 .. $banks - 1) {
      my $base = $b * $bank_size;
      my $vec = $bank_size - 6;
      put16(\$rom, $base + $vec + 0, $origin + $code_off);
      put16(\$rom, $base + $vec + 2, $origin + $code_off);
      put16(\$rom, $base + $vec + 4, $origin + $code_off);
   }
   return $rom;
}

sub require_re {
   my ($text, $re, $what) = @_;
   die "missing $what\n" if $text !~ $re;
}

sub run_ok {
   my (@cmd) = @_;
   system(@cmd) == 0 or die "command failed: @cmd\n";
}

my $in = File::Spec->catdir($tmp, 'disas-in');
my $out = File::Spec->catdir($tmp, 'disas-out');
remove_tree($in, $out);
make_path($in, $out);

# Plain 2K/4K and ordinary F8/F6/F4 sizes.
write_bin(File::Spec->catfile($in, 'plain2k.bin'), make_rom(2048, 0xF800, 0x0100, "\xA9\x42\x60"));
write_bin(File::Spec->catfile($in, 'plain4k.bin'), make_rom(4096, 0xF000, 0x0100, "\xA9\x42\x60"));
# Vector targets may legally point into the high byte of another vector.
# $FFFF is especially useful as a sentinel and must not produce an unresolved
# L_FFFF label merely because the high byte lives inside the IRQ .word.
my $vector_interior = make_rom(4096, 0xF000, 0x0100, "\xA9\x42\x60");
put16(\$vector_interior, 0xFFE, 0xFFFF);
write_bin(File::Spec->catfile($in, 'vector_interior.bin'), $vector_interior);

# Vector-table bytes can themselves be executable code.  This is not merely a
# theoretical overlap: commercial cartridges use vector bytes as tiny helpers.
# The NMI value below is $604A, but the physical bytes are also LSR A / RTS and
# both addresses are called explicitly.  The source emitter must split the
# vector container so L_FFFA and L_FFFB can be real instruction labels.
my $vector_exec = make_rom(4096, 0xF000, 0x0100,
   "\x20\xFA\xFF\x20\xFB\xFF\x60");
substr($vector_exec, 0xFFA, 2, "\x4A\x60");
put16(\$vector_exec, 0xFFC, 0xF000);
put16(\$vector_exec, 0xFFE, 0xF000);
write_bin(File::Spec->catfile($in, 'vector_exec.bin'), $vector_exec);
write_bin(File::Spec->catfile($in, 'origin_d000.bin'), make_rom(4096, 0xD000, 0x0234, "\xA9\x17\x60"));
write_bin(File::Spec->catfile($in, 'f8.bin'), make_rom(8192, 0xF000, 0x0100, "\xAD\xF8\x1F\x60"));
# A plain F8 ROM may legitimately read ordinary ROM in $F080-$F0FF.
# Read-window-looking evidence alone must not promote it to Superchip.
write_bin(File::Spec->catfile($in, 'f8_sc_read_only.bin'),
   make_rom(8192, 0xF000, 0x0100, "\xAD\x80\xF0\xAD\xF8\x1F\x60"));
write_bin(File::Spec->catfile($in, 'f6.bin'), make_rom(16384, 0xF000, 0x0100, "\xAD\xF6\x1F\x60"));
write_bin(File::Spec->catfile($in, 'f4.bin'), make_rom(32768, 0xF000, 0x0100, "\xAD\xF4\x1F\x60"));

# CBS RAM Plus / FA: three 4K banks, selectors $1FF8-$1FFA, 256 bytes
# of RAM with write $1000-$10FF and read $1100-$11FF.  The first $200
# physical bytes of each bank are therefore hidden from runtime ROM fetches.
# Use distinct mirrored 6507 origins to prove origin inference is not tied to
# $F000, and chain bank2 -> bank0 -> bank1 through FA hotspots.
my $fa = "\x02" x 12288;
for my $b (0 .. 2) {
   my $base = $b * 4096;
   my $origin = 0x3000 + $b * 0x2000;
   substr($fa, $base + 0x0208, 0x0B, "\xEA" x 0x0B);
   for my $v (0, 2, 4) {
      put16(\$fa, $base + 0x0FFA + $v, $origin + 0x0208);
   }
}
substr($fa, 0x2000 + 0x0208, 3, "\xAD\xF8\x1F"); # bank2 -> bank0
substr($fa, 0x0000 + 0x020B, 3, "\xAD\xF9\x1F"); # bank0 -> bank1
substr($fa, 0x1000 + 0x020E, 1, "\x60");             # bank1 RTS
write_bin(File::Spec->catfile($in, 'fa.bin'), $fa);

# A bank origin can be inferred from absolute JMP evidence even when that bank
# has unusable vectors.  Bank 1 keeps one real RESET path so the cartridge still
# contains established executable code under the zero-instruction success rule.
my $jmp_origins = chr(0xEA) x 8192;
substr($jmp_origins, 0x0100, 3, pack('C v', 0x4C, 0xD234));
substr($jmp_origins, 0x1000 + 0x0100, 3, pack('C v', 0x4C, 0xF456));
for my $v (0, 2, 4) {
   put16(\$jmp_origins, 0x0FFA + $v, 0x0000);
   put16(\$jmp_origins, 0x1FFA + $v, 0xF100);
}
write_bin(File::Spec->catfile($in, 'jmp_origin_f8.bin'), $jmp_origins);

# DPC is uniquely recognizable by its 10K/10495-byte physical layout.  The
# first 8K are two F8-style 4K program banks; the following 2K are DPC data
# ROM and the standard dump carries a final 255-byte RNG table.
my $dpc = chr(0xEA) x 10495;
substr($dpc, 0x0880, 7, "\xAD\x00\x10\xAD\xF9\x1F\x60");
substr($dpc, 0x1000 + 0x0880, 7, "\xAD\x01\x10\xAD\xF8\x1F\x60");
for my $v (0, 2, 4) {
   put16(\$dpc, 0x0FFA + $v, 0xD880);
   put16(\$dpc, 0x1FFA + $v, 0xF880);
}
for my $i (0x2000 .. 0x28FE) {
   substr($dpc, $i, 1, chr(($i * 29 + 7) & 255));
}
write_bin(File::Spec->catfile($in, 'dpc.bin'), $dpc);

# All eight conditional branches, each in both same-page and cross-page cases.
my @branch_ops = (0x10, 0x30, 0x50, 0x70, 0x90, 0xB0, 0xD0, 0xF0);
my $branch = chr(0xEA) x 4096;
my $main = 0x020;
my $cursor = $main;
for my $i (0 .. $#branch_ops) {
   my $same = 0x810 + $i * 0x100;
   my $cross = 0x0FD + $i * 0x100;
   substr($branch, $cursor, 3, pack('C v', 0x20, 0xF000 + $same)); $cursor += 3;
   substr($branch, $cursor, 3, pack('C v', 0x20, 0xF000 + $cross)); $cursor += 3;
   substr($branch, $same, 4, pack('C C C C', $branch_ops[$i], 1, 0xEA, 0x60));
   substr($branch, $cross, 3, pack('C C C', $branch_ops[$i], 1, 0xEA));
   substr($branch, $cross + 3, 1, "\x60");
}
substr($branch, $cursor, 1, "\x60");
put16(\$branch, 0xFFA, 0xF000 + $main);
put16(\$branch, 0xFFC, 0xF000 + $main);
put16(\$branch, 0xFFE, 0xF000 + $main);
write_bin(File::Spec->catfile($in, 'branches.bin'), $branch);

# Reachable overlapping BIT-skip stream.
my $bit = make_rom(4096, 0xF000, 0x0100,
   "\xA5\x80" .       # LDA $80
   "\xD0\x03" .       # BNE F107
   "\xA2\x01" .       # LDX #1
   "\x2C" .           # BIT abs swallows A2 02 on fallthrough
   "\xA2\x02" .       # alternate entry
   "\x86\x81\x60");
write_bin(File::Spec->catfile($in, 'bit_skip.bin'), $bit);

# Generic non-BIT overlap: branch into the operand of LDA absolute, where the
# operand bytes are themselves LDA #$42 on the alternate path.
my $overlap = make_rom(4096, 0xF000, 0x0100,
   "\xD0\x03" .          # BNE F105
   "\xEA\xEA" .          # fallthrough padding
   "\xAD\xA9\x42" .   # LDA $42A9; inner stream begins at A9
   "\x60");
write_bin(File::Spec->catfile($in, 'generic_overlap.bin'), $overlap);

# Operand at F101 is executable metadata and is also deliberately read as data.
my $cad = make_rom(4096, 0xF000, 0x0100,
   "\xA9\x42" .              # F100 LDA #$42
   "\x20\x08\xF1" .        # F102 JSR F108
   "\x60\xEA\xEA" .        # F105
   "\xAD\x01\xF1\x60"); # F108 LDA F101
write_bin(File::Spec->catfile($in, 'code_as_data.bin'), $cad);

# Known zero-page pointer state should resolve an indirect ROM read without
# pessimistically marking the entire cartridge possibly referenced.  The rest
# of the padding is therefore provably unreferenced.
my $known_ptr = make_rom(4096, 0xF000, 0x0100,
   "\xA9\x00\x85\x80" .      # low pointer byte := $00
   "\xA9\xF2\x85\x81" .      # high pointer byte := $F2
   "\xA0\x00" .                 # Y := 0
   "\xB1\x80\x60");            # LDA ($80),Y; RTS
substr($known_ptr, 0x0200, 1, "\x5A");
write_bin(File::Spec->catfile($in, 'known_indirect_data.bin'), $known_ptr);

# Countdown-indexed graphics table.  The load feeds GRP0 and the DEY/BPL loop
# proves an eight-byte span, which should be emitted one visual row per line.
my $sprite = make_rom(4096, 0xF000, 0x0100,
   "\xA0\x07" .                 # LDY #7
   "\xB9\x00\xF2" .           # LDA $F200,Y
   "\x85\x1B" .                 # STA GRP0
   "\x88" .                         # DEY
   "\x10\xF8" .                 # BPL F102
   "\x60");                        # RTS
substr($sprite, 0x0200, 8,
   pack('C*', 0x3C, 0x66, 0xC3, 0xDB, 0xDB, 0xC3, 0x66, 0x3C));
write_bin(File::Spec->catfile($in, 'sprite_rows.bin'), $sprite);

# A bitmap-looking table that never reaches a TIA graphics register must stay
# ordinary numeric data; appearance alone is not sprite evidence.
my $not_sprite = make_rom(4096, 0xF000, 0x0100,
   "\xA0\x07" .                 # LDY #7
   "\xB9\x00\xF2" .           # LDA $F200,Y
   "\x85\x80" .                 # STA ordinary RAM
   "\x88\x10\xF8\x60");    # DEY/BPL; RTS
substr($not_sprite, 0x0200, 8,
   pack('C*', 0x3C, 0x66, 0xC3, 0xDB, 0xDB, 0xC3, 0x66, 0x3C));
write_bin(File::Spec->catfile($in, 'not_sprite.bin'), $not_sprite);

# Graphics provenance survives simple ALU transforms.  PF0 sees only the high
# nibble after AND, but each source byte is still directly graphical data.
my $graphics_mask = make_rom(4096, 0xF000, 0x0100,
   "\xA0\x07" .                 # LDY #7
   "\xB9\x00\xF2" .           # LDA $F200,Y
   "\x29\xF0" .                 # AND #$F0
   "\x85\x0D" .                 # STA PF0
   "\x88\x10\xF6\x60");    # DEY/BPL F102; RTS
substr($graphics_mask, 0x0200, 8,
   pack('C*', 0xF0, 0xE0, 0xC0, 0x80, 0x10, 0x30, 0x70, 0xF0));
write_bin(File::Spec->catfile($in, 'graphics_mask.bin'), $graphics_mask);

# X/Y loads and stores are legitimate graphics paths too.  This table is loaded
# through X and written directly to GRP1 through STX.
my $graphics_stx = make_rom(4096, 0xF000, 0x0100,
   "\xA0\x07" .                 # LDY #7
   "\xBE\x20\xF2" .           # LDX $F220,Y
   "\x86\x1C" .                 # STX GRP1
   "\x88\x10\xF8\x60");    # DEY/BPL F102; RTS
substr($graphics_stx, 0x0220, 8,
   pack('C*', 0x18, 0x3C, 0x7E, 0xDB, 0xFF, 0x24, 0x24, 0x24));
write_bin(File::Spec->catfile($in, 'graphics_stx.bin'), $graphics_stx);

# Register transfers retain graphics provenance: A loaded from ROM is copied into
# X before STX publishes it to GRP1.
my $graphics_transfer = make_rom(4096, 0xF000, 0x0100,
   "\xA0\x07" .                 # LDY #7
   "\xB9\x30\xF2" .           # LDA $F230,Y
   "\xAA" .                         # TAX
   "\x86\x1C" .                 # STX GRP1
   "\x88\x10\xF7\x60");    # DEY/BPL F102; RTS
substr($graphics_transfer, 0x0230, 8,
   pack('C*', 0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81));
write_bin(File::Spec->catfile($in, 'graphics_transfer.bin'), $graphics_transfer);

# The symmetric Y-register path is valid too: LDY absolute,X feeding STY GRP0.
my $graphics_sty = make_rom(4096, 0xF000, 0x0100,
   "\xA2\x07" .                 # LDX #7
   "\xBC\x28\xF2" .           # LDY $F228,X
   "\x84\x1B" .                 # STY GRP0
   "\xCA\x10\xF8\x60");    # DEX/BPL F102; RTS
substr($graphics_sty, 0x0228, 8,
   pack('C*', 0x7E, 0x42, 0x5A, 0x5A, 0x42, 0x42, 0x7E, 0x00));
write_bin(File::Spec->catfile($in, 'graphics_sty.bin'), $graphics_sty);

# A runtime-indexed font/table gets a bounded graphics range.  The explicit
# routine at F210 supplies a hard end boundary, so exactly 16 font bytes should
# become visual rows even though X is not statically known.
my $font_rows = make_rom(4096, 0xF000, 0x0100,
   "\xAD\x80\x02" .           # LDA SWCHA
   "\x29\x0F\xAA" .           # AND #$0F / TAX
   "\xBD\x00\xF2" .           # LDA $F200,X
   "\x85\x1B" .                 # STA GRP0
   "\x20\x10\xF2\x60");    # JSR F210; RTS
substr($font_rows, 0x0200, 16,
   pack('C*',
      0x3C,0x66,0x6E,0x76,0x66,0x66,0x3C,0x00,
      0x18,0x38,0x18,0x18,0x18,0x18,0x3C,0x00));
substr($font_rows, 0x0210, 1, "\x60");
write_bin(File::Spec->catfile($in, 'font_rows.bin'), $font_rows);

# Random-looking data with no TIA graphics provenance stays numeric even when
# indexed like a table.
my $random_table = make_rom(4096, 0xF000, 0x0100,
   "\xA0\x0F" .                 # LDY #15
   "\xB9\x40\xF2" .           # LDA $F240,Y
   "\x85\x80" .                 # STA ordinary RAM
   "\x88\x10\xF8\x60");    # DEY/BPL; RTS
substr($random_table, 0x0240, 16,
   pack('C*', 0x93,0x07,0xE1,0x4C,0xB6,0x2A,0xD8,0x55,
              0x01,0xFE,0x73,0x8D,0xC2,0x39,0xA4,0x60));
write_bin(File::Spec->catfile($in, 'random_table.bin'), $random_table);

# Compressed/transformed-looking bytes whose route to GRP0 crosses a subroutine
# remain numeric.  The conservative detector must not invent direct graphics
# provenance across a call whose effects are not proven.
my $compressed = make_rom(4096, 0xF000, 0x0100,
   "\xA0\x07" .                 # LDY #7
   "\xB9\x60\xF2" .           # LDA $F260,Y
   "\x20\x80\xF1" .           # JSR transform
   "\x85\x1B" .                 # STA GRP0
   "\x88\x10\xF5\x60");    # DEY/BPL F102; RTS
substr($compressed, 0x0180, 4, "\x49\x5A\x2A\x60"); # EOR/ROL/RTS
substr($compressed, 0x0260, 8,
   pack('C*', 0xD3,0x11,0x8E,0x70,0x2C,0xF5,0x49,0xA6));
write_bin(File::Spec->catfile($in, 'compressed_table.bin'), $compressed);

# Static tracing must stop cleanly when execution leaves cartridge ROM.
my $dynamic_exit = make_rom(4096, 0xF000, 0x0100,
   "\x4C\x80\x00");            # JMP $0080 (RIOT RAM)
write_bin(File::Spec->catfile($in, 'dynamic_exit.bin'), $dynamic_exit);

# Canonical and mirrored hardware accesses, including RIOT.
my $hw = make_rom(4096, 0xF000, 0x0100,
   "\x85\x09" .             # STA COLUBK
   "\x8D\x09\x01" .       # STA.a COLUBK mirror
   "\xAD\x3C\x03" .       # LDA.a INPT4 mirror
   "\xAD\x80\x03" .       # LDA.a SWCHA mirror
   "\x8D\x96\x03" .       # STA.a TIM64T mirror
   "\x0E\x30\x01" .       # ASL.a TIA read/write mirror
   "\xEE\x80\x03" .       # INC.a RIOT read/write mirror
   "\x60");
write_bin(File::Spec->catfile($in, 'hardware.bin'), $hw);

# Ordinary zero-page suffixes are redundant, but an explicitly wide opcode with
# a low operand must retain its absolute-mode suffix so relaxation cannot change
# the original bytes.
my $mode_relax = make_rom(4096, 0xF000, 0x0100,
   "\x95\x80" .             # STA $80,X (zero page,X)
   "\x9D\x80\x00" .       # STA.ax $0080,X (absolute,X)
   "\xA5\x80" .             # LDA $80 (zero page)
   "\xAD\x80\x00" .       # LDA.a $0080 (absolute)
   "\x60");
write_bin(File::Spec->catfile($in, 'mode_relaxation.bin'), $mode_relax);

# Speculative island discovery: three consecutive candidate starts that decode
# directly as CPU-locking opcodes form a sequential-flow barrier.  The first
# nontrivial safe routine immediately after that barrier should be promoted as
# lower-confidence unreachable code even though normal vectors never reference it.
my $island = make_rom(4096, 0xF000, 0x0100, "\x60");
substr($island, 0x0200, 12,
   "\x02\x12\x22" .
   "\xA9\x42\xAA\xA8\xE8\xCA\xC8\x88\x60");
write_bin(File::Spec->catfile($in, 'speculative_island.bin'), $island);

# A speculative candidate must be rejected when a statically possible path
# reaches JAM/KIL.  CLC makes the BCC-to-KIL path definitely taken.
my $island_jam = make_rom(4096, 0xF000, 0x0100, "\x60");
substr($island_jam, 0x0200, 16,
   "\x02\x12\x22" .             # barrier
   "\x18\x90\x03\xA9\x01\x60\x02" . # CLC/BCC -> KIL
   ("\x02" x 6));
write_bin(File::Spec->catfile($in, 'speculative_jam_reject.bin'), $island_jam);

# Conversely, abstract flag state may prove the JAM arm impossible.  SEC makes
# BCC not taken, so this otherwise identical candidate is a valid island.
my $island_dead_jam = make_rom(4096, 0xF000, 0x0100, "\x60");
substr($island_dead_jam, 0x0200, 10,
   "\x02\x12\x22" .             # barrier
   "\x38\x90\x03\xA9\x01\x60\x02"); # SEC/BCC(dead KIL)
write_bin(File::Spec->catfile($in, 'speculative_dead_jam.bin'), $island_dead_jam);

# N/Z abstract state also prunes impossible halt arms.  LDA #0 makes BNE false.
my $island_dead_zero_jam = make_rom(4096, 0xF000, 0x0100, "\x60");
substr($island_dead_zero_jam, 0x0200, 11,
   "\x02\x12\x22" .
   "\xA9\x00\xD0\x03\xA2\x07\x60\x02");
write_bin(File::Spec->catfile($in, 'speculative_dead_zero_jam.bin'), $island_dead_zero_jam);

# A real control-flow target on the far side of a rejected-start barrier remains
# authoritative; the barrier only blocks ordinary speculative fallthrough.
my $barrier_jump = make_rom(4096, 0xF000, 0x0100,
   "\x20\x05\xF2\x60");
substr($barrier_jump, 0x0200, 8, "\x02\x12\x22\x02\x02\xA9\x33\x60");
write_bin(File::Spec->catfile($in, 'barrier_explicit_entry.bin'), $barrier_jump);

# An established entry may begin inside a speculative interpretation that is
# rejected.  At F203 the bytes decode as LDA #$4C / KIL; a real JSR enters F204
# instead, where the same bytes decode as JMP $F002.  Negative evidence for the
# outer start must never erase the independently established overlapping entry.
my $barrier_overlap = make_rom(4096, 0xF000, 0x0100,
   "\x20\x04\xF2\x60");
substr($barrier_overlap, 0x0002, 1, "\x60");
substr($barrier_overlap, 0x0200, 7, "\x02\x12\x22\xA9\x4C\x02\xF0");
write_bin(File::Spec->catfile($in, 'barrier_overlap_entry.bin'), $barrier_overlap);

# A JAM/KIL reached through established vector/control flow is intentional code,
# not speculative negative evidence, and must remain decoded as an instruction.
my $reachable_jam = make_rom(4096, 0xF000, 0x0100, "\x02");
write_bin(File::Spec->catfile($in, 'reachable_jam.bin'), $reachable_jam);

# F8SC evidence: F8 selector plus SC write/read windows.
my $sc = make_rom(8192, 0xF000, 0x0100,
   "\x8D\x00\xF0" .       # write SC RAM
   "\xAD\x80\xF0" .       # read SC RAM
   "\xAD\xF8\x1F" .       # F8 hotspot
   "\x60");
write_bin(File::Spec->catfile($in, 'f8sc.bin'), $sc);
my $f6sc = make_rom(16384, 0xF000, 0x0100,
   "\x8D\x00\xF0\xAD\x80\xF0\xAD\xF6\x1F\x60");
write_bin(File::Spec->catfile($in, 'f6sc.bin'), $f6sc);
my $f4sc = make_rom(32768, 0xF000, 0x0100,
   "\x8D\x00\xF0\xAD\x80\xF0\xAD\xF4\x1F\x60");
write_bin(File::Spec->catfile($in, 'f4sc.bin'), $f4sc);

# Maintained frame scheduler signatures used as static video evidence.
my $ntsc = make_rom(4096, 0xF000, 0x0100,
   "\xA9\x2A\x8D\x96\x02" .  # TIM64T := 42
   "\xA9\x22\x8D\x96\x02\x60"); # TIM64T := 34
write_bin(File::Spec->catfile($in, 'video_ntsc.bin'), $ntsc);
my $pal = make_rom(4096, 0xF000, 0x0100,
   "\xA9\x34\x8D\x96\x02" .  # TIM64T := 52
   "\xA9\x29\x8D\x96\x02\x60"); # TIM64T := 41
write_bin(File::Spec->catfile($in, 'video_pal_family.bin'), $pal);

# Conventional counted-WSYNC frames should identify the standard even without
# RIOT timer constants.  Each loop is LDX #count / STA WSYNC / DEX / BNE loop.
sub counted_wsync_phase {
   my ($count) = @_;
   return pack('C*', 0xA2, $count, 0x85, 0x02, 0xCA, 0xD0, 0xFB);
}
my $scan_ntsc = make_rom(4096, 0xF000, 0x0100,
   counted_wsync_phase(3) . counted_wsync_phase(37) .
   counted_wsync_phase(192) . counted_wsync_phase(30) . "\x60");
write_bin(File::Spec->catfile($in, 'video_scanline_ntsc.bin'), $scan_ntsc);
my $scan_pal = make_rom(4096, 0xF000, 0x0100,
   counted_wsync_phase(3) . counted_wsync_phase(45) .
   counted_wsync_phase(228) . counted_wsync_phase(36) . "\x60");
write_bin(File::Spec->catfile($in, 'video_scanline_pal.bin'), $scan_pal);

# Broader commercial-style timing evidence.  Bridge-like code uses timer values
# close to, but not identical to, VCSC's maintained 42/34 pair.
my $ntsc_general = make_rom(4096, 0xF000, 0x0100,
   "\xA9\x2A\x8D\x96\x02" .  # TIM64T := 42
   "\xA9\x23\x8D\x96\x02\x60"); # TIM64T := 35
write_bin(File::Spec->catfile($in, 'video_ntsc_general.bin'), $ntsc_general);

# Stellar-Track-style helper: callers pass distinct timer values in Y.  The
# helper entry itself has a joined/unknown Y state, so inference must retain
# call-site alternatives rather than requiring a single value at the store.
my $param_timer = make_rom(4096, 0xF000, 0x0100,
   "\xA0\xE4\x20\x00\xF2" .  # 228 TIM64T ticks == 192 scanlines
   "\xA0\x23\x20\x00\xF2" .  # 35
   "\xA0\x30\x20\x00\xF2\x60"); # 48
substr($param_timer, 0x0200, 11,
   "\xAD\x84\x02\xD0\xFB\x84\x02\x8C\x96\x02\x60");
write_bin(File::Spec->catfile($in, 'video_param_timer_ntsc.bin'), $param_timer);

# Counted kernels need not use exactly 192/228 lines.  Broad visible-plus-blank
# evidence should still distinguish conventional 60 Hz and 50 Hz layouts.
my $scan_ntsc_general = make_rom(4096, 0xF000, 0x0100,
   counted_wsync_phase(190) . counted_wsync_phase(35) . "\x60");
write_bin(File::Spec->catfile($in, 'video_scanline_ntsc_general.bin'),
   $scan_ntsc_general);
my $scan_pal_general = make_rom(4096, 0xF000, 0x0100,
   counted_wsync_phase(230) . counted_wsync_phase(48) . "\x60");
write_bin(File::Spec->catfile($in, 'video_scanline_pal_general.bin'),
   $scan_pal_general);

# Filename region tags are useful secondary evidence when timing analysis is
# inconclusive.  Token boundaries prevent titles containing "pal" from matching.
write_bin(File::Spec->catfile($in, 'mystery (PAL).bin'),
   make_rom(4096, 0xF000, 0x0100, "\x60"));

# Controller-pattern fixtures use the same hardware idioms as the VCSC
# libraries, but do not depend on high-level compiler output.
my $keypad = make_rom(4096, 0xF000, 0x0100,
   "\x8D\x80\x02" .   # STA SWCHA (drive rows)
   "\x24\x38" .         # BIT INPT0
   "\x24\x39" .         # BIT INPT1
   "\x24\x3C\x60");  # BIT INPT4
write_bin(File::Spec->catfile($in, 'controller_keypad_left.bin'), $keypad);

my $paddles = make_rom(4096, 0xF000, 0x0100,
   "\x85\x01" .         # STA VBLANK
   "\x24\x38" .         # BIT INPT0
   "\x24\x39\x60");  # BIT INPT1
write_bin(File::Spec->catfile($in, 'controller_paddles_left.bin'), $paddles);

my $driving = make_rom(4096, 0xF000, 0x0100,
   "\xAD\x80\x02" .                       # LDA SWCHA
   "\x4A\x4A\x4A\x4A\x29\x03" .     # left phase
   "\xA5\x3C\x60");                      # LDA INPT4
write_bin(File::Spec->catfile($in, 'controller_driving_left.bin'), $driving);

my $joystick = make_rom(4096, 0xF000, 0x0100,
   "\xAD\x80\x02\x29\xF0" .             # LDA SWCHA / AND left nibble
   "\xA5\x3C\x60");                      # fire via INPT4
write_bin(File::Spec->catfile($in, 'controller_joystick_left.bin'), $joystick);
my $joystick_dir_only = make_rom(4096, 0xF000, 0x0100,
   "\xAD\x80\x02\x29\x40\x60"); # SWCHA / AND left-direction bit
write_bin(File::Spec->catfile($in, 'controller_joystick_direction_only.bin'),
   $joystick_dir_only);

my $keypad_right = make_rom(4096, 0xF000, 0x0100,
   "\x8D\x80\x02" .   # STA SWCHA (drive rows)
   "\x24\x3A" .         # BIT INPT2
   "\x24\x3B" .         # BIT INPT3
   "\x24\x3D\x60");  # BIT INPT5
write_bin(File::Spec->catfile($in, 'controller_keypad_right.bin'), $keypad_right);

my $paddles_right = make_rom(4096, 0xF000, 0x0100,
   "\x85\x01" .         # STA VBLANK
   "\x24\x3A" .         # BIT INPT2
   "\x24\x3B\x60");  # BIT INPT3
write_bin(File::Spec->catfile($in, 'controller_paddles_right.bin'), $paddles_right);

my $driving_right = make_rom(4096, 0xF000, 0x0100,
   "\xAD\x80\x02" .       # LDA SWCHA
   "\x29\x03" .             # right phase
   "\xA5\x3D\x60");      # LDA INPT5
write_bin(File::Spec->catfile($in, 'controller_driving_right.bin'), $driving_right);

my $joystick_right = make_rom(4096, 0xF000, 0x0100,
   "\xAD\x80\x02\x29\x0F" . # LDA SWCHA / AND right nibble
   "\xA5\x3D\x60");          # fire via INPT5
write_bin(File::Spec->catfile($in, 'controller_joystick_right.bin'), $joystick_right);

my $mixed = make_rom(4096, 0xF000, 0x0100,
   "\x85\x01" .                         # STA VBLANK for paddles
   "\x24\x38\x24\x39" .             # left INPT0/1
   "\xAD\x80\x02\x29\x0F" .       # right joystick nibble
   "\xA5\x3D\x60");                    # right fire
write_bin(File::Spec->catfile($in, 'controller_mixed.bin'), $mixed);

run_ok($^X, $roundtrip, $in, $out);

# A zero-instruction result is not a successful disassembly.  Keep this out of
# the bulk round-trip directory because failure is the expected outcome.
my $all_kil = File::Spec->catfile($tmp, 'all_kil.bin');
write_bin($all_kil, "\x02" x 4096);
my $all_kil_out = File::Spec->catfile($tmp, 'all_kil.s26');
unlink($all_kil_out);
my $kil_log = File::Spec->catfile($tmp, 'all_kil.log');
my $kil_cmd = qq{"$disas" -o "$all_kil_out" "$all_kil" >"$kil_log" 2>&1};
my $kil_rc = system($kil_cmd);
die "all-KIL cartridge unexpectedly disassembled successfully\n" if $kil_rc == 0;
die "zero-instruction failure left an output file\n" if -e $all_kil_out;
my $kil_text = slurp($kil_log);
require_re($kil_text, qr/no instructions found/i, 'zero-instruction hard error');

# Unsupported/raw layouts likewise cannot claim a successful disassembly when
# no instruction map exists.
my $odd_raw = File::Spec->catfile($tmp, 'odd-size.bin');
write_bin($odd_raw, join('', map { chr(($_ * 37 + 11) & 255) } 0 .. 2999));
my $odd_out = File::Spec->catfile($tmp, 'odd-size.s26');
unlink($odd_out);
my $odd_log = File::Spec->catfile($tmp, 'odd-size.log');
my $odd_cmd = qq{"$disas" -o "$odd_out" "$odd_raw" >"$odd_log" 2>&1};
my $odd_rc = system($odd_cmd);
die "unsupported raw cartridge unexpectedly succeeded\n" if $odd_rc == 0;
die "unsupported raw failure left an output file\n" if -e $odd_out;
require_re(slurp($odd_log), qr/no instructions found/i, 'raw-layout zero-instruction error');

my $fa_out = slurp(File::Spec->catfile($out, 'fa.s26'));
require_re($fa_out, qr/^; mapper: FA \(high confidence;/m, 'FA 12K mapper inference');
require_re($fa_out, qr/^; reset\/power-on bank: 2 \(FA hardware default\)$/m,
   'FA startup bank');
require_re($fa_out, qr/^; bank 0: .*origin \$3000/m, 'FA bank 0 origin');
require_re($fa_out, qr/^; bank 1: .*origin \$5000/m, 'FA bank 1 origin');
require_re($fa_out, qr/^; bank 2: .*origin \$7000/m, 'FA bank 2 origin');
require_re($fa_out, qr/^; FA cartridge RAM: write \$1000-\$10FF, read \$1100-\$11FF; bank 2 powers up$/m,
   'FA RAM mapping annotation');
require_re($fa_out, qr/^; usage bytes: .*fa-hidden=1536\b/m,
   'FA hidden RAM-window bytes excluded from ROM analysis');

my $dpc_out = slurp(File::Spec->catfile($out, 'dpc.s26'));
require_re($dpc_out, qr/^; mapper: DPC \(high confidence;/m, 'DPC size mapper inference');
require_re($dpc_out, qr/^; DPC auxiliary data ROM: file \$2000\.\.\$27FF \(2048 bytes\)$/m,
   'DPC auxiliary data layout comment');
require_re($dpc_out, qr/^; DPC RNG table: file \$2800\.\.\$28FE \(255 bytes\)$/m,
   'DPC RNG table layout comment');
require_re($dpc_out, qr/^; ---- DPC auxiliary 2K display\/data ROM ----$/m,
   'DPC auxiliary source section');

my $vector_interior_out = slurp(File::Spec->catfile($out, 'vector_interior.s26'));
require_re($vector_interior_out,
   qr/^L_FFFE:\n\s*\.word\s+L_FFFE\s*\+\s*1\s*; IRQ\/BRK vector$/m,
   'vector target into emitted vector word uses container-relative label');
die "vector interior emitted an unresolved standalone L_FFFF reference\n"
   if $vector_interior_out =~ /\.word\s+L_FFFF\b/;

my $vector_exec_out = slurp(File::Spec->catfile($out, 'vector_exec.s26'));
require_re($vector_exec_out,
   qr/^\s*; NMI vector = \$604A; vector bytes also participate in executable code$/m,
   'executable vector bytes force split vector spelling');
require_re($vector_exec_out,
   qr/^L_FFFA:\n\s*; NMI vector = \$604A; vector bytes also participate in executable code\n\s*LSR\s+A$/m,
   'vector low byte remains executable LSR');
require_re($vector_exec_out, qr/^L_FFFB:\n\s*RTS$/m,
   'vector high byte remains executable RTS entry');
require_re($vector_exec_out, qr/JSR\s+L_FFFB\b/,
   'call to executable vector high byte resolves to emitted label');

my $branches = slurp(File::Spec->catfile($out, 'branches.s26'));
my @same = ($branches =~ /\b(?:BPL|BMI|BVC|BVS|BCC|BCS|BNE|BEQ)\.same\b/g);
my @cross = ($branches =~ /\b(?:BPL|BMI|BVC|BVS|BCC|BCS|BNE|BEQ)\.cross\b/g);
die "expected 8 same-page branches, got " . scalar(@same) . "\n" if @same != 8;
die "expected 8 cross-page branches, got " . scalar(@cross) . "\n" if @cross != 8;
for my $mn (qw(BPL BMI BVC BVS BCC BCS BNE BEQ)) {
   require_re($branches, qr/\b\Q$mn\E\.same\b/, "$mn same-page annotation");
   require_re($branches, qr/\b\Q$mn\E\.cross\b/, "$mn cross-page annotation");
}

my $bits = slurp(File::Spec->catfile($out, 'bit_skip.s26'));
require_re($bits, qr/\.byte\s+\$2C/i, 'BIT-skip raw prefix');
require_re($bits, qr/LDX\s+#\$02/i, 'BIT-skip alternate instruction');
require_re($bits, qr/overlap/i, 'overlap annotation');

my $generic_overlap = slurp(File::Spec->catfile($out, 'generic_overlap.s26'));
require_re($generic_overlap, qr/\.byte\s+\$AD/i, 'generic overlap raw outer opcode');
require_re($generic_overlap, qr/LDA\s+#\$42/i, 'generic overlap inner instruction');
require_re($generic_overlap, qr/overlap/i, 'generic overlap annotation');

my $foreign_origin = slurp(File::Spec->catfile($out, 'origin_d000.s26'));
require_re($foreign_origin, qr/^; bank 0: .* origin \$D000\b/m, 'foreign unbanked origin inference');
my $jmp_origin_out = slurp(File::Spec->catfile($out, 'jmp_origin_f8.s26'));
require_re($jmp_origin_out, qr/^; bank 0: .* origin \$D000\b/m,
   'bank 0 JMP-only origin inference');
require_re($jmp_origin_out, qr/^; bank 1: .* origin \$F000\b/m,
   'bank 1 origin inference with RESET path');

my $code_data = slurp(File::Spec->catfile($out, 'code_as_data.s26'));
require_re($code_data, qr/instruction byte\/operand also read as data/i, 'code-as-data annotation');
require_re($code_data, qr/LDA\s+L_F100\s*\+\s*1\b/, 'code-as-data interior alias');

my $known_indirect = slurp(File::Spec->catfile($out, 'known_indirect_data.s26'));
require_re($known_indirect,
   qr/^; usage bytes: .*data-read=[1-9]\d* .*possible=0 .*unreferenced=[1-9]\d*$/m,
   'resolved indirect-read usage accounting');
require_re($known_indirect, qr/unreferenced ROM bytes/i,
   'provably unreferenced ROM annotation');

my $sprite_out = slurp(File::Spec->catfile($out, 'sprite_rows.s26'));
my @sprite_rows = ($sprite_out =~ /^\s*\.byte\s+%[01]{8}\s+;\s+[.X]{8}\s*$/mg);
die "expected 8 visual sprite rows, got " . scalar(@sprite_rows) . "\n"
   if @sprite_rows != 8;
require_re($sprite_out, qr/\.byte\s+%00111100\s+;\s+\.\.XXXX\.\./,
   'sprite binary plus visual row');
my $not_sprite_out = slurp(File::Spec->catfile($out, 'not_sprite.s26'));
die "non-graphics table was rendered as sprite rows\n"
   if $not_sprite_out =~ /^\s*\.byte\s+%[01]{8}\s+;/m;
my $graphics_mask_out = slurp(File::Spec->catfile($out, 'graphics_mask.s26'));
my @mask_rows = ($graphics_mask_out =~ /^\s*\.byte\s+%[01]{8}\s+;\s+[.X]{8}\s*$/mg);
die "expected 8 transformed playfield rows, got " . scalar(@mask_rows) . "\n"
   if @mask_rows != 8;
require_re($graphics_mask_out, qr/\.byte\s+%11110000\s+;\s+XXXX\.\.\.\./,
   'ALU-transformed PF graphics provenance');

my $graphics_stx_out = slurp(File::Spec->catfile($out, 'graphics_stx.s26'));
my @stx_rows = ($graphics_stx_out =~ /^\s*\.byte\s+%[01]{8}\s+;\s+[.X]{8}\s*$/mg);
die "expected 8 STX-fed graphics rows, got " . scalar(@stx_rows) . "\n"
   if @stx_rows != 8;
require_re($graphics_stx_out, qr/\.byte\s+%11111111\s+;\s+XXXXXXXX/,
   'X-register graphics provenance');

my $graphics_transfer_out = slurp(File::Spec->catfile($out, 'graphics_transfer.s26'));
my @transfer_rows = ($graphics_transfer_out =~ /^\s*\.byte\s+%[01]{8}\s+;\s+[.X]{8}\s*$/mg);
die "expected 8 transferred graphics rows, got " . scalar(@transfer_rows) . "\n"
   if @transfer_rows != 8;
require_re($graphics_transfer_out, qr/\.byte\s+%10000001\s+;\s+X\.\.\.\.\.\.X/,
   'register-transfer graphics provenance');

my $graphics_sty_out = slurp(File::Spec->catfile($out, 'graphics_sty.s26'));
my @sty_rows = ($graphics_sty_out =~ /^\s*\.byte\s+%[01]{8}\s+;\s+[.X]{8}\s*$/mg);
die "expected 8 STY-fed graphics rows, got " . scalar(@sty_rows) . "\n"
   if @sty_rows != 8;
require_re($graphics_sty_out, qr/\.byte\s+%01111110\s+;\s+\.XXXXXX\./,
   'Y-register graphics provenance');

my $font_out = slurp(File::Spec->catfile($out, 'font_rows.s26'));
my @font_visual = ($font_out =~ /^\s*\.byte\s+%[01]{8}\s+;\s+[.X]{8}\s*$/mg);
die "expected 16 visual font rows, got " . scalar(@font_visual) . "\n"
   if @font_visual != 16;
require_re($font_out, qr/\.byte\s+%00111100\s+;\s+\.\.XXXX\.\./,
   'runtime-indexed font-table rendering');

for my $non_graphics_name ('random_table.s26', 'compressed_table.s26') {
   my $text = slurp(File::Spec->catfile($out, $non_graphics_name));
   die "$non_graphics_name was overclassified as graphics\n"
      if $text =~ /^\s*\.byte\s+%[01]{8}\s+;/m;
}
my $dynamic_exit_out = slurp(File::Spec->catfile($out, 'dynamic_exit.s26'));
require_re($dynamic_exit_out, qr/JMP\.a\s+\$0080.*control transfer leaves statically decoded cartridge ROM/i,
   'dynamic control exit annotation');

my $hardware = slurp(File::Spec->catfile($out, 'hardware.s26'));
require_re($hardware, qr/STA\s+COLUBK\b/, 'canonical TIA symbol without redundant zero-page suffix');
die "canonical zero-page TIA access retained redundant .z suffix\n"
   if $hardware =~ /STA\.z\s+COLUBK\b/;
require_re($hardware, qr/COLUBK\s*\+\s*\$0100.*mirror of COLUBK/i, 'TIA mirror comment');
require_re($hardware, qr/INPT4\s*\+\s*\$0300.*mirror of INPT4/i, 'TIA read mirror comment');
require_re($hardware, qr/SWCHA\s*\+\s*\$0100.*mirror of SWCHA/i, 'RIOT read mirror comment');
require_re($hardware, qr/TIM64T\s*\+\s*\$0100.*mirror of TIM64T/i, 'RIOT write mirror comment');
require_re($hardware, qr/TIA read-modify-write: reads CXM0P .*mirrored operand \$0130/i,
   'TIA RMW mirror annotation');
require_re($hardware, qr/RIOT read-modify-write: reads SWCHA .*writes SWCHA .*mirrored operand \$0380/i,
   'RIOT RMW mirror annotation');

my $mode_relax_out = slurp(File::Spec->catfile($out, 'mode_relaxation.s26'));
require_re($mode_relax_out, qr/STA\s+\$80,X\b/,
   'redundant zero-page-X suffix omitted');
die "zero-page-X instruction retained redundant .zx suffix\n"
   if $mode_relax_out =~ /STA\.zx\s+\$80,X\b/;
require_re($mode_relax_out, qr/STA\.ax\s+\$0080,X\b/,
   'low absolute-X operand keeps .ax to prevent relaxation');
require_re($mode_relax_out, qr/LDA\s+\$80\b/,
   'redundant zero-page suffix omitted');
die "zero-page instruction retained redundant .z suffix\n"
   if $mode_relax_out =~ /LDA\.z\s+\$80\b/;
require_re($mode_relax_out, qr/LDA\.a\s+\$0080\b/,
   'low absolute operand keeps .a to prevent relaxation');

my $spec_island = slurp(File::Spec->catfile($out, 'speculative_island.s26'));
require_re($spec_island,
   qr/speculative instruction island validated by HLT\/JAM\/KIL rejection/i,
   'speculative island annotation');
require_re($spec_island, qr/^L_F203:\n\s*LDA\s+#\$42\n\s*TAX\n\s*TAY\n\s*INX\n\s*DEX\n\s*INY\n\s*DEY\n\s*RTS$/m,
   'credible safe routine after three-start barrier promoted');
require_re($spec_island,
   qr/^; speculative analysis: rejected-starts=[1-9]\d* barriers=[1-9]\d* islands=[1-9]\d*$/m,
   'speculative analysis usage summary');

my $spec_jam = slurp(File::Spec->catfile($out, 'speculative_jam_reject.s26'));
die "JAM-reaching speculative candidate was promoted\n"
   if $spec_jam =~ /^L_F203:/m ||
      $spec_jam =~ /speculative instruction island.*\nL_F203:/i;

my $spec_dead_jam = slurp(File::Spec->catfile($out, 'speculative_dead_jam.s26'));
require_re($spec_dead_jam, qr/^L_F203:\n\s*SEC\n\s*BCC\.same\s+/m,
   'abstract carry fact keeps impossible JAM arm from rejecting island');

my $spec_dead_zero = slurp(File::Spec->catfile($out, 'speculative_dead_zero_jam.s26'));
require_re($spec_dead_zero, qr/^L_F203:\n\s*LDA\s+#\$00\n\s*BNE\.same\s+/m,
   'known zero flag keeps impossible BNE-to-JAM arm from rejecting island');

my $barrier_jump_out = slurp(File::Spec->catfile($out, 'barrier_explicit_entry.s26'));
require_re($barrier_jump_out, qr/JSR\s+L_F205\b/,
   'explicit control transfer crosses speculative barrier');
require_re($barrier_jump_out, qr/^L_F205:\n\s*LDA\s+#\$33\n\s*RTS$/m,
   'established entry beyond barrier remains code');

my $barrier_overlap_out = slurp(File::Spec->catfile($out, 'barrier_overlap_entry.s26'));
require_re($barrier_overlap_out, qr/JSR\s+L_F204\b/,
   'explicit inner entry into rejected speculative interpretation');
require_re($barrier_overlap_out, qr/^L_F204:\n\s*JMP\s+L_F002\b/m,
   'established overlapping inner JMP survives negative evidence');
die "rejected outer speculative entry F203 was incorrectly promoted\n"
   if $barrier_overlap_out =~ /^L_F203:/m;

my $reachable_jam_out = slurp(File::Spec->catfile($out, 'reachable_jam.s26'));
require_re($reachable_jam_out, qr/^L_F100:\n\s*op02\b/im,
   'established reachable JAM remains executable code');

my $f8_read_only = slurp(File::Spec->catfile($out, 'f8_sc_read_only.s26'));
require_re($f8_read_only, qr/^; mapper: F8 \(/m,
   'plain F8 read in Superchip read window stays F8');
die "read-only Superchip-window access hid ordinary F8 ROM bytes\n"
   if $f8_read_only =~ /sc-hidden=[1-9]/ ||
      $f8_read_only =~ /hidden by Superchip RAM window/i;

my $f8sc = slurp(File::Spec->catfile($out, 'f8sc.s26'));
require_re($f8sc, qr/^; mapper: F8SC\b/m, 'F8SC mapper inference');
require_re($f8sc, qr/physical ROM bytes hidden by Superchip RAM window/i,
   'Superchip-hidden physical ROM annotation');
require_re($f8sc, qr/^; usage bytes: .*sc-hidden=512\b/m,
   'F8SC hidden-byte accounting');
my $f6sc_out = slurp(File::Spec->catfile($out, 'f6sc.s26'));
require_re($f6sc_out, qr/^; mapper: F6SC\b/m, 'F6SC mapper inference');
my $f4sc_out = slurp(File::Spec->catfile($out, 'f4sc.s26'));
require_re($f4sc_out, qr/^; mapper: F4SC\b/m, 'F4SC mapper inference');


my $video_ntsc = slurp(File::Spec->catfile($out, 'video_ntsc.s26'));
require_re($video_ntsc, qr/^; video: NTSC .*\(high confidence\)$/m, 'NTSC inference');
my $video_pal = slurp(File::Spec->catfile($out, 'video_pal_family.s26'));
require_re($video_pal, qr/^; video: PAL-family \(PAL\/SECAM ambiguous; .*\) \(high confidence\)$/m,
   'PAL-family inference');
my $video_scan_ntsc = slurp(File::Spec->catfile($out, 'video_scanline_ntsc.s26'));
require_re($video_scan_ntsc, qr/^; video: NTSC \(counted WSYNC frame signature\) \(high confidence\)$/m,
   'counted-WSYNC NTSC inference');
my $video_scan_pal = slurp(File::Spec->catfile($out, 'video_scanline_pal.s26'));
require_re($video_scan_pal, qr/^; video: PAL-family \(PAL\/SECAM ambiguous; counted WSYNC frame signature\) \(high confidence\)$/m,
   'counted-WSYNC PAL-family inference');
my $video_ntsc_general = slurp(File::Spec->catfile($out, 'video_ntsc_general.s26'));
require_re($video_ntsc_general, qr/^; video: NTSC .*\(medium confidence\)$/m,
   'general TIM64T NTSC inference');
my $video_param_ntsc = slurp(File::Spec->catfile($out, 'video_param_timer_ntsc.s26'));
require_re($video_param_ntsc,
   qr/^; video: NTSC \(general frame-timing evidence\) \(high confidence\)$/m,
   'parameterized timer-helper NTSC inference');
my $video_scan_ntsc_general = slurp(File::Spec->catfile($out, 'video_scanline_ntsc_general.s26'));
require_re($video_scan_ntsc_general,
   qr/^; video: NTSC \(general frame-timing evidence\) \(high confidence\)$/m,
   'broad counted-WSYNC NTSC inference');
my $video_scan_pal_general = slurp(File::Spec->catfile($out, 'video_scanline_pal_general.s26'));
require_re($video_scan_pal_general,
   qr/^; video: PAL-family \(PAL\/SECAM ambiguous; general frame-timing evidence\) \(high confidence\)$/m,
   'broad counted-WSYNC PAL-family inference');
my $video_filename_pal = slurp(File::Spec->catfile($out, 'mystery (PAL).s26'));
require_re($video_filename_pal,
   qr/^; video: PAL \(filename hint\) \(medium confidence\)$/m,
   'PAL filename hint');

my $keypad_out = slurp(File::Spec->catfile($out, 'controller_keypad_left.s26'));
require_re($keypad_out, qr/^; controller port 0: keypad \(high confidence\)$/m,
   'left keypad inference');
my $paddles_out = slurp(File::Spec->catfile($out, 'controller_paddles_left.s26'));
require_re($paddles_out, qr/^; controller port 0: paddles \(high confidence\)$/m,
   'left paddle inference');
my $driving_out = slurp(File::Spec->catfile($out, 'controller_driving_left.s26'));
require_re($driving_out, qr/^; controller port 0: driving controller \(high confidence\)$/m,
   'left driving inference');
my $joystick_dir_only_out = slurp(File::Spec->catfile($out, 'controller_joystick_direction_only.s26'));
require_re($joystick_dir_only_out, qr/^; controller port 0: joystick \(medium confidence\)$/m,
   'single-direction SWCHA mask infers joystick without fire-button access');

my $joystick_out = slurp(File::Spec->catfile($out, 'controller_joystick_left.s26'));
require_re($joystick_out, qr/^; controller port 0: joystick \(medium confidence\)$/m,
   'left joystick inference');
require_re($joystick_out, qr/^; controller port 1: unused or unknown \(low confidence\)$/m,
   'left joystick does not contaminate right port');

my $keypad_right_out = slurp(File::Spec->catfile($out, 'controller_keypad_right.s26'));
require_re($keypad_right_out, qr/^; controller port 1: keypad \(high confidence\)$/m,
   'right keypad inference');
my $paddles_right_out = slurp(File::Spec->catfile($out, 'controller_paddles_right.s26'));
require_re($paddles_right_out, qr/^; controller port 1: paddles \(high confidence\)$/m,
   'right paddle inference');
my $driving_right_out = slurp(File::Spec->catfile($out, 'controller_driving_right.s26'));
require_re($driving_right_out, qr/^; controller port 1: driving controller \(high confidence\)$/m,
   'right driving inference');
my $joystick_right_out = slurp(File::Spec->catfile($out, 'controller_joystick_right.s26'));
require_re($joystick_right_out, qr/^; controller port 1: joystick \(medium confidence\)$/m,
   'right joystick inference');
require_re($joystick_right_out, qr/^; controller port 0: unused or unknown \(low confidence\)$/m,
   'right joystick does not contaminate left port');
my $mixed_out = slurp(File::Spec->catfile($out, 'controller_mixed.s26'));
require_re($mixed_out, qr/^; controller port 0: paddles \(high confidence\)$/m,
   'mixed left paddles inference');
require_re($mixed_out, qr/^; controller port 1: joystick \(medium confidence\)$/m,
   'mixed right joystick inference');

# Determinism: disassembling the same ROM twice must produce identical source.
my $det1 = File::Spec->catfile($tmp, 'det1.s26');
my $det2 = File::Spec->catfile($tmp, 'det2.s26');
run_ok($disas, '-o', $det1, File::Spec->catfile($in, 'hardware.bin'));
run_ok($disas, '-o', $det2, File::Spec->catfile($in, 'hardware.bin'));
die "nondeterministic output\n" if slurp($det1) ne slurp($det2);

# CLI contract and empty-input rejection.
my $help = `$disas --help 2>&1`;
die "--help failed\n" if $? != 0;
require_re($help, qr/^usage:/m, 'help usage');
require_re($help, qr/--version/, 'help version option');
require_re($help, qr/--mapper/, 'help mapper override');
require_re($help, qr/--origin/, 'help origin override');
require_re($help, qr/--entry/, 'help entry hint');
require_re($help, qr/--code/, 'help code hint');
require_re($help, qr/--data/, 'help data hint');
require_re($help, qr/--controller0/, 'help controller override');
require_re($help, qr/--verbose/, 'help verbose evidence mode');
my $version = `$disas --version 2>&1`;
die "--version failed\n" if $? != 0;
require_re($version, qr/\d{4}-\d{2}-\d{2}/, 'generated version string');
my $bad = `$disas --definitely-not-an-option 2>&1`;
die "bad option unexpectedly succeeded\n" if $? == 0;
require_re($bad, qr/Try '.*--help' for a list of supported options\./, 'bad-option help guidance');
# Manual inference hints/overrides are independent of byte representation.
# Force a deliberately different logical origin, mark an instruction operand as
# data as well as code, and override advisory metadata.  The generated source
# must still assemble successfully.
my $hint_s26 = File::Spec->catfile($tmp, 'hint.s26');
my $hint_hex = File::Spec->catfile($tmp, 'hint.hex');
run_ok($disas,
   '--mapper', '4k',
   '--origin', '0:0xD000',
   '--reset-bank', '0',
   '--entry', '0:0xD100',
   '--code', '0:0xD100-0xD102',
   '--data', '0:0xD101-0xD101',
   '--video', 'secam',
   '--controller0', 'joystick',
   '--controller1', 'unused',
   '--verbose',
   '-o', $hint_s26, File::Spec->catfile($in, 'plain4k.bin'));
my $hint_text = slurp($hint_s26);
require_re($hint_text, qr/^; mapper: unbanked 4K \(override;/m,
   'mapper override annotation');
require_re($hint_text, qr/^; bank 0: .* origin \$D000, override$/m,
   'origin override annotation');
require_re($hint_text, qr/^; reset\/power-on bank: 0 \(override\)$/m,
   'reset bank override annotation');
require_re($hint_text, qr/^; video: SECAM \(override\)$/m,
   'video override annotation');
require_re($hint_text, qr/^; controller port 0: joystick \(override\)$/m,
   'controller override annotation');
require_re($hint_text, qr/^; evidence: SWCHA /m,
   'verbose evidence output');
require_re($hint_text, qr/^L_D100:$/m, 'forced entry/code label');
require_re($hint_text, qr/LDA\s+#\$42.*instruction byte\/operand also read as data/i,
   'non-exclusive forced code/data roles');
run_ok($as, "--hex=$hint_hex", $hint_s26);

# Explicit mapper overrides must control Superchip semantics, not merely the
# mapper name printed in the header.  Forcing F8SC on an ordinary 8K image
# hides the physical low $100 bytes of both banks; forcing plain F8 on a ROM
# that contains SC-style accesses must suppress that interpretation.
my $forced_sc_s26 = File::Spec->catfile($tmp, 'forced_f8sc.s26');
run_ok($disas, '--mapper', 'f8sc', '-o', $forced_sc_s26,
   File::Spec->catfile($in, 'f8.bin'));
my $forced_sc = slurp($forced_sc_s26);
require_re($forced_sc, qr/^; mapper: F8SC \(override;/m,
   'forced F8SC mapper annotation');
require_re($forced_sc, qr/^; usage bytes: .*sc-hidden=512\b/m,
   'forced F8SC applies hidden-window semantics');

my $forced_plain_s26 = File::Spec->catfile($tmp, 'forced_f8.s26');
run_ok($disas, '--mapper', 'f8', '-o', $forced_plain_s26,
   File::Spec->catfile($in, 'f8sc.bin'));
my $forced_plain = slurp($forced_plain_s26);
require_re($forced_plain, qr/^; mapper: F8 \(override;/m,
   'forced plain F8 mapper annotation');
die "forced plain F8 still applied Superchip hidden-window semantics\n"
   if $forced_plain =~ /sc-hidden=[1-9]/ ||
      $forced_plain =~ /hidden by Superchip RAM window/i;

my $bad_mapper = `$disas --mapper f8 "@{[File::Spec->catfile($in, 'plain4k.bin')]}" 2>&1`;
die "incompatible mapper override unexpectedly succeeded\n" if $? == 0;
require_re($bad_mapper, qr/incompatible with 4096-byte input/, 'mapper-size contradiction');
my $bad_origin = `$disas --origin 0:0xD001 "@{[File::Spec->catfile($in, 'plain4k.bin')]}" 2>&1`;
die "misaligned origin override unexpectedly succeeded\n" if $? == 0;
require_re($bad_origin, qr/not a valid page-aligned cartridge origin/, 'origin alignment diagnostic');

my $empty = File::Spec->catfile($tmp, 'empty.bin');
write_bin($empty, '');
my $empty_out = File::Spec->catfile($tmp, 'empty.s26');
system($disas, '-o', $empty_out, $empty);
die "empty input unexpectedly succeeded\n" if $? == 0;

print "vcsc-disas regression suite ok\n";
