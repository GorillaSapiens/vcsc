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
write_bin(File::Spec->catfile($in, 'origin_d000.bin'), make_rom(4096, 0xD000, 0x0234, "\xA9\x17\x60"));
write_bin(File::Spec->catfile($in, 'f8.bin'), make_rom(8192, 0xF000, 0x0100, "\xAD\xF8\x1F\x60"));
# A plain F8 ROM may legitimately read ordinary ROM in $F080-$F0FF.
# Read-window-looking evidence alone must not promote it to Superchip.
write_bin(File::Spec->catfile($in, 'f8_sc_read_only.bin'),
   make_rom(8192, 0xF000, 0x0100, "\xAD\x80\xF0\xAD\xF8\x1F\x60"));
write_bin(File::Spec->catfile($in, 'f6.bin'), make_rom(16384, 0xF000, 0x0100, "\xAD\xF6\x1F\x60"));
write_bin(File::Spec->catfile($in, 'f4.bin'), make_rom(32768, 0xF000, 0x0100, "\xAD\xF4\x1F\x60"));

# Bank origins can be inferred from absolute JMP evidence even when vectors are
# deliberately unusable.  Each physical F8 bank carries a different origin.
my $jmp_origins = chr(0xEA) x 8192;
substr($jmp_origins, 0x0100, 3, pack('C v', 0x4C, 0xD234));
substr($jmp_origins, 0x1000 + 0x0100, 3, pack('C v', 0x4C, 0xF456));
for my $base (0, 0x1000) {
   put16(\$jmp_origins, $base + 0xFFA, 0x0000);
   put16(\$jmp_origins, $base + 0xFFC, 0x0000);
   put16(\$jmp_origins, $base + 0xFFE, 0x0000);
}
write_bin(File::Spec->catfile($in, 'jmp_origin_f8.bin'), $jmp_origins);

# Unsupported size must still round-trip as raw bytes.
write_bin(File::Spec->catfile($in, 'odd size.bin'), join('', map { chr(($_ * 37 + 11) & 255) } 0 .. 2999));

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

my $vector_interior_out = slurp(File::Spec->catfile($out, 'vector_interior.s26'));
require_re($vector_interior_out,
   qr/^L_FFFE:\n\s*\.word\s+L_FFFE\s*\+\s*1\s*; IRQ\/BRK vector$/m,
   'vector target into emitted vector word uses container-relative label');
die "vector interior emitted an unresolved standalone L_FFFF reference\n"
   if $vector_interior_out =~ /\.word\s+L_FFFF\b/;

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
   'bank 1 JMP-only origin inference');

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

my $odd = slurp(File::Spec->catfile($out, 'odd size.s26'));
require_re($odd, qr/^; mapper: (?:unknown\/raw|raw)\b/m, 'raw mapper fallback');

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
