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
    --video ntsc --controller0 joystick --controller1 paddles \
    game.bin
```

Supported mapper overrides are `raw`, `2k`, `4k`, `f8`, `f8sc`, `f6`,
`f6sc`, `f4`, and `f4sc`. `--origin BANK:ADDRESS`, `--entry BANK:ADDRESS`,
`--code BANK:START-END`, and `--data BANK:START-END` are repeatable. The bank
may be omitted for a one-bank cartridge. Numbers accept decimal, `0x` hex, or
`$` hex; quote `$` forms in a shell so the shell does not treat them as variable
references.

`--code` asserts a linear instruction range even across `RTS`/`JMP`; `--entry`
adds an ordinary recursive-control-flow seed. `--data` is non-exclusive: the
same bytes may still be executable code. Contradictory mapper sizes, invalid
banks, misaligned origins, truncated forced instructions, and out-of-window
ranges are errors rather than guesses.

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

The disassembler currently recognizes unbanked 2K/4K and the F8/F6/F4 family,
with Superchip evidence reported as F8SC/F6SC/F4SC. Unsupported or odd-sized
images fall back to an exact raw `.byte` representation.

The generated header records the input size and SHA-256, mapper evidence,
physical banks, inferred bank origins and reset bank, video/controller evidence,
and the `vcsc-disas` version.

For Superchip variants, the physical bytes occupying the first `$100` bytes of
each 4K bank are preserved exactly but annotated as hidden by the Superchip RAM
window rather than decoded as ROM. The hardware maps `$1000-$107F` as the RAM
write port and `$1080-$10FF` as its read port, so those dump bytes are not
ordinary runtime ROM.

Automatic Superchip promotion requires a decoded write to the `$x000-$x07F`
write window. A read from `$x080-$x0FF` alone is not sufficient evidence, because
a plain F8/F6/F4 cartridge may legitimately read ordinary ROM at the same bus
addresses. `--mapper f8sc|f6sc|f4sc` remains available when static control-flow
analysis cannot observe the initializing RAM write.

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

Unreferenced regions remain exact data and are annotated rather than being
force-decoded simply because random bytes happen to form legal 6502 opcodes.

## Sprite/font rows

When a ROM table has strong graphics provenance--for example an indexed load
whose value is subsequently written to `GRP0`, `GRP1`, or a playfield
register--raw bytes are written one row per line.  The assembler's actual binary
literal syntax is `%` followed by zeroes and ones, so the X/dot picture is kept
as a comment rather than inventing new assembler syntax:

```asm
    .byte %00111100    ; ..XXXX..
    .byte %01100110    ; .XX..XX.
```

Countdown-indexed loops are used when possible to prove the table length; low
confidence data stays in ordinary numeric form.

## Video and controller inference

Inference comments are evidence, not metadata injected into the cartridge.
Static video recognition understands both the maintained VCSC RIOT timer
signatures and conventional counted-`WSYNC` frame loops. The `42/34` timer pair
is strong NTSC evidence and `52/41` is strong 50-Hz PAL-family evidence; counted
3/37/192/30 and 3/45/228/36 scanline phases provide corresponding evidence for
software that does not use RIOT frame timers. A 50-Hz result is reported as
PAL/SECAM ambiguous; frame timing alone cannot distinguish those two standards.

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

## Developer notes

The opcode table is generated from `assembler/default.cfg` by
`gen_opcode_table.pl`; do not create a second hand-maintained 6502 opcode table.
The analyzer stores byte roles independently, so executable bytes, operands,
data reads, possible dynamic reads, overlaps, vectors, and graphics provenance
may coexist. Abstract state tracks useful A/X/Y, carry/decimal, and zero-page
pointer facts and loses knowledge conservatively at joins.

Mapper state is part of control flow. Origin inference uses vectors plus candidate
`JMP`/`JSR` evidence before final reachability. New mapper recognizers should be
added as explicit hardware models; do not shoehorn unrelated schemes into the
F8/F6/F4 implementation. New controller recognizers should add positive evidence
and preserve ambiguous output when the accessed registers do not distinguish a
device.

Any readability change must continue to pass both `vcsc_disassembler.pl` and
`vcsc_disassembler_opcodes.pl`, plus `roundtrip.pl` against representative real
ROMs. If semantic output cannot be proven to reassemble identically, emit the
original bytes.

## Current limits

Mapper support beyond unbanked/F8/F6/F4/Superchip is deliberately conservative.
3F, 3E, E0, E7, FE, UA, 0840, DPC, DPC+, CDF and coprocessor cartridges need
separate mapper models rather than being mislabeled as F8-family cartridges.
The exact raw fallback remains available for unsupported sizes/layouts.

Static code/data analysis is necessarily incomplete for self-modifying code,
dynamically constructed RAM code, unresolved indirect tables, and similarly
hostile control flow. Those cases should become more explicit as analysis grows;
they must never weaken the byte-round-trip invariant.

The detailed implementation roadmap and analysis contracts live in
`../.../disassembler.txt`.
