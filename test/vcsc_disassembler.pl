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
      # Ordinary synthetic banked fixtures must not accidentally carry the
      # F8SC/F6SC/F4SC duplicated-hidden-window structural signature merely
      # because make_rom fills otherwise-unused bytes with NOP.
      if ($size > 4096 && $bank_size == 4096 &&
          !($b == 0 && $code_off <= 0x80 &&
            $code_off + length($code) > 0x80)) {
         substr($rom, $base + 0x80, 1, "\x18");
      }
   }
   return $rom;
}

sub make_ar_load {
   my ($start, $control, $load_id, $bank_byte, $page) = @_;
   length($page) == 256 or die "AR page must be 256 bytes\n";
   my $data = $page . (chr(0) x (8192 - 256));
   my $header = chr(0) x 256;
   substr($header, 0, 1, chr($start & 0xff));
   substr($header, 1, 1, chr(($start >> 8) & 0xff));
   substr($header, 2, 1, chr($control & 0xff));
   substr($header, 3, 1, chr(1));
   substr($header, 5, 1, chr($load_id & 0xff));
   my $sum7 = 0;
   $sum7 = ($sum7 + ord(substr($header, $_, 1))) & 0xff for 0 .. 7;
   substr($header, 4, 1, chr((0x55 - $sum7) & 0xff));
   substr($header, 16, 1, chr($bank_byte & 0xff));
   my $psum = 0;
   $psum = ($psum + ord(substr($page, $_, 1))) & 0xff for 0 .. 255;
   substr($header, 64, 1, chr((0x55 - $psum - $bank_byte) & 0xff));
   return $data . $header;
}

sub break_sc_layout {
   my ($sref) = @_;
   my $size = length($$sref);
   return if $size < 8192 || ($size % 4096) != 0;
   for my $b (0 .. int($size / 4096) - 1) {
      substr($$sref, $b * 4096 + 0x80, 1, "\x18");
   }
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

# Plain 1K/2K/4K and ordinary F8/F6/F4 sizes.
# Stella's generic 4K cartridge accepts preservation dumps a couple of bytes
# either side of the canonical size: overlong inputs are truncated for runtime
# mapping and short inputs are zero-filled.  VCSC must use the same logical 4K
# image for analysis while preserving the exact physical file length/bytes.
my $odd4k_base = make_rom(4096, 0xF000, 0x0040, "\xA9\x42\x85\x80\x60");
write_bin(File::Spec->catfile($in, 'odd4k_over.bin'), $odd4k_base . "\x12\x34");
write_bin(File::Spec->catfile($in, 'odd4k_under.bin'), substr($odd4k_base, 0, 4094));

my $plain1k = make_rom(1024, 0xFC00, 0x0040, "\xA9\x42\x60");
# Keep an IRQ/BRK-only routine that RESET cannot reach and never invoke BRK.
# A stock 6507 has no IRQ pin, so the vector must remain vector data and must
# not promote this otherwise-unreachable routine into executable code.
substr($plain1k, 0x0080, 3, "\xA9\x99\x60");
put16(\$plain1k, 0x03FE, 0xFC80);
write_bin(File::Spec->catfile($in, 'plain1k.bin'), $plain1k);

# Concrete RESET discovery torture fixture.  The startup establishes SP=$FF,
# clears the entire mirrored stack/RIOT-RAM page with TSX/PHA, then uses BRK as
# a one-byte subroutine call.  The IRQ handler decrements the mirrored saved-PC
# low byte at $FE before RTI, changing BRK's architectural PC+2 return into
# PC+1.  Static CFG deliberately stops at BRK; concrete execution must recover
# the continuation, copy seven ROM bytes to RIOT RAM $80-$86, and execute the
# generated payload at $0080.
my $concrete_payload = chr(0xEA) x 1024;
substr($concrete_payload, 0x0000, 7,
   "\xA9\x42\x85\x90\x4C\x80\x00"); # RAM payload: LDA #$42; STA $90; JMP $0080
substr($concrete_payload, 0x0040, 3,
   "\xC6\xFE\x40");                   # IRQ: DEC $FE; RTI
substr($concrete_payload, 0x0080, 26,
   "\xD8" .                           # CLD
   "\xA9\x00" .                       # LDA #0
   "\xAA" .                           # TAX
   "\xCA" .                           # DEX -> X=$FF
   "\x9A" .                           # TXS -> SP=$FF
   "\xBA\x48\xD0\xFC" .             # TSX; PHA; BNE back to TSX
   "\xA9\x3B" .                       # LDA #$3B
   "\x00" .                           # BRK; IRQ changes saved return to PC+1
   "\xA2\x07" .                       # concrete-only continuation: LDX #7
   "\xBD\xFF\xFB" .                  # LDA $FBFF,X -> source $FC00-$FC06
   "\x95\x7F" .                       # STA $7F,X -> RIOT RAM $80-$86
   "\xCA\xD0\xF8" .                  # DEX; BNE copy loop
   "\x4C\x80\x00");                  # JMP $0080
put16(\$concrete_payload, 0x03FA, 0xFC40);
put16(\$concrete_payload, 0x03FC, 0xFC80);
put16(\$concrete_payload, 0x03FE, 0xFC40);
write_bin(File::Spec->catfile($in, 'concrete_payload.bin'), $concrete_payload);

# H1 hybrid-analysis fixture.  Neutral SWCHA leaves the loader path untaken,
# while one active-low joystick scenario takes it.  The loader first uses the
# same BRK/IRQ/RTI saved-PC trick as the real 1K removable-cartridge title, then
# copies five ROM bytes into RIOT RAM and jumps to them.  This pins three H1
# promises together: external-input branches remain explorable, a known-SP BRK
# continuation is statically provable, and alternate concrete input discovery
# can recover dynamically executed RAM code with ROM provenance.
my $h1_input_payload = chr(0xEA) x 1024;
substr($h1_input_payload, 0x0000, 5,
   "\xA9\x42\x85\x90\x60");       # RAM payload: LDA #$42; STA $90; RTS
substr($h1_input_payload, 0x0040, 3,
   "\xC6\xFE\x40");                 # IRQ: DEC $FE; RTI
substr($h1_input_payload, 0x0080, 27,
   "\xA2\xFF" .                       # LDX #$FF
   "\x9A" .                           # TXS -> known SP=$FF
   "\x2C\x80\x02" .                 # BIT SWCHA
   "\x10\x03" .                       # BPL loader when joystick bit 7 is low
   "\x4C\x83\xFC" .                 # neutral input: poll forever
   "\xA9\x3B" .                       # loader: LDA #$3B
   "\x00" .                           # BRK; IRQ changes saved PC+2 to PC+1
   "\xA2\x05" .                       # statically proven BRK continuation
   "\xBD\xFF\xFB" .                 # LDA $FBFF,X -> source $FC00-$FC04
   "\x95\x7F" .                       # STA $7F,X -> RIOT RAM $80-$84
   "\xCA\xD0\xF8" .                 # DEX; BNE copy loop
   "\x4C\x80\x00");                 # JMP $0080
put16(\$h1_input_payload, 0x03FA, 0xFC40);
put16(\$h1_input_payload, 0x03FC, 0xFC80);
put16(\$h1_input_payload, 0x03FE, 0xFC40);
write_bin(File::Spec->catfile($in, 'h1_input_payload.bin'), $h1_input_payload);


# Console-switch concrete scenarios.  The maintained COLOR/BW and difficulty
# switches have no universally known startup position, so concrete discovery
# must try all 2^3 combinations with SELECT/RESET released.  In the all-low
# combination this fixture generates one VBLANK assertion per synthetic frame
# and accepts SELECT only if it is released through frames 1-9, pressed through
# frames 10-19, and released again through frames 20-29.  Only a true
# 10-frame/10-frame/10-frame pulse writes RAM $93.  The historical
# 8192/16384-instruction pulse misses the frame-10 window and parks in failure.
my $console_switches = chr(0xEA) x 1024;
substr($console_switches, 0x0080, 108,
   "\xA9\x00\x85\x90\x85\x91" . # frame=0; phase=0
   "\xA9\x02\x85\x01" .         # loop: assert VBLANK
   "\xA9\x00\x85\x01" .         # clear VBLANK
   "\xE6\x90" .                   # ++frame
   "\xAD\x82\x02\x29\xC8" .   # maintained COLOR/BW+difficulty bits
   "\xD0\xEF" .                   # other combinations: next frame
   "\xA5\x90\xC9\x0A\x90\x15" . # frame < 10 -> released check
   "\xC9\x14\x90\x1B" .       # frame < 20 -> pressed check
   "\xC9\x1E\x90\x29" .       # frame < 30 -> released-again check
   "\xA5\x91\xC9\x02\xD0\x3E" . # all three phases observed?
   "\xA9\x5A\x85\x93" .         # reached only after full 10/10/10 pulse
   "\x4C\xE9\xFC" .              # park
   "\xAD\x82\x02\x29\x02\xF0\x29" . # pre10: SELECT must be released
   "\x4C\x86\xFC" .
   "\xAD\x82\x02\x29\x02\xD0\x1F" . # 10..19: SELECT must be pressed
   "\xA5\x91\xD0\xBF" .       # keep phase/failure marker once set
   "\xA9\x01\x85\x91\x4C\x86\xFC" .
   "\xAD\x82\x02\x29\x02\xF0\x0D" . # 20..29: SELECT must be released
   "\xA5\x91\xC9\x01\xD0\xAB" .
   "\xA9\x02\x85\x91\x4C\x86\xFC" .
   "\xA9\xFF\x85\x91\x4C\x86\xFC" . # mark timing failure, keep framing
   "\x4C\xE9\xFC");              # park forever after frame 30
put16(\$console_switches, 0x03FA, 0xFC80);
put16(\$console_switches, 0x03FC, 0xFC80);
put16(\$console_switches, 0x03FE, 0xFC80);
write_bin(File::Spec->catfile($in, 'console_switches.bin'), $console_switches);

# Baseline VBLANK dwell regression.  Static reachability settles during the
# delay loop long before the tenth frame marker.  Concrete discovery must not
# declare the baseline converged once VBLANK use has been observed until ten
# VBLANK assertion edges occur; only then does execution jump into the RAM
# payload.  The old 16384-stale-instruction-only rule stopped several frames
# too early and never reached $00A0.
my $baseline_vblank = chr(0xEA) x 1024;
substr($baseline_vblank, 0x0080, 61,
   "\xA9\xA9\x85\xA0" .           # RAM $A0: LDA #$5A
   "\xA9\x5A\x85\xA1" .
   "\xA9\x85\x85\xA2" .           # RAM $A2: STA $91
   "\xA9\x91\x85\xA3" .
   "\xA9\x4C\x85\xA4" .           # RAM $A4: JMP $00A0
   "\xA9\xA0\x85\xA5" .
   "\xA9\x00\x85\xA6" .
   "\xA9\x00\x85\x90" .           # frame counter
   "\xA0\x08" .                     # frame: LDY #8
   "\xA2\xFF" .                     # outer: LDX #$FF
   "\xCA\xD0\xFD" .                # inner: DEX / BNE inner
   "\x88\xD0\xF8" .                # DEY / BNE outer
   "\xA9\x02\x85\x01" .           # assert VBLANK
   "\xA9\x00\x85\x01" .           # clear VBLANK
   "\xE6\x90\xA5\x90\xC9\x0A" . # ++frame; CMP #10
   "\xD0\xE6" .                     # BNE frame
   "\x4C\xA0\x00");               # JMP $00A0 after tenth assertion
put16(\$baseline_vblank, 0x03FA, 0xFC80);
put16(\$baseline_vblank, 0x03FC, 0xFC80);
put16(\$baseline_vblank, 0x03FE, 0xFC80);
write_bin(File::Spec->catfile($in, 'baseline_vblank.bin'), $baseline_vblank);

# H2 fixed-point fixture.  Concrete RESET execution sees TIA read $00 as zero
# and parks at $FD04.  Static analysis correctly treats the TIA read as unknown
# and explores the BNE-only loader.  That loader makes every abstract CPU flag,
# register, SP, and all 128 RIOT-RAM bytes exact before copying a five-byte ROM
# payload to RAM and jumping to it.  H2 must use that exact static state as a
# concrete continuation seed, execute the RAM payload, then feed any newly
# observed cartridge targets back into static analysis without inventing state.
my $h2_fixed_point = chr(0xEA) x 1024;
substr($h2_fixed_point, 0x0000, 5, "\xA9\x42\x85\x90\x60");
my $h2_code =
   "\xA5\x00" .                     # LDA TIA $00: static unknown, concrete zero
   "\xD0\x0C" .                     # BNE $FD10: static-only loader edge
   "\x4C\x04\xFD";                 # concrete RESET path parks forever
$h2_code .= "\xEA" x (0x10 - length($h2_code));
$h2_code .= "\xA9\x00";
for my $addr (0x80 .. 0xFF) {
   $h2_code .= pack('CC', 0x85, $addr); # make all RIOT RAM exact
}
$h2_code .=
   "\xA2\x7F\x9A" .                 # exact SP
   "\xA2\x11\xA0\x22" .           # exact X/Y
   "\xD8\x18\xB8\xA9\x01";      # exact D/C/V/N/Z and A
for my $i (0 .. 4) {
   $h2_code .= pack('C*', 0xAD, $i, 0xFC, 0x85, 0x80 + $i);
}
$h2_code .= "\x4C\x80\x00";       # enter copied payload
substr($h2_fixed_point, 0x0100, length($h2_code), $h2_code);
put16(\$h2_fixed_point, 0x03FA, 0xFD04);
put16(\$h2_fixed_point, 0x03FC, 0xFD00);
put16(\$h2_fixed_point, 0x03FE, 0xFD04);
write_bin(File::Spec->catfile($in, 'h2_fixed_point.bin'), $h2_fixed_point);
write_bin(File::Spec->catfile($in, 'plain2k.bin'), make_rom(2048, 0xF800, 0x0100, "\xA9\x42\x60"));
write_bin(File::Spec->catfile($in, 'plain4k.bin'), make_rom(4096, 0xF000, 0x0100, "\xA9\x42\x60"));
# A common preservation/dump form stores a mirrored 2K cartridge twice in a
# 4K file.  This is structurally exact, not heuristic: when both 2K halves are
# byte-identical, analyze one logical 2K image but preserve the second physical
# copy verbatim so round trip remains 4096 bytes and byte exact.
my $doubled_2k_half = make_rom(2048, 0xF800, 0x0100, "\xA9\x2A\x60");
write_bin(File::Spec->catfile($in, 'doubled2k.bin'),
          $doubled_2k_half . $doubled_2k_half);
# Stella likewise collapses an 8K image whose two 4K halves are exactly
# identical to one logical 4K cartridge.  Include a UA-looking opcode in the
# logical image so the structural duplicate rule must run before 8K mapper
# heuristics; preserve the duplicate second half verbatim for round trip.
my $doubled_4k_half = make_rom(4096, 0xF000, 0x0100, "\xAD\xC0\x02\x60");
write_bin(File::Spec->catfile($in, 'doubled4k.bin'),
          $doubled_4k_half . $doubled_4k_half);
# Multi-game images are containers, not one bankswitched CPU address space.
# Four distinct, independently rooted 2K components must be split/analyzed
# separately while the outer source preserves the exact concatenation.
my $multicart_4in1 = '';
for my $game (0 .. 3) {
   $multicart_4in1 .= make_rom(2048, 0xF800, 0x0100,
      pack('C*', 0xA9, 0x40 + $game, 0x85, 0x80 + $game, 0x60));
}
write_bin(File::Spec->catfile($in, 'multicart_4in1.bin'), $multicart_4in1);
# Manual analysis hints: a byte sequence that is intentionally a pointer
# table but has no automatic low/high builder, plus a generic data table.
my $manual_hints = make_rom(4096, 0xF000, 0x0100, "\xA9\x42\x60");
substr($manual_hints, 0x0200, 6, pack('v3', 0xF100, 0xF100, 0xF100));
substr($manual_hints, 0x0300, 16, pack('C*', 0 .. 15));
write_bin(File::Spec->catfile($in, 'manual_hints.bin'), $manual_hints);
# Vector targets may legally point into the high byte of another vector.
# $FFFF is especially useful as a sentinel and must not produce an unresolved
# L_FFFF label merely because the high byte lives inside the IRQ .word.
my $vector_interior = make_rom(4096, 0xF000, 0x0100, "\x00"); # reachable BRK promotes IRQ vector
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

# Tigervision 3F maps a value-selected 2K bank at $F000-$F7FF and fixes the
# final physical 2K at $F800-$FFFF.  RESET starts in the fixed bank, explicitly
# selects lower bank 1 twice (also satisfying Stella's STA-$3F detector), jumps
# into it, then selects bank 2.  Bank 1's physical continuation is JAM while
# bank 2 contains the actual next opcode, proving that the selector is a CFG
# edge rather than an execution-line terminator.  Nonuniform filler avoids
# accidentally creating the Superchip duplicated-prefix signature.
my $threef = join('', map { chr(($_ * 73 + 19) & 0xff) } 0 .. 8191);
substr($threef, 1 * 2048 + 0x0100, 5, "\xA9\x02\x85\x3F\x02");
substr($threef, 2 * 2048 + 0x0104, 3, "\xA9\x42\x60");
substr($threef, 3 * 2048 + 0x0100, 11,
   "\xA9\x01\x85\x3F" .
   "\xA9\x01\x85\x3F" .
   "\x4C\x00\xF1");
for my $v (0, 2, 4) {
   put16(\$threef, 3 * 2048 + 0x07FA + $v, 0xF900);
}
write_bin(File::Spec->catfile($in, 'threef.bin'), $threef);


# The fixed final 2K bank can also be selected into 3F's lower window.  A
# relative branch near the end of that lower-window alias can cross into the
# fixed upper window.  Runtime $F7E7 + BPL $38 targets cartridge address $F821;
# the same physical bytes are emitted under bank 3's fixed .rorg at $FFE7, where
# naively recomputing the operand would invent BPL $0021.  That symbolic branch
# is not representable under the one physical-bank presentation and must stay
# raw.  This is distinct from a genuine unbanked 16-bit $FFxx->$00xx branch.
my $threef_alias_branch = join('', map { chr(($_ * 29 + 11) & 0xff) } 0 .. 8191);
substr($threef_alias_branch, 3 * 2048 + 0x0021, 1, "\x60");
substr($threef_alias_branch, 3 * 2048 + 0x0100, 11,
   "\xA9\x03\x85\x3F" .
   "\xA9\x03\x85\x3F" .
   "\x4C\xE7\xF7");
substr($threef_alias_branch, 3 * 2048 + 0x07E7, 3, "\x10\x38\x60");
for my $v (0, 2, 4) {
   put16(\$threef_alias_branch, 3 * 2048 + 0x07FA + $v, 0xF900);
}
write_bin(File::Spec->catfile($in, 'threef_alias_branch.bin'), $threef_alias_branch);

# 3F is not intrinsically an 8K scheme.  Exercise a 32K/16-bank image so the
# CFG state and emitter cannot accidentally bake in four physical 2K banks.
my $threef32 = join('', map { chr(($_ * 41 + 7) & 0xff) } 0 .. 32767);
substr($threef32, 14 * 2048 + 0x0100, 5, "\xA9\x03\x85\x3F\x02");
substr($threef32,  3 * 2048 + 0x0104, 3, "\xA9\x55\x60");
substr($threef32, 15 * 2048 + 0x0100, 11,
   "\xA9\x0E\x85\x3F" .
   "\xA9\x0E\x85\x3F" .
   "\x4C\x00\xF1");
for my $v (0, 2, 4) {
   put16(\$threef32, 15 * 2048 + 0x07FA + $v, 0xF900);
}
write_bin(File::Spec->catfile($in, 'threef32.bin'), $threef32);

# Tigervision 3E extends 3F with an exact $3E RAM-bank selector.  The lower
# 2K window can be switched from ROM to one of 32 external 1K RAM banks; in
# RAM mode $F000-$F3FF reads and $F400-$F7FF writes the same 1K.  Keep the
# selector routine in the fixed final 2K so switching RAM does not make the
# following instruction unknowable, then restore ROM bank 1 and enter it.
my $threee = join('', map { chr(($_ * 59 + 23) & 0xff) } 0 .. 8191);
substr($threee, 1 * 2048 + 0x0100, 3, "\xA9\x42\x60");
substr($threee, 3 * 2048 + 0x0100, 22,
   "\xA9\x02\x85\x3E" .       # select RAM bank 2
   "\xAD\x00\xF0" .            # read RAM alias
   "\x8D\x00\xF4" .            # write same RAM through write alias
   "\xA9\x01\x85\x3F" .       # restore ROM bank 1
   "\xA9\x01\x85\x3F" .       # repeated ROM selector signature
   "\x4C\x00\xF1");
for my $v (0, 2, 4) {
   put16(\$threee, 3 * 2048 + 0x07FA + $v, 0xF900);
}
write_bin(File::Spec->catfile($in, 'threee.bin'), $threee);

# A 3E RAM bank exposes distinct read and write aliases, so an RMW against
# either half cannot be a normal RAM RMW.  Keep the RMW in the fixed final 2K
# after selecting RAM so a forced 3E analysis must record the contradiction.
my $threee_rmw = chr(0xEA) x 8192;
substr($threee_rmw, 3 * 2048 + 0x0100, 17,
   "\xA9\x02\x85\x3E" .       # select RAM bank 2
   "\xEE\x00\xF0" .            # INC read alias: split-RAM contradiction
   "\xA9\x01\x85\x3F" .       # restore ROM bank 1
   "\xA9\x01\x85\x3F" .       # repeated ROM selector signature
   "\x60");
for my $v (0, 2, 4) {
   put16(\$threee_rmw, 3 * 2048 + 0x07FA + $v, 0xF900);
}
write_bin(File::Spec->catfile($in, 'threee_rmw.bin'), $threee_rmw);

# Activision/SCABS FE delays the bank decision by one bus cycle after the
# stack-page $01FE access.  In the released-cart JSR idiom, JSR's low return
# address push hits $01FE and the following target-high byte supplies the bank
# bit.  This Decathlon-shaped sequence switches from bank 0 to bank 1 while the
# target bytes in the old mapping are JAM; RTS must return to bank 0.
my $fe = chr(0xEA) x 8192;
break_sc_layout(\$fe);
substr($fe, 0x0000, 1, "\x02");
substr($fe, 0x1000 + 0x0000, 3, "\xA9\x55\x60");
substr($fe, 0x0100, 11,
   "\xA2\xFF\x9A" .        # LDX #$FF; TXS: next JSR low-return push uses $01FE
   "\x20\x00\xD0" .        # JSR $D000: following target-high byte selects FE bank 1
   "\xC6\xC5" .            # DEC $C5 completes Stella's Decathlon FE signature
   "\xA9\x42\x60");        # caller continuation remains in bank 0
for my $v (0, 2, 4) {
   put16(\$fe, 0x0FFA + $v, 0xF100);
   put16(\$fe, 0x1FFA + $v, 0x0000);
}
write_bin(File::Spec->catfile($in, 'fe_flow.bin'), $fe);

# M-Network E7 maps a selectable lower 2K plus a fixed final 2K, with RAM
# overlays in both regions.  Cover all three released ROM sizes because the
# selector-to-physical-bank mapping differs for 8K, 12K, and 16K carts.
my $e7_8k = join('', map { chr(($_ * 31 + 11) & 0xff) } 0 .. 8191);
substr($e7_8k, 1 * 2048 + 0x0100, 3, "\xA9\x42\x60");
substr($e7_8k, 3 * 2048 + 0x0200, 6,
   "\xAD\xE5\xFF" .          # 8K: $1FE5 selects lower physical bank 1
   "\x4C\x00\xF1");
for my $v (0, 2, 4) {
   put16(\$e7_8k, 3 * 2048 + 0x07FA + $v, 0xFA00);
}
write_bin(File::Spec->catfile($in, 'e7_8k.bin'), $e7_8k);

my $e7_12k = join('', map { chr(($_ * 47 + 29) & 0xff) } 0 .. 12287);
substr($e7_12k, 4 * 2048 + 0x0100, 3, "\xA9\x43\x60");
substr($e7_12k, 5 * 2048 + 0x0200, 9,
   "\xAD\xE2\xFF" .          # 12K quirk: $1FE2 aliases physical bank 0
   "\xAD\xE6\xFF" .          # and $1FE6 selects physical bank 4
   "\x4C\x00\xF1");
for my $v (0, 2, 4) {
   put16(\$e7_12k, 5 * 2048 + 0x07FA + $v, 0xFA00);
}
write_bin(File::Spec->catfile($in, 'e7_12k.bin'), $e7_12k);

my $e7_16k = join('', map { chr(($_ * 53 + 17) & 0xff) } 0 .. 16383);
substr($e7_16k, 5 * 2048 + 0x0100, 3, "\xA9\x44\x60");
substr($e7_16k, 7 * 2048 + 0x0200, 27,
   "\xAD\xE7\xFF" .          # lower window -> 1K RAM
   "\x8D\x00\xF0" .          # lower RAM write alias
   "\xAD\x00\xF4" .          # lower RAM read alias
   "\xAD\xE9\xFF" .          # fixed 256-byte RAM block 1
   "\x8D\x00\xF8" .          # fixed RAM write alias
   "\xAD\x00\xF9" .          # fixed RAM read alias
   "\xAD\xE5\xFF" .          # restore lower ROM physical bank 5
   "\x4C\x00\xF1");
for my $v (0, 2, 4) {
   put16(\$e7_16k, 7 * 2048 + 0x07FA + $v, 0xFA00);
}
write_bin(File::Spec->catfile($in, 'e7_16k.bin'), $e7_16k);

# Both E7 RAM regions are split read/write aliases.  A single-address 6502
# RMW is contradictory in either region; pin both halves in one forced case.
my $e7_rmw = chr(0xEA) x 16384;
substr($e7_rmw, 7 * 2048 + 0x0200, 18,
   "\xAD\xE7\xFF" .          # lower RAM selected
   "\xEE\x00\xF4" .          # INC lower read alias: contradiction
   "\xAD\xE9\xFF" .          # fixed RAM block 1 selected
   "\xEE\x00\xF9" .          # INC fixed read alias: contradiction
   "\xAD\xE5\xFF" .          # restore ROM bank 5
   "\x60");
for my $v (0, 2, 4) {
   put16(\$e7_rmw, 7 * 2048 + 0x07FA + $v, 0xFA00);
}
write_bin(File::Spec->catfile($in, 'e7_rmw.bin'), $e7_rmw);


# Mapper inference must use executable control flow, not raw byte substrings.
# CPX #$2C followed by this BCS happens to contain 2C B0 0F, the historical
# UA BIT-$0FB0 signature, across an instruction boundary.  This is nevertheless
# an F8 cartridge: LDA $1FF9 changes the bank supplying the next opcode.  The
# old-bank next byte is deliberately JAM; bank 1 contains the real continuation.
my $f8_false_ua = chr(0xEA) x 8192;
break_sc_layout(\$f8_false_ua);
substr($f8_false_ua, 0x0100, 10,
   "\xA2\x00" .                 # LDX #0
   "\xE0\x2C" .                 # CPX #$2C
   "\xB0\x0F" .                 # BCS F115; raw bytes include 2C B0 0F
   "\xAD\xF9\x1F" .            # LDA $1FF9: F8 -> bank 1
   "\x02");                      # JAM only if the switch is ignored
substr($f8_false_ua, 0x0115, 1, "\x60");
substr($f8_false_ua, 0x1000 + 0x0109, 9,
   "\xA9\x42\xAA\xA8\xE8\xCA\xC8\x88\x60");
# Only bank 0 has a plausible RESET vector, so competing hypotheses begin from
# the same physical execution path rather than winning on vector-shaped filler.
for my $v (0, 2, 4) {
   put16(\$f8_false_ua, 0x0FFA + $v, 0xF100);
   put16(\$f8_false_ua, 0x1FFA + $v, 0x0000);
}
write_bin(File::Spec->catfile($in, 'f8_false_ua_flow.bin'), $f8_false_ua);

# A raw UA-family byte signature is only candidate evidence.  It must not erase
# a narrower mapper whose established selector actually changes banks.  This
# models an ordinary F8 image with an unreachable LDA $02C0 byte sequence in
# data: both no-switch continuations are locally harmless, so the decision must
# come from F8's real $1FF9 bank-changing edge rather than a JAM escape.
my $f8_raw_ua_data = chr(0xEA) x 8192;
break_sc_layout(\$f8_raw_ua_data);
substr($f8_raw_ua_data, 0x0100, 6,
   "\xAD\xF9\x1F" .            # LDA $1FF9: F8 -> bank 1
   "\xA9\x11\x60");             # harmless no-switch continuation
substr($f8_raw_ua_data, 0x1000 + 0x0103, 3,
   "\xA9\x42\x60");             # actual F8 continuation in bank 1
substr($f8_raw_ua_data, 0x0800, 3, "\xAD\xC0\x02"); # unreachable raw UA signature
for my $v (0, 2, 4) {
   put16(\$f8_raw_ua_data, 0x0FFA + $v, 0xF100);
   put16(\$f8_raw_ua_data, 0x1FFA + $v, 0x0000);
}
write_bin(File::Spec->catfile($in, 'f8_raw_ua_data.bin'), $f8_raw_ua_data);

# Branch-edge state must constrain the tested flag.  This F8 RESET path
# switches into bank 0, reads the unknown RIOT timer, then uses mutually
# exhaustive BMI/BPL tests.  If BMI falls through, N is necessarily clear and
# BPL must be taken; the intervening JAM byte is data and is unreachable.  A
# path-insensitive fork that forgets the first branch condition falsely kills
# the otherwise-correct F8 mapper hypothesis.
my $f8_branch_edge = chr(0xEA) x 8192;
break_sc_layout(\$f8_branch_edge);
substr($f8_branch_edge, 0x1000 + 0x0100, 4,
   "\xAD\xF8\xFF\x02");                    # F8 -> bank0; old-bank JAM
substr($f8_branch_edge, 0x0103, 9,
   "\xAD\x84\x02" .                        # LDA INTIM: N unknown
   "\x30\xFB" .                              # BMI F103
   "\x10\x01" .                              # BPL F10B if BMI fell through
   "\x02" .                                      # impossible fallthrough JAM
   "\x60");                                      # F10B: RTS
for my $v (0, 2, 4) {
   put16(\$f8_branch_edge, 0x0FFA + $v, 0x0000);
   put16(\$f8_branch_edge, 0x1FFA + $v, 0xF100);
}
write_bin(File::Spec->catfile($in, 'f8_branch_edge_flags.bin'), $f8_branch_edge);

# Positive mapper flow must outrank a merely possible JAM caused by incomplete
# abstract data state.  Raw bytes elsewhere make the legacy detector say E0.
# The E0 RESET path never executes an E0 selector and returns immediately.  F8
# instead performs a real bank-1 -> bank-0 selector transition, then branches on
# unknown RAM; one over-approximated branch reaches JAM while the other returns.
# The possible JAM must not erase the demonstrated F8 switching mechanism.
my $f8_cross_vs_possible_jam = chr(0x02) x 8192;
break_sc_layout(\$f8_cross_vs_possible_jam);
substr($f8_cross_vs_possible_jam, 0x0400, 3, "\x8D\xE0\x1F"); # raw E0 signature only
substr($f8_cross_vs_possible_jam, 0x1000 + 0x0100, 4,
   "\xAD\xF8\x1F\x60");                  # F8: switch bank1 -> bank0; E0: RTS
substr($f8_cross_vs_possible_jam, 0x0103, 6,
   "\xA5\x80" .                             # unknown RAM value
   "\xD0\x01" .                             # BNE -> RTS; fallthrough is possible JAM
   "\x02" .                                   # possible, not proven, JAM path
   "\x60");                                   # valid continuation
for my $v (0, 2, 4) {
   put16(\$f8_cross_vs_possible_jam, 0x0FFA + $v, 0x0000);
   put16(\$f8_cross_vs_possible_jam, 0x1FFA + $v, 0xF100);
}
write_bin(File::Spec->catfile($in, 'f8_cross_switch_possible_jam.bin'),
          $f8_cross_vs_possible_jam);

# Concrete execution takes BEQ because RIOT RAM starts at zero.  Static RESET
# analysis does not know that RAM value, so historically it promoted both arms
# and called the never-observed fallthrough JAM established code.  An unknown
# branch arm that was not seen concretely now gets a mapper-aware sanity walk;
# this fallthrough must be rejected without rejecting the branch or cartridge.
my $static_branch_jam = make_rom(4096, 0xF000, 0x0100,
   "\xA5\x80" .                            # LDA $80: abstractly unknown, concretely 0
   "\xF0\x01" .                            # BEQ F105: concrete arm
   "\x02" .                                  # never-observed JAM fallthrough
   "\x60");                                  # F105: RTS
write_bin(File::Spec->catfile($in, 'static_branch_unobserved_jam.bin'),
          $static_branch_jam);

# Same confidence rule through an unconditional jump: the unobserved fall arm
# jumps to JAM rather than containing it directly.  Validation must follow the
# deterministic JMP before deciding the edge is bad.
my $static_branch_jmp_jam = make_rom(4096, 0xF000, 0x0100,
   "\xA5\x80" .                            # LDA $80
   "\xF0\x03" .                            # BEQ F107: concrete arm
   "\x4C\x10\xF1" .                       # unobserved JMP F110
   "\x60");                                  # F107: RTS
substr($static_branch_jmp_jam, 0x0110, 1, "\x02");
write_bin(File::Spec->catfile($in, 'static_branch_unobserved_jmp_jam.bin'),
          $static_branch_jmp_jam);

# Critical mapper caveat: an unobserved branch arm is good even when the byte
# physically following a selector is JAM in the old F8 bank.  The LDA $1FF8
# switches bank 1 -> bank 0; the next opcode at F107 must therefore be fetched
# from bank 0, where it is RTS.  Rejecting the old-bank JAM would be a false
# negative caused by validating bytes instead of mapper-aware execution flow.
my $static_branch_hotspot = chr(0xEA) x 8192;
break_sc_layout(\$static_branch_hotspot);
substr($static_branch_hotspot, 0x1000 + 0x0100, 10,
   "\xA5\x80" .                            # LDA $80: concrete zero
   "\xF0\x05" .                            # BEQ F109: concrete arm
   "\xAD\xF8\x1F" .                       # unobserved arm selects bank 0
   "\x02" .                                  # bank-1 F107 JAM: must never be fetched
   "\xEA" .                                  # F108
   "\x60");                                  # bank-1 F109 concrete RTS
substr($static_branch_hotspot, 0x0107, 1, "\x60"); # bank-0 F107 actual successor
# Stamp VCSC's explicit F8 signature so concrete discovery is trusted for this
# synthetic banked image.  The four-byte signature intentionally occupies the
# otherwise-unused NMI vector bytes at $FFF8-$FFFB; RESET/IRQ remain ordinary.
substr($static_branch_hotspot, 0x1FF8, 4, "F8\0\0");
put16(\$static_branch_hotspot, 0x1FFC, 0xF100);
put16(\$static_branch_hotspot, 0x1FFE, 0xF100);
write_bin(File::Spec->catfile($in, 'static_branch_hotspot_avoids_jam.bin'),
          $static_branch_hotspot);

# UASW can be inferred from execution semantics even without a raw detector
# signature.  Under UASW, reading $0220 selects bank 1; under UA it selects
# bank 0, while the other 8K hypotheses do not make this transition.  The
# physical byte after the selector is JAM only in the losing hypotheses.
my $uasw_flow = chr(0xEA) x 8192;
break_sc_layout(\$uasw_flow);
substr($uasw_flow, 0x0100, 4, "\xAD\x20\x02\x02");
substr($uasw_flow, 0x1000 + 0x0103, 1, "\x60");
for my $v (0, 2, 4) {
   put16(\$uasw_flow, 0x0FFA + $v, 0xF100);
   put16(\$uasw_flow, 0x1FFA + $v, 0x0000);
}
write_bin(File::Spec->catfile($in, 'uasw_flow_only.bin'), $uasw_flow);

# Raw UA-family signatures establish the family but do not by themselves
# distinguish the two selector polarities.  Under ordinary UA, $02C0 selects
# bank 1; under UASW it selects bank 0.  The losing variant therefore fetches
# JAM from the old bank while the correct variant reaches RTS in bank 1.
my $ua_raw_variant = chr(0xEA) x 8192;
break_sc_layout(\$ua_raw_variant);
substr($ua_raw_variant, 0x0100, 4, "\xAD\xC0\x02\x02");
substr($ua_raw_variant, 0x1000 + 0x0103, 1, "\x60");
for my $v (0, 2, 4) {
   put16(\$ua_raw_variant, 0x0FFA + $v, 0xF100);
   put16(\$ua_raw_variant, 0x1FFA + $v, 0x0000);
}
write_bin(File::Spec->catfile($in, 'ua_raw_variant.bin'), $ua_raw_variant);

# $021F,X is one of the historical UA detector signatures.  With X=1 its
# effective $0220 access selects bank 1 only under the swapped UASW polarity.
# This pins behavioral variant selection without relying on VCSC tail metadata.
my $uasw_raw_variant = chr(0xEA) x 8192;
break_sc_layout(\$uasw_raw_variant);
substr($uasw_raw_variant, 0x0100, 6, "\xA2\x01\xBD\x1F\x02\x02");
substr($uasw_raw_variant, 0x1000 + 0x0105, 1, "\x60");
for my $v (0, 2, 4) {
   put16(\$uasw_raw_variant, 0x0FFA + $v, 0xF100);
   put16(\$uasw_raw_variant, 0x1FFA + $v, 0x0000);
}
write_bin(File::Spec->catfile($in, 'uasw_raw_variant.bin'), $uasw_raw_variant);

# Parker Brothers E0 is a segmented mapper, not a whole-4K bank switch.  RESET
# executes from fixed physical bank 7, jumps into default segment 0 (bank 4),
# then LDA $FFE0 replaces that segment with bank 0.  The byte physically after
# the selector in bank 4 is JAM; the actual next fetch comes from bank 0.
my $e0_flow = chr(0x02) x 8192;
break_sc_layout(\$e0_flow);
substr($e0_flow, 7 * 1024, 3, "\x4C\x00\xF1");          # fixed bank7: JMP $F100
substr($e0_flow, 4 * 1024 + 0x0100, 4, "\xAD\xE0\xFF\x02");
substr($e0_flow, 0x0103, 12,
   "\xAD\xE9\xFF" .                                  # E0 segment1 selector/signature
   "\xA9\x42\xAA\xA8\xE8\xCA\xC8\x88\x60");
for my $v (0, 2, 4) {
   put16(\$e0_flow, 7 * 1024 + 0x03FA + $v, 0xFC00);
}
write_bin(File::Spec->catfile($in, 'e0_flow_only.bin'), $e0_flow);

# The same rule must work for a speculative island.  The detached routine is
# in physical bank 4 at runtime $F203.  Its E0 selector changes segment 0 to
# bank 0; the old-bank next byte is JAM, while bank 0 contains the continuation.
my $e0_island = chr(0xEA) x 8192;
break_sc_layout(\$e0_island);
substr($e0_island, 7 * 1024, 1, "\x60");               # mapper-neutral RESET path
for my $v (0, 2, 4) {
   put16(\$e0_island, 7 * 1024 + 0x03FA + $v, 0xFC00);
   # Presentation-origin evidence for physical bank 4; E0 ignores these as
   # hardware vectors, but they make the synthetic island's runtime $F2xx
   # placement unambiguous to the source emitter.
   put16(\$e0_island, 4 * 1024 + 0x03FA + $v, 0xF203);
}
substr($e0_island, 4 * 1024 + 0x0200, 7,
   "\x02\x12\x22" .                                  # rejected-start barrier
   "\xAD\xE0\xFF" .                                  # E0 -> bank0 in segment0
   "\x02");                                           # old-bank JAM, never fetched
substr($e0_island, 0x0206, 12,
   "\xAD\xE9\xFF" .                                  # selector + E0 signature
   "\xA9\x42\xAA\xA8\xE8\xCA\xC8\x88\x60");
write_bin(File::Spec->catfile($in, 'e0_speculative_banked_island.bin'), $e0_island);

# A plain F8 ROM may legitimately read ordinary ROM in $F080-$F0FF.
# Read-window-looking evidence alone must not promote it to Superchip.
write_bin(File::Spec->catfile($in, 'f8_sc_read_only.bin'),
   make_rom(8192, 0xF000, 0x0100, "\xAD\x80\xF0\xAD\xF8\x1F\x60"));

# Ordinary banked ROMs may also write cartridge space.  A write to the
# Superchip-looking $x000-$x07F alias is not enough by itself: automatic
# semantic promotion requires established use of the $x080-$x0FF read alias as
# well.  Pin that rule at every
# F8/F6/F4 size because corpus false positives occurred in all three families.
write_bin(File::Spec->catfile($in, 'f8_sc_write_only.bin'),
   make_rom(8192, 0xF000, 0x0100, "\x8D\x20\xF0\xAD\xF8\x1F\x60"));
write_bin(File::Spec->catfile($in, 'f6_sc_write_only.bin'),
   make_rom(16384, 0xF000, 0x0100, "\x8D\x20\xF0\xAD\xF6\x1F\x60"));
write_bin(File::Spec->catfile($in, 'f4_sc_write_only.bin'),
   make_rom(32768, 0xF000, 0x0100, "\x8D\x20\xF0\xAD\xF4\x1F\x60"));

# The two aliases need not use the same RAM offset.  This is still genuine
# split-address SC behavior and must not be rejected just because no individual
# byte is observed on both sides of the analysis.
write_bin(File::Spec->catfile($in, 'f8sc_disjoint_offsets.bin'),
   make_rom(8192, 0xF000, 0x0100,
      "\x8D\x20\xF0\xAD\xA1\xF0\xAD\xF8\x1F\x60"));

# RMW instructions cannot be valid Superchip RAM operations because the read
# and write aliases are different addresses.  Any reachable RMW anywhere in
# $F000-$F0FF is therefore negative SC evidence, not merely "not positive".
write_bin(File::Spec->catfile($in, 'plain4k_sc_rmw_only.bin'),
   make_rom(4096, 0xF000, 0x0100, "\x0E\x00\xF0\x60"));
write_bin(File::Spec->catfile($in, 'plain4k_sc_rmw_write_conflict.bin'),
   make_rom(4096, 0xF000, 0x0100,
      "\x8D\x20\xF0" .      # otherwise-positive SC write
      "\xEE\x40\xF0" .      # RMW in write port: contradiction
      "\x60"));
write_bin(File::Spec->catfile($in, 'plain4k_sc_rmw_read_conflict.bin'),
   make_rom(4096, 0xF000, 0x0100,
      "\x8D\x20\xF0" .      # otherwise-positive SC write
      "\xEE\x80\xF0" .      # RMW in read port: contradiction
      "\x60"));

# Even paired semantic SC evidence must not override established RESET/control
# flow through the SC write port: instruction fetch there proves those physical
# ROM bytes are intended to execute and therefore vetoes automatic SC.
write_bin(File::Spec->catfile($in, 'plain4k_sc_write_port_exec.bin'),
   make_rom(4096, 0xF000, 0x0000, "\x8D\x20\xF0\xAD\xA0\xF0\x60"));

# Historical Stella 4KSC images use ASCII "SC" in the unbonded NMI-vector
# bytes at $FFFA-$FFFB.  This is explicit mapper metadata just like VCSC's
# newer 4-byte "4KSC" signature, and must work without semantic SC accesses.
my $stella_4ksc_marker = make_rom(4096, 0xF000, 0x0100, "\xA9\x42\x60");
substr($stella_4ksc_marker, 0x0080, 1, "\x18"); # do not rely on prefix duplication
substr($stella_4ksc_marker, 0x0FFA, 2, "SC");
write_bin(File::Spec->catfile($in, 'stella_4ksc_marker.bin'), $stella_4ksc_marker);
write_bin(File::Spec->catfile($in, 'f6.bin'), make_rom(16384, 0xF000, 0x0100, "\xAD\xF6\x1F\x60"));

# A wrong mapper must not win merely because it traces less code.  Both F6 and
# JANE are viable here: the ordinary 16K/F6 reset path in bank 3 exits the
# statically decoded cartridge window, while JANE's fixed startup bank 1 simply
# returns.  There is no JANE signature or JANE-specific selector evidence, so
# fewer dynamic exits would be exactly backwards: the truncated JANE CFG is not
# positive mapper evidence.  Preserve the normal 16K default, F6.
my $f6_jane_exit_tie = chr(0xEA) x 16384;
break_sc_layout(\$f6_jane_exit_tie);
substr($f6_jane_exit_tie, 0 * 4096 + 0x0100, 1, "\x60");
substr($f6_jane_exit_tie, 1 * 4096 + 0x0100, 1, "\x60");
substr($f6_jane_exit_tie, 2 * 4096 + 0x0100, 1, "\x60");
substr($f6_jane_exit_tie, 3 * 4096 + 0x0100, 3, "\x4C\x80\x00");
for my $b (0 .. 3) {
   for my $v (0, 2, 4) {
      put16(\$f6_jane_exit_tie, $b * 4096 + 0x0FFA + $v, 0xF100);
   }
}
write_bin(File::Spec->catfile($in, 'f6_jane_exit_tie.bin'), $f6_jane_exit_tie);


# A coherent JANE startup-bank interpretation is not mapper evidence by itself.
# This fixture deliberately makes the ordinary F6 power-on bank halt while
# JANE's fixed bank 1 returns cleanly, but contains neither the Stella JANE
# signature nor an established access to JANE's unique $1FF0/$1FF1 selectors.
# Automatic inference must keep the normal 16K default, F6, rather than rescue
# the image by choosing whichever startup bank happens to decode farther.
my $f6_jane_no_evidence = chr(0xEA) x 16384;
break_sc_layout(\$f6_jane_no_evidence);
substr($f6_jane_no_evidence, 1 * 4096 + 0x0100, 1, "\x60");
substr($f6_jane_no_evidence, 3 * 4096 + 0x0100, 1, "\x02");
for my $b (0 .. 3) {
   for my $v (0, 2, 4) {
      put16(\$f6_jane_no_evidence, $b * 4096 + 0x0FFA + $v, 0xF100);
   }
}
write_bin(File::Spec->catfile($in, 'f6_jane_no_evidence_rescue.bin'),
   $f6_jane_no_evidence);



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

# All native split-address cartridge RAM has the same RMW impossibility as
# Superchip: one effective address cannot be both the read alias and write
# alias.  FA's split is $F000-$F0FF write / $F100-$F1FF read.  These remain FA
# by their unique 12K shape, but the contradiction must be reported rather
# than mistaken for meaningful RAM access.
my $fa_rmw_write = $fa;
substr($fa_rmw_write, 2 * 4096 + 0x0208, 4, "\xEE\x20\xF0\x60");
write_bin(File::Spec->catfile($in, 'fa_rmw_write.bin'), $fa_rmw_write);
my $fa_rmw_read = $fa;
substr($fa_rmw_read, 2 * 4096 + 0x0208, 4, "\xEE\x20\xF1\x60");
write_bin(File::Spec->catfile($in, 'fa_rmw_read.bin'), $fa_rmw_read);

# CV competes with ordinary mirrored 2K ROM.  A deliberate CV tail signature
# is not allowed to override contradictory executable semantics: reachable RMW
# against either half of CV's split RAM window eliminates CV and leaves 2K.
for my $case ([cv_rmw_read => 0xF020], [cv_rmw_write => 0xF420]) {
   my ($name, $addr) = @$case;
   my $rom = make_rom(2048, 0xF800, 0x0100, pack('C v C', 0xEE, $addr, 0x60));
   substr($rom, 0x07F8, 4, "CV\0\0");
   write_bin(File::Spec->catfile($in, "$name.bin"), $rom);
}

# Stella accepts two 4K storage forms for the intrinsically 2K CV mapper.
# A doubled 2K image is analyzed as the final 2K ROM and preserved exactly;
# the MagiCard-style save image stores initial cartridge RAM/padding in the
# first 2K and the actual CV ROM in the final 2K.
my $cv_2k = make_rom(2048, 0xF800, 0x0100, "\xA9\x42\x99\x00\xF4\x60");
my $cv_doubled_4k = $cv_2k . $cv_2k;
write_bin(File::Spec->catfile($in, 'cv_doubled_4k.bin'), $cv_doubled_4k);
my $cv_saved_prefix = join('', map { chr(($_ * 37 + 11) & 255) } 0 .. 1023) . ("\xFF" x 1024);
my $cv_saved_4k = $cv_saved_prefix . $cv_2k;
write_bin(File::Spec->catfile($in, 'cv_saved_4k.bin'), $cv_saved_4k);

# A bank origin can be inferred from absolute JMP evidence even when that bank
# has unusable vectors.  Bank 1 keeps one real RESET path so the cartridge still
# contains established executable code under the zero-instruction success rule.
my $jmp_origins = chr(0xEA) x 8192;
break_sc_layout(\$jmp_origins);
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

# Wickstead Design / Pursuit of the Pink Panther has two file forms in Stella.
# WDSW is the historical 8K+3 preservation dump: its physical 1K chunks 2/3
# are reversed and the last three bytes are outside the emulated ROM.  WD is
# the corrected 8192-byte ordering and is detected by Stella's LDA $39; JMP
# signature.  Both use the same four-segment hardware and delayed TIA selector.
# Power-on arrangement 0 maps logical 0,0,1,3, so the WDSW vector in physical
# file chunk 2 (logical bank 3 after correction) enters bank 0 at bus $1400.
my $wdsw = chr(0x02) x 8195;
substr($wdsw, 0x0000, 6, "\xA5\x39\x4C\x05\xD4\x60");
substr($wdsw, 0x0400 + 3, 1, "\x60");
for my $v (0, 2, 4) {
   put16(\$wdsw, 0x0800 + 0x03FA + $v, 0xD400);
}
substr($wdsw, 8192, 3, "\x12\x34\x56");
write_bin(File::Spec->catfile($in, 'wdsw_bad_dump.bin'), $wdsw);

# Correct the historical dump to Stella's ordinary 8K WD file layout by
# swapping physical chunks 2/3 and removing the three preservation bytes.
my $wd = substr($wdsw, 0, 8192);
my $wd_chunk2 = substr($wd, 2 * 1024, 1024);
my $wd_chunk3 = substr($wd, 3 * 1024, 1024);
substr($wd, 2 * 1024, 1024, $wd_chunk3);
substr($wd, 3 * 1024, 1024, $wd_chunk2);
write_bin(File::Spec->catfile($in, 'wd.bin'), $wd);

my $wdsw_rmw_read = $wdsw;
substr($wdsw_rmw_read, 0x0000, 4, "\xEE\x20\xF0\x60");
write_bin(File::Spec->catfile($in, 'wdsw_rmw_read.bin'), $wdsw_rmw_read);
my $wdsw_rmw_write = $wdsw;
substr($wdsw_rmw_write, 0x0000, 4, "\xEE\x60\xF0\x60");
write_bin(File::Spec->catfile($in, 'wdsw_rmw_write.bin'), $wdsw_rmw_write);


# Amiga Power Play FC stages a target bank through $1FF8/$1FF9 and changes
# the visible 4K bank only when $1FFC is accessed.  Deliberate JAMs in the old
# bank immediately after each commit prove that the next opcode comes from the
# newly committed bank, while the NOP before the first commit proves staging
# alone does not change the active bank.
my $fc = chr(0xEA) x 32768;
my $fc_entry = 0x0100;
my $fc_code =
   "\xA9\x1A" .             # LDA #$1A
   "\x8D\xF8\x1F" .        # STA $1FF8 -> pending low = 2
   "\x4A\x4A" .             # LSR; LSR -> A = 6
   "\x8D\xF9\x1F" .        # STA $1FF9 -> oversized-high fallback => target 6
   "\xEA" .                 # still bank 0 before commit
   "\xAD\xFC\x1F";          # LDA $1FFC -> commit bank 6
substr($fc, $fc_entry, length($fc_code), $fc_code);
my $fc_after_read = $fc_entry + length($fc_code);
substr($fc, $fc_after_read, 1, "\x02"); # old-bank continuation is JAM
my $fc6_code =
   "\xA9\x03" .             # LDA #3
   "\x8D\xF8\x1F" .        # stage target 3, bank 6 still active
   "\x8D\xFC\x1F";          # write $1FFC -> commit bank 3
substr($fc, 6 * 4096 + $fc_after_read, length($fc6_code), $fc6_code);
my $fc_after_write = $fc_after_read + length($fc6_code);
substr($fc, 6 * 4096 + $fc_after_write, 1, "\x02"); # old bank 6 is JAM
substr($fc, 3 * 4096 + $fc_after_write, 1, "\x60"); # committed bank 3 RTS
for my $v (0, 2, 4) {
   put16(\$fc, 0x0FFA + $v, 0xF000 + $fc_entry);
}
write_bin(File::Spec->catfile($in, 'fc.bin'), $fc);

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

# A relative branch may wrap the 16-bit CPU PC from $FFxx into $00xx.  The
# disassembler should preserve the real short branch and its .cross contract;
# vcsc-as must encode the wrapped displacement rather than relaxing it long.
my $branch_wrap = make_rom(4096, 0xF000, 0x0FF0, "\x10\x20\x60");
write_bin(File::Spec->catfile($in, 'branch_wrap_ffff.bin'), $branch_wrap);

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

# Dynamic animation pointers often use a ROM low-byte table plus a constant high
# byte.  X is deliberately unknown here; all three eight-row frames must still
# be recognized because the low-byte table has an exact $08 stride and the
# resulting pointer feeds GRP0 through ($80),Y.
my $pointer_frames = make_rom(4096, 0xF000, 0x0100,
   "\xAD\x80\x02" .           # LDA SWCHA
   "\x29\x03\xAA" .           # AND #3 / TAX (runtime index)
   "\xBD\x40\xF2" .           # LDA $F240,X
   "\x85\x80" .                 # STA pointer low
   "\xA9\xF2\x85\x81" .       # pointer high := $F2
   "\xA0\x07" .                 # LDY #7
   "\xB1\x80" .                 # LDA ($80),Y
   "\x85\x1B" .                 # STA GRP0
   "\x20\x43\xF2\x60");      # make F243 a known boundary
substr($pointer_frames, 0x0240, 3, pack('C*', 0x80, 0x88, 0x90));
substr($pointer_frames, 0x0243, 1, "\x60");
substr($pointer_frames, 0x0280, 24,
   pack('C*',
      0x00,0x18,0x3C,0x7E,0xDB,0x18,0x18,0x00,
      0x00,0x3C,0x66,0xC3,0xC3,0x66,0x3C,0x00,
      0x00,0x7E,0x42,0x5A,0x5A,0x42,0x7E,0x00));
write_bin(File::Spec->catfile($in, 'pointer_frames.bin'), $pointer_frames);

# A long, coherent fixed-height font is strong structural graphics evidence even
# when pointer arithmetic is too dynamic to prove a short direct TIA data-flow
# path.  A single bitmap-shaped object is still not sufficient (not_sprite.bin).
# Start the table immediately after ordinary raw bytes so the emitter regression
# also proves a raw .byte run cannot swallow the first glyph.
my $structural_font = make_rom(4096, 0xF000, 0x0100, "\x60");
substr($structural_font, 0x02F8, 8, pack('C*', 1,2,4,8,16,32,64,128));
substr($structural_font, 0x0300, 64,
   pack('C*',
      0x3C,0x66,0x66,0x66,0x66,0x66,0x66,0x3C,
      0x3C,0x18,0x18,0x18,0x18,0x18,0x38,0x18,
      0x7E,0x60,0x60,0x3C,0x06,0x06,0x46,0x3C,
      0x3C,0x46,0x06,0x0C,0x0C,0x06,0x46,0x3C,
      0x0C,0x0C,0x0C,0x7E,0x4C,0x2C,0x1C,0x0C,
      0x7C,0x46,0x06,0x06,0x7C,0x60,0x60,0x7E,
      0x3C,0x66,0x66,0x66,0x7C,0x60,0x62,0x3C,
      0x18,0x18,0x18,0x18,0x0C,0x06,0x42,0x7E));
write_bin(File::Spec->catfile($in, 'structural_font.bin'), $structural_font);

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


# The same bank-transition semantics apply while rendering speculative islands.
# A candidate in bank 0 reads the F8 selector and execution continues at the same
# logical PC in bank 1.  The byte at that PC in the old bank is JAM and must not
# poison island validation.  The detached selector itself must not vote on mapper
# inference; F8 comes from the independently established size/topology decision.
my $banked_island = make_rom(8192, 0xF000, 0x0100, "\x60");
substr($banked_island, 0x1000 + 0x0100, 1, "\x60");
substr($banked_island, 0x0200, 7,
   "\x02\x12\x22" .             # barrier
   "\xAD\xF9\x1F" .             # F8 -> bank 1
   "\x02");                      # old-bank JAM, never fetched after switch
substr($banked_island, 0x1000 + 0x0206, 9,
   "\xA9\x42\xAA\xA8\xE8\xCA\xC8\x88\x60");
write_bin(File::Spec->catfile($in, 'speculative_banked_island.bin'), $banked_island);

# A same-sized foreign 6502 blob can contain perfectly valid detached routines,
# but if its RESET vector does not establish cartridge code those routines must
# not resurrect mapper viability or make the disassembly successful.
my $no_reset_island = chr(0xEA) x 16384;
break_sc_layout(\$no_reset_island);
substr($no_reset_island, 0x0200, 12,
   "\x02\x12\x22" .
   "\xA9\x42\xAA\xA8\xE8\xCA\xC8\x88\x60");
for my $b (0 .. 3) {
   for my $v (0, 2, 4) {
      put16(\$no_reset_island, $b * 4096 + 0x0FFA + $v, 0x0400);
   }
}
my $no_reset_path = File::Spec->catfile($tmp, 'speculative_without_reset.bin');
write_bin($no_reset_path, $no_reset_island);

# A promoted island may contain perfectly convincing hardware-access idioms,
# but those bytes are still only a presentation hypothesis.  Keep a trivial
# established RESET path and put NTSC-timer + keypad-looking traffic exclusively
# in the detached island.  Neither video nor controller inference may consume it.
my $spec_inference = make_rom(4096, 0xF000, 0x0100, "\x60");
substr($spec_inference, 0x0200, 23,
   "\x02\x12\x22" .             # rejected-start barrier
   "\xA9\x2A\x8D\x96\x02" . # TIM64T := 42
   "\xA9\x22\x8D\x96\x02" . # TIM64T := 34
   "\x8D\x80\x02" .           # STA SWCHA
   "\x24\x38\x24\x39\x24\x3C" . # keypad-looking INPT reads
   "\x60");
write_bin(File::Spec->catfile($in, 'speculative_inference_quarantine.bin'),
   $spec_inference);

# Speculative SC-looking traffic must not change the hardware model even inside
# the speculative phase.  This detached F8 island touches both split aliases and
# then calls ordinary ROM at $F080.  If those speculative accesses were allowed
# to activate Superchip mid-walk, $F080 would become hidden by the RAM window and
# the candidate's own control-flow interpretation would change.
my $spec_sc_freeze = make_rom(8192, 0xF000, 0x0100, "\x60");
substr($spec_sc_freeze, 0x1000 + 0x0100, 1, "\x60");
substr($spec_sc_freeze, 0x0080, 3, "\xA9\x11\x60");
substr($spec_sc_freeze, 0x0200, 15,
   "\x02\x12\x22" .             # rejected-start barrier
   "\xA9\x42" .                 # known write value
   "\x8D\x00\x10" .           # STA $1000: SC write alias
   "\xAD\x80\x10" .           # LDA $1080: SC read alias
   "\x20\x80\xF0" .           # JSR $F080: must remain ROM
   "\x60");
write_bin(File::Spec->catfile($in, 'speculative_sc_hardware_freeze.bin'),
   $spec_sc_freeze);

# A speculative candidate must be rejected when a statically possible path
# reaches JAM/KIL.  CLC makes the BCC-to-KIL path definitely taken.
my $island_jam = make_rom(4096, 0xF000, 0x0100, "\x60");
substr($island_jam, 0x0200, 16,
   "\x02\x12\x22" .             # barrier
   "\x18\x90\x03\xA9\x01\x60\x02" . # CLC/BCC -> KIL
   ("\x02" x 6));
write_bin(File::Spec->catfile($in, 'speculative_jam_reject.bin'), $island_jam);

# A detached candidate near the end of the address space must not be promoted
# when a statically possible relative branch wraps into the TIA register window.
# Reproduce the corpus failure's second ingredient too: the candidate first JSRs
# through a cartridge mirror to a long, valid-looking routine that consumes the
# entire 512-step credibility budget and terminates strongly.  Older validation
# then reached the BMI continuation only after the budget was exhausted, returned
# weak without inspecting it, and let the strong JSR arm promote the island.
my $island_tia_branch = make_rom(4096, 0xF000, 0x0800, "\x60");
substr($island_tia_branch, 0x0020, 511, ("\xEA" x 510) . "\x60");
substr($island_tia_branch, 0x0FD0, 12,
   "\x02\x12\x22" .             # barrier; candidate starts at $FFD3
   "\x20\x20\x30" .             # JSR $3020 -> cart mirror of $F020
   "\x30\x40" .                   # BMI $0018 if N is set
   "\xEA\xEA\x60\xEA");
write_bin(File::Spec->catfile($in, 'speculative_tia_branch_reject.bin'),
   $island_tia_branch);

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
# Commercial SC dumps can provide decisive structural evidence even when the
# reachable CFG does not expose a direct SC store: each 4K bank duplicates the
# 128 physical bytes hidden behind the write/read aliases.
my $f6sc_layout = make_rom(16384, 0xF000, 0x0100,
   "\xAD\xF6\x1F\x60");
for my $b (0 .. 3) {
   my $base = $b * 4096;
   substr($f6sc_layout, $base + 0x80, 0x80,
          substr($f6sc_layout, $base, 0x80));
}
write_bin(File::Spec->catfile($in, 'f6sc_layout.bin'), $f6sc_layout);
# VCSC-generated images carry an explicit four-byte mapper declaration at
# $xFF8-$xFFB in the final file bank.  It must remain authoritative even when
# the image has neither the legacy duplicate-prefix shape nor decoded SC RAM use.
my $f8sc_signature = make_rom(8192, 0xF000, 0x0100, "\xAD\xF8\x1F\x60");
substr($f8sc_signature, length($f8sc_signature) - 8, 4, "F8SC");
write_bin(File::Spec->catfile($in, 'f8sc_signature.bin'), $f8sc_signature);
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

# Dynamic frame probe regressions.  These deliberately use a 2-WSYNC loop whose
# total (258 or 308 lines) is outside the static visible/blanking signatures.
# The only reliable classification comes from actually executing the frame and
# measuring consecutive VSYNC rises.
sub dynamic_frame_rom {
   my ($count) = @_;
   return make_rom(4096, 0xF000, 0x0100, pack('C*',
      0xA9,0x02,             # LDA #2
      0x85,0x00,             # STA VSYNC
      0x85,0x02,0x85,0x02,0x85,0x02, # 3 VSYNC scanlines
      0xA9,0x00,0x85,0x00,  # VSYNC := 0
      0xA2,$count,           # X := 129 (NTSC) or 154 (PAL)
      0x85,0x02,0x85,0x02,  # two WSYNCs per loop
      0xCA,0xD0,0xF9,       # DEX / BNE loop
      0x85,0x02,             # one final line
      0x4C,0x00,0xF1));     # JMP frame
}
write_bin(File::Spec->catfile($in, 'video_dynamic_60hz.bin'),
   dynamic_frame_rom(129));  # 3 + 129*2 + 1 = 262
write_bin(File::Spec->catfile($in, 'video_dynamic_50hz.bin'),
   dynamic_frame_rom(154));  # 3 + 154*2 + 1 = 312
write_bin(File::Spec->catfile($in, 'video_dynamic (SECAM).bin'),
   dynamic_frame_rom(154));

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


# Item 12 analysis-presentation fixtures.  A referenced run of three exact
# little-endian cartridge addresses should be rendered as a pointer table, not
# an anonymous byte blob.
my $pointer_table = make_rom(4096, 0xF000, 0x0100,
   "\x20\x40\xF3" .           # establish F340 as code
   "\x20\x50\xF3" .           # establish F350 as code
   "\x20\x60\xF3" .           # establish F360 as code
   "\xA6\x80" .                 # LDX $80 (runtime word index)
   "\xBD\x00\xF3" .           # LDA F300,X (pointer low)
   "\x85\x80" .                 # STA $80
   "\xE8" .                         # INX to high byte
   "\xBD\x00\xF3" .           # LDA F300,X (pointer high)
   "\x85\x81" .                 # STA $81
   "\xA0\x00" .                 # LDY #0
   "\xB1\x80" .                 # LDA ($80),Y
   "\x60");
substr($pointer_table, 0x0300, 6, pack('v*', 0xF340, 0xF350, 0xF360));
substr($pointer_table, 0x0340, 1, "\x60");
substr($pointer_table, 0x0350, 1, "\x60");
substr($pointer_table, 0x0360, 1, "\x60");
write_bin(File::Spec->catfile($in, 'pointer_table.bin'), $pointer_table);

# A shifted pointer-table interpretation must never swallow a real label.
# The first indexed load makes F2F0..F3EF merely possible data, while the
# second establishes F300 as the real table boundary.  Bytes starting at F2FF
# happen to decode as three valid pointers to established code; Item 12 must not
# turn them into .word containers because that would consume L_F300.
my $shifted_pointer = make_rom(4096, 0xF000, 0x0100,
   "\x20\x00\xF4" .           # establish F400 as code
   "\x20\x10\xF4" .           # establish F410 as code
   "\x20\x20\xF4" .           # establish F420 as code
   "\xA4\x80" .                   # LDY $80 (unknown)
   "\xB9\xF0\xF2" .           # broad possible range from F2F0
   "\xB9\x00\xF3" .           # real indexed-table boundary F300
   "\x60");
substr($shifted_pointer, 0x02FF, 6, pack('v*', 0xF400, 0xF410, 0xF420));
substr($shifted_pointer, 0x0400, 1, "\x60");
substr($shifted_pointer, 0x0410, 1, "\x60");
substr($shifted_pointer, 0x0420, 1, "\x60");
write_bin(File::Spec->catfile($in, 'shifted_pointer_boundary.bin'), $shifted_pointer);

# A counted indexed load that flows directly into COLUBK is strong color-table
# evidence.  Palette-looking bytes without this data-flow proof remain raw.
my $color_table = make_rom(4096, 0xF000, 0x0100,
   "\xA0\x02" .                 # LDY #2
   "\xB9\x80\xF3" .           # loop: LDA F380,Y
   "\x85\x09" .                 # STA COLUBK
   "\x88" .                       # DEY
   "\x10\xF8" .                 # BPL loop
   "\x60");
substr($color_table, 0x0380, 3, pack('C*', 0x84, 0x46, 0xC8));
write_bin(File::Spec->catfile($in, 'color_table.bin'), $color_table);

# Starpath/Arcadia Supercharger fast-load images are structurally different
# from cartridges: each 8448-byte block is 8K page data + a 256-byte header.
# The header maps data pages into the Supercharger's three 2K RAM banks and
# supplies the initial start address/control byte.  Keep physical bytes raw for
# exact reconstruction while emitting a comment-only runtime payload view.
my $ar_page0 = "\xA9\x42\x85\x80\x60" . (chr(0xEA) x 251);
my $ar_single = make_ar_load(0xF000, 0x04, 0, 0x00, $ar_page0);
write_bin(File::Spec->catfile($in, 'ar_single.bin'), $ar_single);
my $ar_page1 = "\xA9\x99\x85\x81\x60" . (chr(0xEA) x 251);
my $ar_multi = $ar_single . make_ar_load(0xF000, 0x14, 1, 0x01, $ar_page1);
write_bin(File::Spec->catfile($in, 'ar_multi.bin'), $ar_multi);

run_ok($^X, $roundtrip, $in, $out);

my $multicart_out = slurp(File::Spec->catfile($out, 'multicart_4in1.s26'));
require_re($multicart_out, qr/^; mapper: 4IN1 \(container;/m,
   '4IN1 outer image recognized as a container');
require_re($multicart_out, qr/^; container analysis: 4\/4 component slices established independently$/m,
   '4IN1 components analyzed independently');
for my $game (1 .. 4) {
   my $sidecar = File::Spec->catfile($out, sprintf('multicart_4in1.game%02d.s26', $game));
   -f $sidecar or die "missing 4IN1 component sidecar $sidecar\n";
   my $text = slurp($sidecar);
   require_re($text, qr/^; mapper: unbanked 2K \(/m,
      "4IN1 component $game independently disassembled");
}

# A detached island is never enough to satisfy the tool's minimum executable
# evidence contract.  With no cartridge-backed RESET/manual/concrete entry,
# the disassembler must now refuse the image rather than letting speculation
# turn a foreign/same-sized blob into apparent code.
my $no_reset_out = File::Spec->catfile($tmp, 'speculative_without_reset.s26');
my $no_reset_rc = system($disas, '-o', $no_reset_out, $no_reset_path);
die "speculative-only image unexpectedly disassembled successfully\n"
   if $no_reset_rc == 0;
die "speculative-only rejection unexpectedly created output\n"
   if -e $no_reset_out;

my $ar_single_out = slurp(File::Spec->catfile($out, 'ar_single.s26'));
require_re($ar_single_out, qr/^; mapper: AR \(high confidence;/m,
   '8448-byte image recognized as Starpath AR');
require_re($ar_single_out,
   qr/^; Starpath\/Arcadia Supercharger fast-load image: 1 load x 8448 bytes/m,
   'AR single-load structural annotation');
require_re($ar_single_out,
   qr/^; AR load 0: .*load-id=\$00, start=\$F000, control=\$04, pages=1, header-checksum=ok, page-checksums=ok$/m,
   'AR header decoded');
require_re($ar_single_out,
   qr/^; \$F000: A9 42\s+LDA #\$42\s+; loaded from file \$0000$/m,
   'AR RAM payload decoded with physical provenance');
my $ar_multi_out = slurp(File::Spec->catfile($out, 'ar_multi.s26'));
require_re($ar_multi_out,
   qr/^; Starpath\/Arcadia Supercharger fast-load image: 2 loads x 8448 bytes/m,
   'AR concatenated multi-load structural annotation');
require_re($ar_multi_out,
   qr/^; AR load 1: .*load-id=\$01, start=\$F000, control=\$14, pages=1/m,
   'AR nonzero multi-load header decoded');

my $odd4k_over_out = slurp(File::Spec->catfile($out, 'odd4k_over.s26'));
require_re($odd4k_over_out, qr/^; input bytes: 4098$/m,
   '4098-byte physical size retained');
require_re($odd4k_over_out, qr/^; mapper: unbanked 4K \(/m,
   '4098-byte dump analyzed as logical 4K');
require_re($odd4k_over_out,
   qr/^; preservation image: 4098-byte overlong 4K dump; Stella-compatible analysis ignores 2 trailing bytes, retained raw for exact round trip$/m,
   '4098-byte overlong preservation annotation');
require_re($odd4k_over_out,
   qr/^; ---- trailing bytes from overlong 4K preservation dump ----$/m,
   '4098-byte trailing preservation section');

my $odd4k_under_out = slurp(File::Spec->catfile($out, 'odd4k_under.s26'));
require_re($odd4k_under_out, qr/^; input bytes: 4094$/m,
   '4094-byte physical size retained');
require_re($odd4k_under_out, qr/^; mapper: unbanked 4K \(/m,
   '4094-byte dump analyzed as logical 4K');
require_re($odd4k_under_out,
   qr/^; preservation image: 4094-byte short 4K dump; Stella-compatible analysis zero-fills 2 missing tail bytes, but generated source preserves the original file length$/m,
   '4094-byte short preservation annotation');

my $plain1k_out = slurp(File::Spec->catfile($out, 'plain1k.s26'));
require_re($plain1k_out, qr/^; mapper: unbanked 1K \(/m,
   '1024-byte image recognized as unbanked 1K');
require_re($plain1k_out, qr/^; physical banks: 1 x 1024 bytes$/m,
   '1K physical topology');
require_re($plain1k_out, qr/^; bank 0: .*origin \$FC00/m,
   '1K canonical top-mirror origin');
require_re($plain1k_out, qr/^; usage bytes: .*vectors=6\b/m,
   'all three 1K vector words remain classified as vector data');
die "unreachable IRQ-only 1K routine was incorrectly promoted to code\n"
   if $plain1k_out =~ /^L_FC80:\s*\n\s*LDA\s+#\$99/m;

my $concrete_out = slurp(File::Spec->catfile($out, 'concrete_payload.s26'));
require_re($concrete_out,
   qr/^; concrete RESET discovery: .*RIOT-RAM-starts=3 .*reachability converged$/m,
   'bounded concrete RESET discovery executes generated RIOT-RAM payload');
require_re($concrete_out,
   qr/^; concrete RESET discovery: .*ROM-data-bytes=[1-9]\d* .*RIOT-RAM-starts=3/m,
   'concrete discovery retains observed ROM data reads');
require_re($concrete_out,
   qr/^; usage bytes: .*data-read=[1-9]\d*/m,
   'observed concrete ROM reads feed usage-role accounting');
require_re($concrete_out,
   qr/\bBRK\n\s*LDX\s+#\$07/m,
   'concrete execution seeds the statically opaque BRK continuation');
require_re($concrete_out,
   qr/^; ---- concrete RIOT RAM execution \(comment-only discovery\) ----$/m,
   'concrete RIOT-RAM execution section');
require_re($concrete_out,
   qr/^; \$0080: A9 42\s+LDA #\$42\s+; copied from ROM file \$0000$/m,
   'RAM payload instruction recovered with ROM provenance');
require_re($concrete_out,
   qr/^; \$0084: 4C 80 00\s+JMP \$0080\s+; copied from ROM file \$0004$/m,
   'RAM payload control flow recovered with ROM provenance');


my $h1_input_out = slurp(File::Spec->catfile($out, 'h1_input_payload.s26'));
require_re($h1_input_out,
   qr/^; static interrupt analysis: 1 provable BRK\/IRQ\/RTI continuation$/m,
   'known-SP BRK/IRQ/RTI continuation is statically proven');
require_re($h1_input_out,
   qr/^L_FC40:\s*\n\s*DEC\s+\$FE\n\s*RTI/m,
   'reachable BRK promotes its IRQ/BRK vector target into executable code');
require_re($h1_input_out,
   qr/\bBRK\n(?:L_[0-9A-F]+:\n)?\s*LDX\s+#\$05/m,
   'static CFG reaches code immediately after the one-byte BRK call');
require_re($h1_input_out,
   qr/^; concrete RESET discovery: scenarios=16 productive=[1-9]\d* .*RIOT-RAM-starts=[1-9]\d* .*reachability converged$/m,
   'input-gated loader is reached by a demand-driven alternate SWCHA scenario');
require_re($h1_input_out,
   qr/^; \$0080: A9 42\s+LDA #\$42\s+; copied from ROM file \$0000$/m,
   'alternate-input execution recovers copied RIOT-RAM payload with provenance');


my $console_switches_out = slurp(File::Spec->catfile($out, 'console_switches.s26'));
require_re($console_switches_out,
   qr/^; concrete RESET discovery: scenarios=24 productive=[1-9]\d* .*RAM-bytes-written=3.*reachability converged$/m,
   'all 8 maintained configurations run and SELECT receives a full 10-frame released/pressed/released pulse');
require_re($console_switches_out, qr/10 VBLANK frames released, 10 pressed, then 10 released/m,
   'generated header documents frame-counted SELECT/RESET pulse timing');

my $baseline_vblank_out = slurp(File::Spec->catfile($out, 'baseline_vblank.s26'));
require_re($baseline_vblank_out,
   qr/^; concrete RESET discovery: .*reachability converged$/m,
   'baseline concrete discovery converges after VBLANK dwell');
my ($baseline_vblank_instructions) =
   $baseline_vblank_out =~ /^; concrete RESET discovery: .*instructions=(\d+)/m;
defined($baseline_vblank_instructions) or die "missing VBLANK baseline instruction count\n";
$baseline_vblank_instructions >= 40000
   or die "VBLANK baseline converged before ten assertion edges: $baseline_vblank_instructions instructions\n";
require_re($baseline_vblank_out,
   qr/requires 10 VBLANK assertions before convergence once VBLANK is used/m,
   'generated header documents ten-VBLANK baseline minimum');

my $h2_fixed_out = slurp(File::Spec->catfile($out, 'h2_fixed_point.s26'));
require_re($h2_fixed_out,
   qr/^; H2 fixed-point feedback: rounds=[1-9]\d* exact-static-seeds=[1-9]\d* new-reachability=[1-9]\d*$/m,
   'H2 feeds exact static states into concrete discovery');
require_re($h2_fixed_out,
   qr/^; \$0080: A9 42\s+LDA #\$42\s+; copied from ROM file \$0000$/m,
   'H2 concrete continuation executes the static-only copied RAM payload');

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
require_re($kil_text, qr/no (?:established )?instructions found/i, 'zero-instruction hard error');

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
require_re(slurp($odd_log), qr/no (?:established )?instructions found/i, 'raw-layout zero-instruction error');

my $doubled_2k_out = slurp(File::Spec->catfile($out, 'doubled2k.s26'));
require_re($doubled_2k_out, qr/^; mapper: unbanked 2K \(/m,
   'byte-identical doubled 2K dump recognized as logical 2K');
require_re($doubled_2k_out,
   qr/^; preservation image: 2K ROM duplicated byte-for-byte to 4K;/m,
   'doubled 2K preservation annotation');
require_re($doubled_2k_out,
   qr/^; ---- duplicated second 2K copy from preservation image ----$/m,
   'doubled 2K second-copy preservation section');

my $doubled_4k_out = slurp(File::Spec->catfile($out, 'doubled4k.s26'));
require_re($doubled_4k_out, qr/^; mapper: unbanked 4K \(/m,
   'byte-identical doubled 4K dump recognized as logical 4K before UA heuristics');
require_re($doubled_4k_out,
   qr/^; preservation image: 4K ROM duplicated byte-for-byte to 8K;/m,
   'doubled 4K preservation annotation');
require_re($doubled_4k_out,
   qr/^; ---- duplicated second 4K copy from preservation image ----$/m,
   'doubled 4K second-copy preservation section');

my $f8_out = slurp(File::Spec->catfile($out, 'f8.s26'));
require_re($f8_out, qr/^B0_F100:\s*$/m,
   'bank-qualified colliding label in bank 0');
require_re($f8_out, qr/^B1_F100:\s*$/m,
   'bank-qualified colliding label in bank 1');

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
for my $case (
   ['fa_rmw_write.s26', 'FA write-port'],
   ['fa_rmw_read.s26',  'FA read-port'],
) {
   my ($name, $which) = @$case;
   my $text = slurp(File::Spec->catfile($out, $name));
   require_re($text, qr/^; mapper: FA \(high confidence;.*1 native split-RAM RMW conflict\)/m,
      "$which RMW recorded as split-RAM contradiction");
}

my $sc_disjoint = slurp(File::Spec->catfile($out, 'f8sc_disjoint_offsets.s26'));
require_re($sc_disjoint, qr/^; mapper: F8SC\b/m,
   'F8SC semantic inference accepts disjoint established read/write offsets');
require_re($sc_disjoint,
   qr/1 SC write, 0 SC RMW conflicts, 1 SC read, 0 SC paired offsets/,
   'disjoint SC aliases are diagnostic evidence without an artificial byte-pair requirement');
my $cv_doubled_out = slurp(File::Spec->catfile($out, 'cv_doubled_4k.s26'));
require_re($cv_doubled_out, qr/^; mapper: CV \(high confidence;/m,
   'doubled 2K CV storage form remains CV');
require_re($cv_doubled_out, qr/^; preservation image: CV 2K ROM duplicated byte-for-byte to 4K;/m,
   'doubled 2K CV preservation form is documented');
my $cv_saved_out = slurp(File::Spec->catfile($out, 'cv_saved_4k.s26'));
require_re($cv_saved_out, qr/^; mapper: CV \(high confidence;/m,
   '4K CV save-image storage form remains CV');
require_re($cv_saved_out, qr/^; preservation image: Stella 4K CV save form;/m,
   '4K CV saved-RAM preservation form is documented');

for my $case (
   ['cv_rmw_read.s26',  'CV read-port'],
   ['cv_rmw_write.s26', 'CV write-port'],
) {
   my ($name, $which) = @$case;
   my $text = slurp(File::Spec->catfile($out, $name));
   require_re($text, qr/^; mapper: unbanked 2K \(/m,
      "$which RMW rejects CV mapper hypothesis");
   require_re($text, qr/^; mapper flow hypotheses: 2 tested, 1 survived; control flow refined selection$/m,
      "$which split-RAM contradiction refines CV to plain 2K");
}

my $dpc_out = slurp(File::Spec->catfile($out, 'dpc.s26'));
require_re($dpc_out, qr/^; mapper: DPC \(high confidence;/m, 'DPC size mapper inference');
require_re($dpc_out, qr/^; DPC auxiliary data ROM: file \$2000\.\.\$27FF \(2048 bytes\)$/m,
   'DPC auxiliary data layout comment');
require_re($dpc_out, qr/^; DPC RNG table: file \$2800\.\.\$28FE \(255 bytes\)$/m,
   'DPC RNG table layout comment');
require_re($dpc_out, qr/^; ---- DPC auxiliary 2K display\/data ROM ----$/m,
   'DPC auxiliary source section');

my $wdsw_out = slurp(File::Spec->catfile($out, 'wdsw_bad_dump.s26'));
require_re($wdsw_out, qr/^; mapper: WDSW \(high confidence;/m,
   'WDSW 8195-byte mapper inference');
require_re($wdsw_out,
   qr/^; WDSW cartridge RAM: read \$1000-\$103F, write \$1040-\$107F \(64 bytes\)$/m,
   'WDSW RAM mapping annotation');
require_re($wdsw_out,
   qr/^; WDSW 8195-byte preservation form: logical 1K banks 2 and 3 are reversed in the file;/m,
   'WDSW malformed-dump correction annotation');
require_re($wdsw_out, qr/WDSW selector -> arrangement 1 \(hardware-delayed\)/,
   'WDSW TIA selector annotation');
require_re($wdsw_out,
   qr/^; ---- trailing bytes from 8195-byte WDSW preservation dump ----$/m,
   'WDSW trailing-byte preservation section');
require_re($wdsw_out, qr/^\s*\.byte \$12, \$34, \$56$/m,
   'WDSW trailing bytes preserved exactly');

my $wd_out = slurp(File::Spec->catfile($out, 'wd.s26'));
require_re($wd_out, qr/^; mapper: WD \(high confidence;/m,
   'corrected 8192-byte WD mapper inference');
require_re($wd_out, qr/WD selector -> arrangement 1 \(hardware-delayed\)/,
   'WD TIA selector annotation');
die "corrected WD mislabeled as WDSW preservation form\n"
   if $wd_out =~ /WDSW 8195-byte preservation form/;

for my $case (
   ['wdsw_rmw_read.s26',  'WDSW read-port'],
   ['wdsw_rmw_write.s26', 'WDSW write-port'],
) {
   my ($name, $which) = @$case;
   my $text = slurp(File::Spec->catfile($out, $name));
   require_re($text, qr/^; mapper: WDSW \(high confidence;.*1 native split-RAM RMW conflict\)/m,
      "$which RMW recorded as split-RAM contradiction");
}

my $fc_out = slurp(File::Spec->catfile($out, 'fc.s26'));
require_re($fc_out, qr/^; mapper: FC \(high confidence;/m,
   'FC staged mapper inference');
require_re($fc_out,
   qr/^; FC switching: write low selector to \$1FF8, write high selector to \$1FF9, then access \$1FFC to commit;/m,
   'FC staged protocol annotation');
require_re($fc_out, qr/STA\s+\$1FF8\s+; FC stage low bank bits/m,
   'FC low selector instruction annotation');
require_re($fc_out, qr/STA\s+\$1FF9\s+; FC stage high bank bits/m,
   'FC high selector instruction annotation');
require_re($fc_out, qr/LDA\s+\$1FFC\s+; FC commit pending bank/m,
   'FC read commit instruction annotation');
require_re($fc_out, qr/STA\s+\$1FFC\s+; FC commit pending bank/m,
   'FC write commit instruction annotation');
require_re($fc_out, qr/^; reset\/power-on bank: 0 \(FC hardware bank 0; pending target 0\)$/m,
   'FC startup bank and pending selector');
require_re($fc_out, qr/^B6_F10E:/m,
   'FC read commit continues in staged bank 6 before old-bank JAM');
require_re($fc_out, qr/^B3_F116:/m,
   'FC write commit continues in staged bank 3 before old-bank JAM');

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

my $branch_wrap_out = slurp(File::Spec->catfile($out, 'branch_wrap_ffff.s26'));
require_re($branch_wrap_out, qr/\bBPL\.cross\s+\$0012\b/,
   '16-bit wrapped relative branch retained as short cross-page branch');

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
   qr/^; usage bytes: .*data-read=[1-9]\d* .*possible=0 .*unclassified=[1-9]\d*$/m,
   'resolved indirect-read usage accounting');
require_re($known_indirect, qr/ROM bytes not classified by discovered code\/data references/i,
   'unclassified ROM annotation');


my $pointer_table_out = slurp(File::Spec->catfile($out, 'pointer_table.s26'));
require_re($pointer_table_out, qr/probable little-endian ROM pointer table/i,
   'pointer-table annotation');
require_re($pointer_table_out,
   qr/\.word\s+L_F340\s*\n\s*\.word\s+L_F350\s*\n\s*\.word\s+L_F360/m,
   'symbolic pointer-table words');
require_re($pointer_table_out, qr/(?:definite|possible) ROM-data target/i,
   'ROM-data target annotation');

my $shifted_pointer_out = slurp(File::Spec->catfile($out, 'shifted_pointer_boundary.s26'));
require_re($shifted_pointer_out, qr/^L_F300:\s*$/m,
   'interior indexed-data label survives table presentation');
die "shifted possible-data bytes falsely rendered as pointer table\n"
   if $shifted_pointer_out =~ /probable little-endian ROM pointer table/i;

my $color_table_out = slurp(File::Spec->catfile($out, 'color_table.s26'));
require_re($color_table_out, qr/probable TIA color table .*COLU\*/i,
   'color-table annotation');
require_re($color_table_out, qr/\.byte\s+\$84,\s*\$46.*?\.byte\s+\$C8/is,
   'color-table byte preservation across interior label');
require_re($color_table_out, qr/^L_F382:\s*$/m,
   'color-table interior label preserved');

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

my $pointer_frames_out = slurp(File::Spec->catfile($out, 'pointer_frames.s26'));
my @pointer_frame_rows = ($pointer_frames_out =~ /^\s*\.byte\s+%[01]{8}\s+;\s+[.X]{8}\s*$/mg);
die "expected 24 visual rows from dynamic low-byte pointer table, got " . scalar(@pointer_frame_rows) . "\n"
   if @pointer_frame_rows != 24;
require_re($pointer_frames_out, qr/^L_F280:\s*$/m, 'first inferred animation-frame label');
require_re($pointer_frames_out, qr/^L_F288:\s*$/m, 'second inferred animation-frame label');
require_re($pointer_frames_out, qr/^L_F290:\s*$/m, 'third inferred animation-frame label');

my $structural_font_out = slurp(File::Spec->catfile($out, 'structural_font.s26'));
my @structural_font_rows = ($structural_font_out =~ /^\s*\.byte\s+%[01]{8}\s+;\s+[.X]{8}\s*$/mg);
die "expected 64 structural-font visual rows, got " . scalar(@structural_font_rows) . "\n"
   if @structural_font_rows != 64;
require_re($structural_font_out, qr/probable 8x8 font\/graphics table/i,
   'structural font annotation');
require_re($structural_font_out, qr/\.byte\s+%00111100\s+;\s+\.\.XXXX\.\./,
   'structural font first glyph row not swallowed by raw run');

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
   qr/^; speculative analysis: rejected-starts=[1-9]\d* barriers=[1-9]\d* islands=[1-9]\d* capped-walks=\d+ promotion-capped=\d+$/m,
   'speculative analysis usage summary');


my $spec_banked = slurp(File::Spec->catfile($out, 'speculative_banked_island.s26'));
require_re($spec_banked, qr/^; mapper: F8 \(/m,
   'banked speculative-island mapper');
require_re($spec_banked,
   qr/^; mapper flow hypotheses: 12 tested, 4 survived$/m,
   'speculative selector traffic and evidence-free UA variants do not rank mapper hypotheses');
require_re($spec_banked,
   qr/^; mapper: F8 \(medium confidence; 0 decoded hotspot accesses,/m,
   'speculative F8 hotspot does not become mapper evidence');
require_re($spec_banked,
   qr/speculative instruction island validated by HLT\/JAM\/KIL rejection\nB0_F203:\n\s*LDA\s+\$1FF9/m,
   'speculative island may end its physical-bank line at an F8 selector');
require_re($spec_banked, qr/^B1_F206:\n\s*LDA\s+#\$42/m,
   'speculative execution resumes in bank selected by hotspot');

my $spec_inference_out = slurp(File::Spec->catfile($out,
   'speculative_inference_quarantine.s26'));
require_re($spec_inference_out,
   qr/^; video: unknown \(unknown confidence\)$/m,
   'speculative timer traffic excluded from video inference');
require_re($spec_inference_out,
   qr/^; controller port 0: unused or unknown \(low confidence\)$/m,
   'speculative keypad traffic excluded from controller inference');
require_re($spec_inference_out,
   qr/^; usage bytes: established-code=1 speculative-code=[1-9]\d* /m,
   'usage report separates established and speculative code');
require_re($spec_inference_out,
   qr/speculative instruction island validated by HLT\/JAM\/KIL rejection\nL_F203:/m,
   'quarantined speculative code remains available for presentation');

my $spec_sc_freeze_out = slurp(File::Spec->catfile($out,
   'speculative_sc_hardware_freeze.s26'));
require_re($spec_sc_freeze_out, qr/^; mapper: F8 \(/m,
   'speculative SC hardware-freeze mapper remains plain F8');
require_re($spec_sc_freeze_out,
   qr/^; mapper: F8 \(medium confidence; 0 decoded hotspot accesses, 0 SC writes, 0 SC RMW conflicts, 0 SC reads,/m,
   'speculative SC accesses do not become hardware evidence');
require_re($spec_sc_freeze_out, qr/^B0_F080:\n\s*LDA\s+#\$11/m,
   'speculative SC accesses cannot hide ordinary ROM mid-phase');
require_re($spec_sc_freeze_out,
   qr/^; usage bytes: established-code=[1-9]\d* speculative-code=[1-9]\d* /m,
   'speculative SC hardware-freeze code remains quarantined');

my $spec_jam = slurp(File::Spec->catfile($out, 'speculative_jam_reject.s26'));
die "JAM-reaching speculative candidate was promoted\n"
   if $spec_jam =~ /^L_F203:/m ||
      $spec_jam =~ /speculative instruction island.*\nL_F203:/i;

my $spec_tia_branch = slurp(File::Spec->catfile($out, 'speculative_tia_branch_reject.s26'));
die "TIA-targeting speculative candidate was promoted\n"
   if $spec_tia_branch =~ /^L_FFD3:/m ||
      $spec_tia_branch =~ /speculative instruction island.*\nL_FFD3:/i;

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
require_re($f8_read_only, qr/0 SC writes, 0 SC RMW conflicts, 1 SC read, 0 SC paired offsets/,
   'read-only Superchip-looking access remains unpaired evidence');
die "read-only Superchip-window access hid ordinary F8 ROM bytes\n"
   if $f8_read_only =~ /sc-hidden=[1-9]/ ||
      $f8_read_only =~ /hidden by Superchip RAM window/i;

for my $case (
   ['f8_sc_write_only.s26', 'F8'],
   ['f6_sc_write_only.s26', 'F6'],
   ['f4_sc_write_only.s26', 'F4'],
) {
   my ($name, $mapper) = @$case;
   my $text = slurp(File::Spec->catfile($out, $name));
   require_re($text, qr/^; mapper: \Q$mapper\E \(/m,
      "$mapper write-only Superchip-looking access stays plain");
   require_re($text,
      qr/1 SC write, 0 SC RMW conflicts, 0 SC reads, 0 SC paired offsets/,
      "$mapper write-only evidence is recorded but not paired");
   die "$mapper write-only access incorrectly promoted Superchip\n"
      if $text =~ /^; mapper: \Q${mapper}SC\E\b/m ||
         $text =~ /sc-hidden=[1-9]/ ||
         $text =~ /hidden by Superchip RAM window/i;
}

my $sc_rmw_only = slurp(File::Spec->catfile($out, 'plain4k_sc_rmw_only.s26'));
require_re($sc_rmw_only, qr/^; mapper: unbanked 4K \(/m,
   'plain 4K RMW access in Superchip write window stays 4K');
require_re($sc_rmw_only, qr/1 SC RMW conflict/,
   'write-port RMW recorded as negative Superchip evidence');
die "RMW-only Superchip candidate hid ordinary 4K ROM bytes\n"
   if $sc_rmw_only =~ /sc-hidden=[1-9]/ ||
      $sc_rmw_only =~ /hidden by Superchip RAM window/i;

for my $case (
   ['plain4k_sc_rmw_write_conflict.s26', 'write-port'],
   ['plain4k_sc_rmw_read_conflict.s26',  'read-port'],
) {
   my ($name, $which) = @$case;
   my $text = slurp(File::Spec->catfile($out, $name));
   require_re($text, qr/^; mapper: unbanked 4K \(/m,
      "$which RMW vetoes otherwise-positive Superchip write evidence");
   require_re($text, qr/1 SC write, 1 SC RMW conflict/,
      "$which RMW conflict reported alongside SC write evidence");
   die "$which RMW conflict still promoted Superchip\n"
      if $text =~ /sc-hidden=[1-9]/ ||
         $text =~ /hidden by Superchip RAM window/i;
}

my $stella_4ksc_marker_out = slurp(File::Spec->catfile($out, 'stella_4ksc_marker.s26'));
require_re($stella_4ksc_marker_out, qr/^; mapper: 4KSC \(high confidence;/m,
   'historical Stella SC marker at $FFFA-$FFFB identifies 4KSC');
require_re($stella_4ksc_marker_out,
   qr/0 SC writes, 0 SC RMW conflicts, 0 SC reads, 0 SC paired offsets/,
   'historical Stella 4KSC marker does not require semantic SC evidence');

my $sc_write_exec = slurp(File::Spec->catfile($out, 'plain4k_sc_write_port_exec.s26'));
require_re($sc_write_exec, qr/^; mapper: unbanked 4K \(/m,
   'RESET execution in Superchip write port vetoes paired automatic 4KSC promotion');
require_re($sc_write_exec, qr/1 SC write, 0 SC RMW conflicts, 1 SC read, 1 SC paired offset/,
   'write-port execution fixture contains otherwise-positive paired SC evidence');
require_re($sc_write_exec, qr/^L_F000:
\s*STA\s+\$F020/m,
   'plain 4K write-port code remains executable ROM');
die "write-port execution conflict still hid ordinary 4K ROM bytes\n"
   if $sc_write_exec =~ /sc-hidden=[1-9]/ ||
      $sc_write_exec =~ /hidden by Superchip RAM window/i;


my $threef_out = slurp(File::Spec->catfile($out, 'threef.s26'));
require_re($threef_out, qr/^; mapper: 3F \(high confidence;/m,
   '3F mapper inferred from executable selector flow');
require_re($threef_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   '3F mapper hypotheses converge');
require_re($threef_out, qr/^B1_F100:\n\s*LDA\s+#\$02\n\s*STA\s+\$3F/m,
   '3F lower-bank selector decoded');
require_re($threef_out, qr/^B2_F104:\n\s*LDA\s+#\$42\n\s*RTS$/m,
   '3F execution resumes in value-selected 2K bank after old-bank JAM');
require_re($threef_out, qr/^B3_F900:\n\s*LDA\s+#\$01\n\s*STA\s+\$3F/m,
   '3F RESET executes from fixed final 2K bank');


my $threef_alias_out = slurp(File::Spec->catfile($out, 'threef_alias_branch.s26'));
require_re($threef_alias_out, qr/^; mapper: 3F \(/m,
   '3F alias-branch fixture keeps 3F mapping');
die "3F lower-window alias branch was mis-presented as a zero-page target\n"
   if $threef_alias_out =~ /\bBPL\.cross\s+\$0021\b/;
require_re($threef_alias_out, qr/\.byte[^\n]*\$10, \$38/i,
   '3F lower-to-fixed alias branch preserved as exact raw bytes');

my $threef32_out = slurp(File::Spec->catfile($out, 'threef32.s26'));
require_re($threef32_out, qr/^; mapper: 3F \(high confidence;/m,
   '32K 3F mapper inference');
require_re($threef32_out, qr/^; physical banks: 16 x 2048 bytes$/m,
   '32K 3F physical bank count');
require_re($threef32_out, qr/^B14_F100:\n\s*LDA\s+#\$03\n\s*STA\s+\$3F/m,
   '32K 3F high-numbered selectable bank decoded');
require_re($threef32_out, qr/^B3_F104:\n\s*LDA\s+#\$55\n\s*RTS$/m,
   '32K 3F value-selected continuation decoded');

my $threee_out = slurp(File::Spec->catfile($out, 'threee.s26'));
require_re($threee_out, qr/^; mapper: 3E \(high confidence;/m,
   '3E mapper inferred from RAM+ROM selector signature and flow');
require_re($threee_out, qr/^; mapper flow hypotheses: 12 tested, /m,
   '3E participates in 8K mapper hypothesis convergence');
require_re($threee_out, qr/^B3_F900:
\s*LDA\s+#\$02
\s*STA\s+\$3E/m,
   '3E RESET path selects external RAM bank');
require_re($threee_out, qr/STA\s+\$3F/m,
   '3E RESET path restores selectable ROM bank');
require_re($threee_out, qr/^B1_F100:
\s*LDA\s+#\$42
\s*RTS$/m,
   '3E execution enters restored lower ROM bank');
require_re($threee_out, qr/^; 3E cartridge RAM: /m,
   '3E split-RAM alias description emitted');

my $forced_threee_rmw_s26 = File::Spec->catfile($tmp, 'forced_threee_rmw.s26');
run_ok($disas, '--mapper', '3e', '-o', $forced_threee_rmw_s26,
   File::Spec->catfile($in, 'threee_rmw.bin'));
my $forced_threee_rmw = slurp($forced_threee_rmw_s26);
require_re($forced_threee_rmw,
   qr/^; mapper: 3E \(override;.*1 native split-RAM RMW conflict\)/m,
   '3E RMW against selected RAM read alias recorded as contradiction');

my $fe_out = slurp(File::Spec->catfile($out, 'fe_flow.s26'));
require_re($fe_out, qr/^; mapper: FE \(high confidence;/m,
   'FE mapper inferred from canonical SCABS call signature and executable flow');
require_re($fe_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   'FE mapper hypotheses converge');
require_re($fe_out, qr/^B0_F100:\n\s*LDX\s+#\$FF\n\s*TXS\n\s*JSR\s+\$D000/m,
   'FE RESET path contains canonical JSR switching idiom');
require_re($fe_out, qr/^B1_D000:\n\s*LDA\s+#\$55\n\s*RTS$/m,
   'FE JSR target executes from selected physical bank');
require_re($fe_out, qr/DEC\s+\$C5\n\s*LDA\s+#\$42\n\s*RTS/m,
   'FE RTS returns to caller continuation in original bank');
require_re($fe_out, qr/^; FE\/SCABS switching:/m,
   'FE hardware semantics documented in generated source');

my $e7_8k_out = slurp(File::Spec->catfile($out, 'e7_8k.s26'));
require_re($e7_8k_out, qr/^; mapper: E7 \(high confidence;/m,
   '8K E7 mapper inferred');
require_re($e7_8k_out,
   qr/^; physical banks: 4 x 2048 bytes$/m,
   '8K E7 physical layout');
require_re($e7_8k_out,
   qr/^B3_FA00:\n\s*LDA\s+B3_FFE5\n\s*JMP\s+\$F100/m,
   '8K E7 fixed-ROM selector routine decoded');
require_re($e7_8k_out, qr/^B1_F100:\n\s*LDA\s+#\$42\n\s*RTS$/m,
   '8K E7 selected lower ROM bank decoded');

my $e7_12k_out = slurp(File::Spec->catfile($out, 'e7_12k.s26'));
require_re($e7_12k_out, qr/^; mapper: E7 \(high confidence;/m,
   '12K E7 mapper inferred');
require_re($e7_12k_out, qr/^; physical banks: 6 x 2048 bytes$/m,
   '12K E7 physical layout');
require_re($e7_12k_out,
   qr/^B5_FA00:\n\s*LDA\s+B5_FFE2\n\s*LDA\s+B5_FFE6\n\s*JMP\s+\$F100/m,
   '12K E7 selector alias table decoded');
require_re($e7_12k_out, qr/^B4_F100:\n\s*LDA\s+#\$43\n\s*RTS$/m,
   '12K E7 selected lower ROM bank decoded');

my $e7_16k_out = slurp(File::Spec->catfile($out, 'e7_16k.s26'));
require_re($e7_16k_out, qr/^; mapper: E7 \(high confidence;/m,
   '16K E7 mapper inferred');
require_re($e7_16k_out, qr/^; physical banks: 8 x 2048 bytes$/m,
   '16K E7 physical layout');
require_re($e7_16k_out, qr/^; E7 RAM aliases:/m,
   'E7 split-RAM aliases documented');
require_re($e7_16k_out, qr/^B5_F100:\n\s*LDA\s+#\$44\n\s*RTS$/m,
   '16K E7 execution reaches selected lower ROM bank after RAM use');

my $forced_e7_rmw_s26 = File::Spec->catfile($tmp, 'forced_e7_rmw.s26');
run_ok($disas, '--mapper', 'e7', '-o', $forced_e7_rmw_s26,
   File::Spec->catfile($in, 'e7_rmw.bin'));
my $forced_e7_rmw = slurp($forced_e7_rmw_s26);
require_re($forced_e7_rmw,
   qr/^; mapper: E7 \(override;.*2 native split-RAM RMW conflicts\)/m,
   'E7 lower and fixed RAM RMW aliases recorded as contradictions');

my $f8_false_ua_out = slurp(File::Spec->catfile($out, 'f8_false_ua_flow.s26'));
require_re($f8_false_ua_out, qr/^; mapper: F8 \(/m,
   'control-flow inference rejects accidental UA byte signature');
require_re($f8_false_ua_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   'false-UA mapper hypotheses converge');
require_re($f8_false_ua_out, qr/CPX\s+#\$2C\n\s*BCS\.same\s+/m,
   'accidental 2C B0 0F sequence remains ordinary decoded F8 code');
require_re($f8_false_ua_out, qr/BCS\.same\s+\$F115.*\n\s*LDA\s+\$1FF9/m,
   'F8 selector remains on established RESET execution path');
require_re($f8_false_ua_out, qr/B1_F109:\n\s*LDA\s+#\$42/m,
   'F8 execution continues in successor bank after selector');

my $f8_raw_ua_data_out = slurp(File::Spec->catfile($out, 'f8_raw_ua_data.s26'));
require_re($f8_raw_ua_data_out, qr/^; mapper: F8 \(/m,
   'raw UA signature in data cannot override established narrow F8 switching');
require_re($f8_raw_ua_data_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   'raw-UA-data F8 mapper hypotheses converge');
require_re($f8_raw_ua_data_out, qr/B0_F100:\n\s*LDA\s+\$1FF9/m,
   'raw-UA-data fixture retains established F8 selector');
require_re($f8_raw_ua_data_out, qr/B1_F103:\n\s*LDA\s+#\$42/m,
   'raw-UA-data fixture continues in selected F8 bank');

my $f8_branch_edge_out = slurp(File::Spec->catfile($out, 'f8_branch_edge_flags.s26'));
require_re($f8_branch_edge_out, qr/^; mapper: F8 \(/m,
   'branch-edge flag refinement preserves valid F8 mapper hypothesis');
require_re($f8_branch_edge_out, qr/LDA\s+INTIM\n\s*BMI\.same\s+\$F103.*\n\s*BPL\.same\s+\$F10B/m,
   'mutually exhaustive BMI/BPL path remains executable');
die "impossible BMI/BPL fallthrough JAM was decoded as reachable code\n"
   if $f8_branch_edge_out =~ /B0_F10A:\n\s*op02/m;

my $f8_cross_jam_out = slurp(File::Spec->catfile($out, 'f8_cross_switch_possible_jam.s26'));
require_re($f8_cross_jam_out, qr/^; mapper: F8 \(/m,
   'real F8 cross-bank selector outranks possible abstract-state JAM path');
require_re($f8_cross_jam_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   'cross-bank F8 evidence eliminates zero-switch E0 hypothesis');
require_re($f8_cross_jam_out, qr/B1_F100:\n\s*LDA\s+\$1FF8/m,
   'F8 cross-bank evidence begins on RESET path');

my $static_branch_jam_out = slurp(File::Spec->catfile($out, 'static_branch_unobserved_jam.s26'));
require_re($static_branch_jam_out,
   qr/^; static branch confidence: checked=\d+ concrete-edges=\d+ rejected=[1-9]\d* rejected-halt=[1-9]\d* inconclusive=\d+$/m,
   'never-observed static JAM arm is rejected by confidence gate');
require_re($static_branch_jam_out, qr/LDA\s+\$80\n\s*BEQ\.same\s+\$F105/m,
   'concrete branch arm remains established');
die "never-observed direct JAM branch arm became established code\n"
   if $static_branch_jam_out =~ /F104:\n\s*op02/m;

my $static_branch_jmp_jam_out = slurp(File::Spec->catfile($out, 'static_branch_unobserved_jmp_jam.s26'));
require_re($static_branch_jmp_jam_out,
   qr/^; static branch confidence: .*rejected=[1-9]\d* rejected-halt=[1-9]\d*/m,
   'unobserved static arm follows JMP through to JAM before rejection');
die "JMP-to-JAM branch arm became established code\n"
   if $static_branch_jmp_jam_out =~ /JMP\s+\$F110/;

my $static_branch_hotspot_out = slurp(File::Spec->catfile($out, 'static_branch_hotspot_avoids_jam.s26'));
require_re($static_branch_hotspot_out, qr/^; mapper: F8 \(/m,
   'hotspot branch confidence fixture remains F8');
require_re($static_branch_hotspot_out, qr/BEQ\.same\s+\$F109.*\n\s*LDA\s+\$1FF8/ms,
   'unobserved static arm containing F8 selector remains established');
require_re($static_branch_hotspot_out, qr/B0_F107:\n\s*RTS$/m,
   'static branch validator follows selector into successor F8 bank');
die "old-bank JAM after hotspot was incorrectly established\n"
   if $static_branch_hotspot_out =~ /B1_F107:\n\s*op02/m;

my $uasw_flow_out = slurp(File::Spec->catfile($out, 'uasw_flow_only.s26'));
require_re($uasw_flow_out, qr/^; mapper: UASW \(/m,
   'control-flow inference distinguishes UASW from UA and F8');
require_re($uasw_flow_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   'UASW mapper hypotheses converge');
require_re($uasw_flow_out, qr/B0_F100:\n\s*LDA\s+\$0220/m,
   'UASW selector decoded on RESET path');
require_re($uasw_flow_out, qr/B1_F103:\n\s*RTS$/m,
   'UASW successor-bank continuation decoded');


my $ua_raw_variant_out = slurp(File::Spec->catfile($out, 'ua_raw_variant.s26'));
require_re($ua_raw_variant_out, qr/^; mapper: UA \(/m,
   'raw UA-family signature plus mapper flow selects ordinary UA polarity');
require_re($ua_raw_variant_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   'ordinary UA variant evidence removes unsigned competing 8K hypotheses');
require_re($ua_raw_variant_out, qr/B1_F103:\n\s*RTS$/m,
   'ordinary UA selector continues in bank 1');

my $uasw_raw_variant_out = slurp(File::Spec->catfile($out, 'uasw_raw_variant.s26'));
require_re($uasw_raw_variant_out, qr/^; mapper: UASW \(/m,
   'raw UA-family signature plus mapper flow selects swapped UASW polarity');
require_re($uasw_raw_variant_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   'UASW variant evidence removes unsigned competing 8K hypotheses');
require_re($uasw_raw_variant_out, qr/B1_F105:\n\s*RTS$/m,
   'UASW indexed selector continues in bank 1');

my $e0_flow_out = slurp(File::Spec->catfile($out, 'e0_flow_only.s26'));
require_re($e0_flow_out, qr/^; mapper: E0 \(/m,
   'E0 segmented mapper inferred from executable flow');
require_re($e0_flow_out,
   qr/^; mapper flow hypotheses: 12 tested, 1 survived; control flow refined selection$/m,
   'E0 RESET-path mapper hypotheses converge');
require_re($e0_flow_out, qr/B4_F100:\n\s*LDA\s+\$FFE0/m,
   'E0 selector decoded in default physical bank 4');
require_re($e0_flow_out, qr/B0_F103:\n\s*LDA\s+\$FFE9\n\s*LDA\s+#\$42/m,
   'E0 execution resumes from newly selected physical bank');

my $e0_spec_out = slurp(File::Spec->catfile($out, 'e0_speculative_banked_island.s26'));
require_re($e0_spec_out, qr/^; mapper: E0 \(/m,
   'E0 speculative-island mapper inferred');
require_re($e0_spec_out,
   qr/^; mapper flow hypotheses: 12 tested, 3 survived$/m,
   'E0 speculative selector traffic excluded from mapper ranking');
require_re($e0_spec_out,
   qr/^; mapper: E0 \(high confidence; 0 decoded hotspot accesses,/m,
   'E0 raw signature may identify mapper without speculative semantic votes');
require_re($e0_spec_out,
   qr/speculative instruction island validated by HLT\/JAM\/KIL rejection\nB4_F203:\n\s*LDA\s+\$FFE0/m,
   'E0 speculative island may switch away from old-bank JAM');
require_re($e0_spec_out, qr/B0_F206:\n\s*LDA\s+\$FFE9\n\s*LDA\s+#\$42/m,
   'E0 speculative execution resumes in selected physical bank');

my $f8sc = slurp(File::Spec->catfile($out, 'f8sc.s26'));
require_re($f8sc, qr/^; mapper: F8SC\b/m, 'F8SC mapper inference');
require_re($f8sc, qr/1 SC write, 0 SC RMW conflicts, 1 SC read, 1 SC paired offset/,
   'F8SC semantic inference requires paired write/read alias evidence');
require_re($f8sc, qr/physical ROM bytes hidden by Superchip RAM window/i,
   'Superchip-hidden physical ROM annotation');
require_re($f8sc, qr/^; usage bytes: .*sc-hidden=512\b/m,
   'F8SC hidden-byte accounting');
my $f6_jane_tie_out = slurp(File::Spec->catfile($out, 'f6_jane_exit_tie.s26'));
require_re($f6_jane_tie_out, qr/^; mapper: F6 \(medium confidence;/m,
   'F6/JANE ambiguity does not reward truncated control flow');
require_re($f6_jane_tie_out,
   qr/^; mapper flow hypotheses: 6 tested, 1 survived; control flow refined selection$/m,
   'JANE requires positive family evidence instead of mere coherent startup flow');


my $f6_jane_no_evidence_out =
   slurp(File::Spec->catfile($out, 'f6_jane_no_evidence_rescue.s26'));
require_re($f6_jane_no_evidence_out, qr/^; mapper: F6 \(medium confidence;/m,
   'coherent JANE startup bank cannot rescue an evidence-free 16K image');
require_re($f6_jane_no_evidence_out,
   qr/^; mapper flow hypotheses: 6 tested, 0 survived$/m,
   'evidence-free JANE hypothesis is not viable merely because F6 halts');


my $f6sc_out = slurp(File::Spec->catfile($out, 'f6sc.s26'));
require_re($f6sc_out, qr/^; mapper: F6SC\b/m, 'F6SC mapper inference');
require_re($f6sc_out, qr/1 SC write, 0 SC RMW conflicts, 1 SC read, 1 SC paired offset/,
   'F6SC semantic inference requires paired write/read alias evidence');
my $f6sc_layout_out = slurp(File::Spec->catfile($out, 'f6sc_layout.s26'));
require_re($f6sc_layout_out, qr/^; mapper: F6SC\b/m,
   'F6SC duplicated-window structural inference');
require_re($f6sc_layout_out, qr/^; Superchip structural evidence: /m,
   'F6SC structural evidence annotation');
require_re($f6sc_layout_out, qr/\b0 SC writes\b/,
   'F6SC structural inference does not invent store evidence');
my $f8sc_signature_out = slurp(File::Spec->catfile($out, 'f8sc_signature.s26'));
require_re($f8sc_signature_out, qr/^; mapper: F8SC\b/m,
   'explicit VCSC F8SC tail signature is authoritative');
require_re($f8sc_signature_out,
   qr/0 SC writes, 0 SC RMW conflicts, 0 SC reads, 0 SC paired offsets/,
   'explicit F8SC signature does not require invented semantic evidence');
my $f4sc_out = slurp(File::Spec->catfile($out, 'f4sc.s26'));
require_re($f4sc_out, qr/^; mapper: F4SC\b/m, 'F4SC mapper inference');
require_re($f4sc_out, qr/1 SC write, 0 SC RMW conflicts, 1 SC read, 1 SC paired offset/,
   'F4SC semantic inference requires paired write/read alias evidence');


# Concrete execution must not turn a weak size-default banked mapper guess into
# positive reachability evidence. Unsupported 32K layouts (for example OMNI)
# can survive the current static F4 hypothesis by coincidence; emulating them
# as F4 would manufacture thousands of bogus instruction starts. An explicit
# --mapper remains a deliberate opt-in to the concrete F4 bus model.
my $f4_out = slurp(File::Spec->catfile($out, 'f4.s26'));
die "weak automatic F4 guess unexpectedly ran concrete discovery\n"
   if $f4_out =~ /^; concrete RESET discovery:/m;
my $forced_f4_concrete_s26 = File::Spec->catfile($tmp, 'forced_f4_concrete.s26');
run_ok($disas, '--mapper', 'f4', '-o', $forced_f4_concrete_s26,
   File::Spec->catfile($in, 'f4.bin'));
my $forced_f4_concrete = slurp($forced_f4_concrete_s26);
require_re($forced_f4_concrete, qr/^; concrete RESET discovery:/m,
   'explicit F4 mapper enables concrete discovery');


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
my $video_dynamic_ntsc = slurp(File::Spec->catfile($out, 'video_dynamic_60hz.s26'));
require_re($video_dynamic_ntsc,
   qr/^; video: NTSC \(dynamic stable frame measurement: 262 raw line intervals\) \(high confidence\)$/m,
   'dynamic NTSC frame measurement');
my $video_dynamic_pal = slurp(File::Spec->catfile($out, 'video_dynamic_50hz.s26'));
require_re($video_dynamic_pal,
   qr/^; video: PAL-family \(PAL\/SECAM ambiguous; dynamic stable frame measurement: 312 raw line intervals\) \(high confidence\)$/m,
   'dynamic PAL-family frame measurement');
my $video_dynamic_secam = slurp(File::Spec->catfile($out, 'video_dynamic (SECAM).s26'));
require_re($video_dynamic_secam,
   qr/^; video: SECAM \(filename hint; dynamic 312-interval 50 Hz confirmation\) \(medium confidence\)$/m,
   'dynamic 50 Hz measurement preserves SECAM filename distinction');
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
require_re($help, qr/--table/, 'help generic table hint');
require_re($help, qr/--pointer/, 'help pointer table hint');
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

# Manual table/pointer presentation fills the last Item-13 hint gap.  The
# pointer table has no automatic builder, so only --pointer may promote it to
# .word form.  A second pointer hint deliberately overlaps executable bytes;
# code remains primary while the non-exclusive data role is retained.
my $manual_s26 = File::Spec->catfile($tmp, 'manual_hints.s26');
my $manual_hex = File::Spec->catfile($tmp, 'manual_hints.hex');
run_ok($disas,
   '--pointer', '0:0xF200-0xF205',
   '--table', '0:0xF300-0xF30F',
   '--pointer', '0:0xF100-0xF101',
   '-o', $manual_s26, File::Spec->catfile($in, 'manual_hints.bin'));
my $manual_text = slurp($manual_s26);
require_re($manual_text, qr/manual little-endian pointer table hint/i,
   'forced pointer-table presentation');
require_re($manual_text, qr/^L_F200:\n\s*; manual little-endian pointer table hint\n\s*\.word L_F100\n\s*\.word L_F100\n\s*\.word L_F100/m,
   'forced pointer-table words');
require_re($manual_text, qr/manual generic data-table hint/i,
   'forced generic-table presentation');
require_re($manual_text, qr/^L_F300:\n\s*\.byte \$00, \$01, \$02, \$03/m,
   'forced generic table bytes');
require_re($manual_text,
   qr/manual pointer-table data role; primary code\/vector\/raw representation preserved.*\n.*L_F100:.*\n\s*LDA\s+#\$42/is,
   'pointer role overlapping executable code');
run_ok($as, "--hex=$manual_hex", $manual_s26);

my $odd_pointer = `$disas --pointer 0:0xF200-0xF204 "@{[File::Spec->catfile($in, 'manual_hints.bin')]}" 2>&1`;
die "odd-length pointer hint unexpectedly succeeded\n" if $? == 0;
require_re($odd_pointer, qr/even number of bytes/, 'odd pointer-range diagnostic');
my $overlap_hints = `$disas --table 0:0xF200-0xF203 --pointer 0:0xF202-0xF205 "@{[File::Spec->catfile($in, 'manual_hints.bin')]}" 2>&1`;
die "overlapping table/pointer hints unexpectedly succeeded\n" if $? == 0;
require_re($overlap_hints, qr/overlapping manual table\/pointer hint/, 'overlapping hint diagnostic');

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
my $bad_1k_layout = `$disas --mapper 1k "@{[File::Spec->catfile($in, 'plain2k.bin')]}" 2>&1`;
die "2K image unexpectedly accepted as forced 1K\n" if $? == 0;
require_re($bad_1k_layout, qr/incompatible with 2048-byte input/,
   'forced 1K rejects non-1K layout');
my $bad_fc_layout = `$disas --mapper fc "@{[File::Spec->catfile($in, 'fa.bin')]}" 2>&1`;
die "12K image unexpectedly accepted as forced FC\n" if $? == 0;
require_re($bad_fc_layout, qr/incompatible with 12288-byte input/,
   'forced FC rejects unsupported 12K layout');
my $bad_wd_layout = `$disas --mapper wd "@{[File::Spec->catfile($in, 'wdsw_bad_dump.bin')]}" 2>&1`;
die "8195-byte WDSW layout unexpectedly accepted as forced WD\n" if $? == 0;
require_re($bad_wd_layout, qr/incompatible with 8195-byte input/, 'forced WD rejects WDSW layout');
my $bad_wdsw_layout = `$disas --mapper wdsw "@{[File::Spec->catfile($in, 'wd.bin')]}" 2>&1`;
die "8192-byte WD layout unexpectedly accepted as forced WDSW\n" if $? == 0;
require_re($bad_wdsw_layout, qr/incompatible with 8192-byte input/, 'forced WDSW rejects WD layout');
my $bad_ar_layout = `$disas --mapper ar "@{[File::Spec->catfile($in, 'plain4k.bin')]}" 2>&1`;
die "4K image unexpectedly accepted as forced AR\n" if $? == 0;
require_re($bad_ar_layout, qr/incompatible with 4096-byte input/,
   'forced AR rejects non-8448-multiple layout');
my $bad_origin = `$disas --origin 0:0xD001 "@{[File::Spec->catfile($in, 'plain4k.bin')]}" 2>&1`;
die "misaligned origin override unexpectedly succeeded\n" if $? == 0;
require_re($bad_origin, qr/not a valid page-aligned cartridge origin/, 'origin alignment diagnostic');

my $empty = File::Spec->catfile($tmp, 'empty.bin');
write_bin($empty, '');
my $empty_out = File::Spec->catfile($tmp, 'empty.s26');
system($disas, '-o', $empty_out, $empty);
die "empty input unexpectedly succeeded\n" if $? == 0;

print "vcsc-disas regression suite ok\n";
