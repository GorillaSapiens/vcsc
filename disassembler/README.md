```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# vcsc-disas

`vcsc-disas` is the VCSC Atari 2600/6507 cartridge disassembler. It reads a
raw cartridge `.bin` and writes VCSC assembler source (`.s26`) that is intended
to reconstruct the original cartridge **byte for byte** with `vcsc-as`.

Exact reconstruction outranks pretty output. When an interpretation is not
safe, the disassembler emits the original bytes with `.byte` rather than
inventing code or data semantics.

## Basic use

```sh
./disassembler/vcsc-disas game.bin
./disassembler/vcsc-disas -o game.s26 game.bin
./assembler/vcsc-as --hex=game.hex game.s26
```

Without `-o`, `game.bin` produces `game.s26`. `-o -` writes assembly to
standard output. Use `--help` for the complete current option list and `-V` or
`--version` for build/version information.

`vcsc-as` direct assembly currently writes Intel HEX rather than a raw cartridge
file. The development utility described below performs that flattening and the
exact comparison automatically.

## Analysis overrides and hints

Inference is deliberately conservative. When a ROM uses information the static
analyzer cannot recover, command-line hints can supply it without editing the
generated source:

```sh
./disassembler/vcsc-disas \
    --mapper f8sc \
    --origin 0:0xD000 --origin 1:0xF000 \
    --reset-bank 1 \
    --entry 0:0xD234 \
    --data 0:0xD800-0xD8FF \
    --pointer 0:0xD900-0xD91F \
    --table 0:0xDA00-0xDA3F \
    --video ntsc --controller0 joystick --controller1 paddles \
    game.bin
```

Supported mapper overrides are `2k`, `4k`, `f8`, `f8sc`, `f6`, `f6sc`,
`f4`, `f4sc`, `fa`, `dpc`, `wd`, `cv`, `jane`, `0840`, `ua`, and `uasw`. `--origin BANK:ADDRESS`, `--entry BANK:ADDRESS`,
`--code BANK:START-END`, `--data BANK:START-END`, `--table BANK:START-END`, and
`--pointer BANK:START-END` are repeatable. The bank may be omitted for a one-bank
cartridge. Numbers accept decimal, `0x` hex, or `$` hex; quote `$` forms in a
shell so the shell does not treat them as variable references.

`--code` asserts a linear instruction range even across `RTS`/`JMP`; `--entry`
adds an ordinary recursive-control-flow seed. `--data` is a definite data-role
hint without prescribing presentation. `--table` additionally establishes a
named generic byte-table boundary and suppresses conflicting automatic pretty
printing in that range. `--pointer` declares an even-length little-endian pointer
table and emits `.word` entries when doing so cannot hide established code,
vectors, or an odd-byte label. All data/table/pointer roles are non-exclusive:
the same bytes may still be executable code, in which case executable source is
kept as the primary physical representation. Contradictory mapper sizes, invalid
banks, misaligned origins, truncated forced instructions, odd pointer ranges,
overlapping manual table/pointer presentations, and out-of-window ranges are
errors rather than guesses.

`--video` and `--controller0`/`--controller1` override only advisory generated
metadata. `--verbose` adds detailed evidence counts without changing the emitted
bytes. Run `vcsc-disas --help` for the authoritative current option list.

## What the generated source preserves

For supported ordinary Atari layouts, generated source separates physical ROM
position from runtime 6507 addresses:

```asm
.org $0000
.rorg $F000
    ...
.rend
```

The disassembler currently recognizes unbanked 2K/4K, the F8/F6/F4 family
(with Superchip evidence reported as 4KSC/F8SC/F6SC/F4SC), CBS RAM Plus / FA, CommaVid CV, JANE, 0840/EconoBanking, UA/UASW, DPC,
and Wickstead Design / WD. Standard DPC
images are recognized by their distinctive 10240- or 10495-byte layout: two
4K F8-style program banks followed by 2K of DPC data ROM, with the 10495-byte
form carrying an additional 255-byte RNG table.

WD is the custom Pursuit of the Pink Panther mapper. It uses eight 1K ROM banks
and eight fixed four-segment arrangements selected by reads from TIA `$30-$3F`.
The cartridge also contains 64 bytes of RAM, read at `$1000-$103F` and written
at `$1040-$107F`. The known 8195-byte preservation dump is recognized directly:
for runtime analysis its 1K banks 2 and 3 are interpreted in the corrected order
used by Stella, while source emission keeps the original physical file order and
retains the three non-emulated trailing bytes so round trip remains exact. A
corrected 8192-byte image can be forced with `--mapper wd`.

A run that discovers zero instructions is an error. `vcsc-disas` does not call a
100%-`.byte` dump a successful disassembly; unsupported/raw layouts therefore
fail unless future mapper support or explicit analysis can establish executable
code. Raw `.byte` emission remains the exactness fallback for uncertain regions
inside an otherwise successful disassembly.

The generated header records the input size and SHA-256, mapper evidence,
physical banks, inferred bank origins and reset bank, video/controller evidence,
and the `vcsc-disas` version.

Graphics-oriented data is rendered one byte per line as `%00110100` with a
matching X/dot picture when the analysis has strong evidence. Besides direct
GRP/PF provenance, the detector recognizes common indirect animation pointers
built from a ROM low-byte table plus a constant high byte and can infer frame
height from a constant low-byte stride. It also recognizes long, coherent,
aligned 8x8 font runs structurally; a lone bitmap-looking object is not enough
to trigger that fallback. Pitfall's eight 22-row Harry frames and its decimal
font are regression cases for these two paths.

For Superchip variants, the physical bytes occupying the first `$100` bytes of
each 4K bank are preserved exactly but annotated as hidden by the Superchip RAM
window rather than decoded as ROM. The hardware maps `$1000-$107F` as the RAM
write port and `$1080-$10FF` as its read port, so those dump bytes are not
ordinary runtime ROM.

FA is the historical CBS RAM Plus 12K layout: three 4K banks selected at
`$1FF8-$1FFA`, with physical bank 2 selected at power-on. Its 256 bytes of
cartridge RAM use write `$1000-$10FF` and read `$1100-$11FF`, so the first
`$200` physical bytes of each 4K bank are preserved in the output but excluded
from executable-ROM and ROM-data discovery. Because the 6507 exposes only 13
address pins, FA bank origins such as `$3000`, `$5000`, and `$7000` are valid
mirrors; origin inference must not force every bank to `$F000`.

CV is the fixed CommaVid 2K layout. Its ROM occupies only logical
`$F800-$FFFF`; the lower half of the cartridge window is 1K of RAM read at
`$F000-$F3FF` and written at `$F400-$F7FF`. `vcsc-disas` recognizes VCSC's
`CV\0\0` tail signature and the established indexed-write instruction
patterns used for legacy CV detection. CV RAM addresses are excluded from ROM
code/data discovery, and a generated CV disassembly round-trips as an exact
2048-byte image.

JANE is a 16K four-bank layout with selectors `$1FF0`, `$1FF1`, `$1FF8`, and
`$1FF9` selecting physical/file banks 0, 1, 2, and 3. Physical bank 1 is the
hardware power-on bank. `vcsc-disas` recognizes either VCSC's `JANE` tail
signature or the established `LDA $FFF1; RTS` detector byte pattern, reports
the nonstandard power-on bank explicitly, and preserves physical file order on
round trip. `--mapper jane` forces the same interpretation.

Automatic Superchip promotion requires a decoded write to the `$x000-$x07F`
write window. A read from `$x080-$x0FF` alone is not sufficient evidence, because
a plain F8/F6/F4 cartridge may legitimately read ordinary ROM at the same bus
addresses. `--mapper f8sc|f6sc|f4sc` remains available when static control-flow
analysis cannot observe the initializing RAM write.
0840/EconoBanking is an 8K two-bank layout whose selectors live below the
cartridge window. `vcsc-disas` recognizes the VCSC `0840` tail signature or the
legacy hotspot-access patterns used by current emulator detectors. It reports
physical bank 0 as power-on, decodes the `$0800/$0840` selector families, and
round-trips VCSC-generated 0840 images byte-exactly.

UA and UASW are 8K two-bank layouts with alias-decoded selectors below the
cartridge window. UA uses `(A & $1260)==$0220` for bank 0 and `==$0240` for bank
1; UASW swaps those associations. `vcsc-disas` recognizes VCSC's `UA\0\0`
and `UASW` tail signatures, and also recognizes the established UA access
patterns as UA when no explicit swapped signature is present. Both report
physical bank 0 as power-on and round-trip byte-exactly.


Conditional branches are always emitted with the VCSC timing contract
`.same` or `.cross`. Their operand is the exact numeric runtime target; when a
generated target label exists it is repeated in a comment. Keeping the branch
operand numeric avoids a forward-label relaxation edge in `vcsc-as` at the top
of the legal short-branch range while preserving the original two-byte opcode
and page contract exactly. Addressing-mode suffixes are emitted only when they are needed to preserve the
original opcode encoding. Ordinary named instructions omit redundant `.z`, `.zx`,
and `.zy` suffixes because `vcsc-as` naturally selects zero page for resolved
8-bit operands. Conversely, `.a`, `.ax`, or `.ay` is retained when an originally
wide operand is below `$0100` and would otherwise relax to zero page. Raw `opXX`
spellings keep explicit mode suffixes because the assembler requires them for
ambiguous operand shapes.

## Hardware symbols and mirrors

Recognized TIA and RIOT accesses use the canonical VCSC names (`COLUBK`,
`GRP0`, `SWCHA`, `TIM64T`, and so on). Generated files contain the equates they
actually use, so they remain self-contained for the existing assembler.

A noncanonical mirrored access keeps the exact encoded operand and names the
register the hardware really selects, for example:

```asm
    STA COLUBK + $0100      ; mirror of COLUBK ($0009)
```

The mirror is never normalized to a different address merely to look nicer.

## Deliberately tricky 6502 code

Code/data roles are non-exclusive. The analyzer permits:

- instruction bytes or operands that are also read as data;
- branch/JMP/JSR targets entering the middle of another reachable instruction;
- multiple executable interpretations of the same physical bytes;
- ROM bytes that are neither reached as code nor found by the current data-read
  analysis.

For the classic BIT-skip trick, the outer byte can therefore be emitted raw
while the alternate entry is emitted as a real instruction:

```asm
    .byte $2C
alternate:
    LDX #$02
```

This is a general overlapping-stream rule, not a special `$2C` decoder hack.

Unreferenced regions normally remain exact data rather than being force-decoded
simply because random bytes happen to form legal 6502 opcodes. A conservative
second pass tests unknown instruction starts as speculative islands: if any
statically possible path reaches a newly speculative HLT/JAM/KIL, that start is
rejected. Three consecutive rejected starts form a sequential-flow barrier.
When all three failures reach JAM/KIL through straight-line fallthrough, the
furthest halt also gives a conservative end for that non-code span. A candidate
after that span is promoted only if it also passes `stego`-style credibility
checks (coherent multi-instruction flow, mostly official opcodes, no conflicts
with established code/data, and a credible terminal/join). Established
vectors/JMPs/JSRs and intentional reachable JAM/KIL always override this negative
evidence.

Known C/Z/N/V flag state is used to prune impossible branch arms before deciding
that a halt is reachable. Speculative walks are bounded; a candidate that exceeds
the analysis budget stays inconclusive/raw rather than being guessed. The generated
header reports rejected-start, barrier, and promoted-island counts.

## Sprite/font rows

When a ROM table has strong graphics provenance--for example a ROM load into
A/X/Y whose value reaches `GRP0`, `GRP1`, `PF0`, `PF1`, or `PF2` along a short
straight-line dependency path--raw bytes are written one row per line. The
analysis follows register transfers and simple ALU/accumulator-shift transforms,
and recognizes `STA`, `STX`, and `STY` graphics writes. The assembler's actual binary
literal syntax is `%` followed by zeroes and ones, so the X/dot picture is kept
as a comment rather than inventing new assembler syntax:

```asm
    .byte %00111100    ; ..XXXX..
    .byte %01100110    ; .XX..XX.
```

Countdown-indexed loops are used when possible to prove the table length;
otherwise a runtime-indexed table is conservatively bounded by the next known
code/vector/label boundary. Calls, branches, unknown raw opcodes, and unrelated
loads stop provenance, so random tables and call-mediated/compressed-looking data
stay in ordinary numeric form unless stronger evidence exists.

## Labels, tables, vectors, and analysis comments

Definite control-flow and ROM-data targets receive deterministic labels. In
banked cartridges labels are bank-qualified so equal runtime addresses in
different physical banks remain unambiguous. References into an emitted
instruction operand or vector word use the containing label plus an exact byte
offset rather than inventing a label that cannot be placed in the source.

The normal output keeps table recognition conservative:

- a probable little-endian pointer table requires at least three consecutive
  exact in-bank pointers, evidence that the table bytes are referenced as ROM
  data, and independent semantic evidence for every target; the table is not
  allowed to create its own credibility, and accepted words are emitted as
  symbolic `.word` values;
- a probable TIA color table requires an indexed ROM load whose value can be
  followed through a short straight-line dependency chain into `COLUP0`,
  `COLUP1`, `COLUPF`, or `COLUBK`; palette-looking bytes alone are not enough;
- graphics/font tables retain the stricter provenance/structural rules described
  above.

Normal source comments call out definite/possible ROM-data targets, code bytes
that are also read as data, overlapping executable streams, unreferenced runs,
and dynamic control-flow exits. `--verbose` adds the heavier inference evidence
and usage accounting; ordinary output remains intentionally quieter.

Vector words are emitted symbolically only when doing so preserves the original
16-bit value exactly. If either vector byte is executable, instruction emission
wins and a comment records the vector value instead of hiding executable bytes
inside a `.word`.

## Video and controller inference

Inference comments are evidence, not metadata injected into the cartridge.
Static video recognition understands both the maintained VCSC RIOT timer
signatures and conventional counted-`WSYNC` frame loops. The `42/34` timer pair
is strong NTSC evidence and `52/41` is strong 50-Hz PAL-family evidence; counted
3/37/192/30 and 3/45/228/36 scanline phases provide corresponding evidence for
software that does not use RIOT frame timers.

When established code writes VSYNC, `vcsc-disas` also runs a bounded dynamic
frame probe using the same MOS 6502 core as `vcsc-sim`. The probe models the
6507 address mirror, RIOT RAM/timers, TIA VSYNC/WSYNC stalls, neutral controller
inputs, the supported F8/F6/F4/FA bank hotspots, and Superchip/FA RAM windows.
Several consecutive VSYNC rises must settle to a stable frame period before the
dynamic result is accepted. The reported measurement is in **raw 76-cycle line
intervals**, not Stella display scanlines: for example, VCSC's calibrated frame
schedulers intentionally produce 264/314 raw harness intervals while Stella
reports 262/312 displayed scanlines. Dynamic execution is skipped for DPC and WD
until their cartridge-specific coprocessor/segmented-mapper behavior has a faithful
probe model; static evidence remains available there.

A stable 60-Hz-family measurement is reported as NTSC. A stable 50-Hz result is
reported as PAL/SECAM ambiguous because timing cannot distinguish those two
standards. Explicit PAL/SECAM filename tokens (including `pal50`/`secam50`) may
name the likely member of the already-confirmed 50-Hz family, but that
distinction remains medium-confidence metadata evidence rather than something
the frame timing proved. `--video` is authoritative when the user knows better.

Current controller recognition looks for conservative register-access patterns
used by the VCSC joystick, paddle, keypad, and driving-controller support. When
register use is insufficient to distinguish devices, the header says so rather
than making a forced guess.

## Corpus round-trip verifier

`roundtrip.pl` is a standalone development tool, intentionally outside the
normal `test/` directory:

```sh
perl disassembler/roundtrip.pl INPUT_DIR OUTPUT_DIR
```

It processes every direct `.bin` in `INPUT_DIR` in lexical order. For each ROM
it keeps `NAME.s26` and a reconstructed `NAME.bin` in `OUTPUT_DIR`, prints the
original and reconstructed MD5 values, and also performs an exact size/byte
comparison. It continues after individual failures and exits nonzero unless the
entire corpus passes.

Input and output directories may not alias. Filenames are passed to child
processes without shell interpolation.

A successful corpus run is the easiest end-to-end proof: the script runs
`vcsc-disas`, runs `vcsc-as`, flattens assembler Intel HEX back to raw bytes,
prints both MD5 values, and performs an exact size/byte comparison equivalent to
`cmp`.

The repository hardening gates go further than the standalone verifier. All
85 editable VCSC example ROMs are round-tripped inside the eight normal
`vcs_examples_build_*of8.test` shards. `vcsc_disassembler_hardening.pl` also
pins deterministic source output, duplicated and padded supported images,
filenames containing shell metacharacters, stale-output rejection, malformed
sizes adjacent to every supported layout, zero-instruction failures for every
size-selected mapper family, and an independently compiled `stego` smoke case.
Deterministic fuzz additionally rejects accidental graphics, pointer-table, and
TIA-color-table promotion in arbitrary data.

## Developer notes

The opcode table is generated from `assembler/default.cfg` by
`gen_opcode_table.pl`; do not create a second hand-maintained 6502 opcode table.
The analyzer stores byte roles independently, so executable bytes, operands,
data reads, possible dynamic reads, overlaps, vectors, and graphics provenance
may coexist. Abstract state tracks useful A/X/Y, C/Z/N/V/D condition facts, and
zero-page pointer values and loses knowledge conservatively at joins.

Mapper state is part of control flow. Origin inference uses vectors plus candidate
`JMP`/`JSR` evidence before final reachability. New mapper recognizers should be
added as explicit hardware models; do not shoehorn unrelated schemes into the
F8/F6/F4/FA implementation. New controller recognizers should add positive evidence
and preserve ambiguous output when the accessed registers do not distinguish a
device.

Any readability change must continue to pass both `vcsc_disassembler.pl` and
`vcsc_disassembler_opcodes.pl`, plus `roundtrip.pl` against representative real
ROMs. If semantic output cannot be proven to reassemble identically, emit the
original bytes.

## Current limits

Mapper support beyond unbanked/F8/F6/F4/Superchip/FA/CV/JANE/0840/UA/UASW/DPC/WD is deliberately conservative.
3F, 3E, E0, E7, FE, UA, DPC+, CDF and coprocessor cartridges need
separate mapper models rather than being mislabeled as supported families.
Unsupported layouts that yield no executable instructions fail explicitly rather
than producing a misleading 100%-data source file.

Static code/data analysis is necessarily incomplete for self-modifying code,
dynamically constructed RAM code, unresolved indirect tables, and similarly
hostile control flow. Those cases should become more explicit as analysis grows;
they must never weaken the byte-round-trip invariant.

The detailed implementation roadmap and analysis contracts live in
`../.../disassembler.txt`.

Video inference combines known RIOT timer values, parameterized timer-helper call sites, broad counted-WSYNC kernels, explicit NTSC/PAL/SECAM filename tokens, and a bounded stable-frame execution probe built on the shared `simulator/mos6502` core. Timing-only 50 Hz results remain PAL-family because PAL and SECAM share the frame layout.
