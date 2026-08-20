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

Supported mapper overrides are `1k`, `2k`, `4k`, `f8`, `f8sc`, `f6`, `f6sc`,
`f4`, `f4sc`, `fa`, `dpc`, `wd`, `wdsw`, `fc`, `e0`, `3f`, `3e`, `fe`, `cv`, `jane`, `0840`, `ua`, `uasw`, `0fa0`, and `ar`. `--origin BANK:ADDRESS`, `--entry BANK:ADDRESS`,
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

The disassembler currently recognizes unbanked 1K/2K/4K, the F8/F6/F4 family
(with Superchip evidence reported as 4KSC/F8SC/F6SC/F4SC), CBS RAM Plus / FA, CommaVid CV, Parker Brothers E0, M-Network E7, Tigervision 3F/3E, JANE, 0840/EconoBanking, UA/UASW, 0FA0/Fotomania, DPC,
Wickstead Design / WD/WDSW, Amiga Power Play / FC, and Starpath/Arcadia Supercharger / AR. Standard DPC
images are recognized by their distinctive 10240- or 10495-byte layout: two
4K F8-style program banks followed by 2K of DPC data ROM, with the 10495-byte
form carrying an additional 255-byte RNG table.

Starpath/Arcadia Supercharger fast-load images are recognized structurally when the input size is an exact multiple of 8448 bytes. Each 8448-byte load contains 8192 bytes of page data followed by a 256-byte header. The header supplies the initial start address, control byte, page count, load ID, page-to-RAM map, and checksums. `vcsc-disas` reconstructs the Supercharger's three 2K RAM banks from those page mappings, carries prior RAM contents into nonzero concatenated multi-loads, and recursively decodes the payload from the header start address under the header's initial two-window bank configuration. Payload code is emitted as a comment-only runtime view with physical-file provenance, while every original tape/load byte is emitted raw so reassembly remains byte-exact. Invalid header or page checksums are reported but do not cause preservation bytes to be normalized or rejected. Static payload flow currently stops when a `$FFF8` configuration change cannot be resolved from the address-bus data-hold latch; analog cassette timing and the copyrighted 2K Supercharger BIOS are deliberately outside the input image and are not synthesized into output bytes.

Unbanked 1K cartridges are treated as one physical 1024-byte ROM mirrored four
times through the 4K cartridge window.  The canonical presentation origin is
therefore normally `$FC00`, while runtime references in any mirror resolve to
the same physical byte modulo `$0400`.  The hardware vector bytes are the final
six physical bytes of the 1K image.  Normal analysis retains the existing NMI
and RESET roots, but does not seed IRQ/BRK merely from `$FFFE/$FFFF`; that
target becomes executable only after analysis encounters a reachable `BRK`.
RESET alone is used while testing competing mapper hypotheses.  `--mapper 1k` forces this
topology for a 1024-byte input.

A 4096-byte image whose upper 2048 bytes are byte-for-byte identical to its
lower 2048 bytes is recognized as a doubled preservation dump of an ordinary
unbanked 2K cartridge.  `vcsc-disas` analyzes one logical 2K copy with normal
2K mirroring semantics and emits the duplicate half as preserved raw bytes, so
disassemble/reassemble still reproduces the original 4096-byte file exactly.
A merely similar or partially duplicated 4K image remains an ordinary 4K cart.

Stella-playable 4094- and 4098-byte preservation dumps are treated as logical
unbanked 4K cartridges without changing their physical files.  This mirrors
Stella's generic cartridge behavior: a short image is zero-filled to 4096 bytes
for runtime analysis, while an overlong image is truncated to 4096 bytes for
runtime mapping.  VCSC emits only the bytes actually present in a short dump
and preserves ignored trailing bytes from an overlong dump, so exact round trip
retains the original 4094/4098-byte input rather than canonicalizing it.

WD is the custom Pursuit of the Pink Panther mapper. It uses eight 1K ROM banks
and eight fixed four-segment arrangements selected by reads from TIA `$30-$3F`.
The cartridge also contains 64 bytes of RAM, read at `$1000-$103F` and written
at `$1040-$107F`. Stella uses two names for the two known file layouts: `WD` is
the corrected 8192-byte image and is recognized by the distinctive `LDA $39;
JMP` byte signature; `WDSW` is the historical 8195-byte preservation dump. Both
run through the same WD hardware model. For WDSW analysis, physical 1K chunks 2
and 3 are interpreted in the corrected logical order used by Stella, while
source emission keeps the original file order and retains the three non-emulated
trailing bytes so round trip remains exact. `--mapper wd` accepts only 8192-byte
images and `--mapper wdsw` only the 8195-byte preservation form.

FC is Amiga Power Play's staged 4K-bank mapper, supported for 4K, 8K,
16K, and 32K images.  The currently mapped bank and the prepared bank selector
are separate state.  A write to `$1FF8` replaces the prepared selector with the
low two bits of the written value.  A write to `$1FF9` supplies the high part;
when `(value << 2)` names a representable bank it is added to the prepared low
bits modulo the ROM bank count, otherwise Stella's hardware model falls back to
`value % bank_count`.  Merely staging either value leaves execution in the old
bank.  A read or write access to `$1FFC` commits the prepared selector, and the
next opcode fetch comes from the newly mapped bank.  Reads of `$1FF8/$1FF9` do
not stage anything.  Reset starts with physical bank 0 mapped and prepared
selector 0.  Automatic FC inference uses Stella's characteristic staged-select
byte signatures; `--mapper fc` is available when explicit identification is
needed.

E0 is modeled as eight physical 1K ROM banks mapped into four 1K runtime
segments. Accesses to `$1FE0-$1FE7`, `$1FE8-$1FEF`, and `$1FF0-$1FF7` select
physical banks for the first, second, and third segments respectively; the top
segment always maps physical bank 7. Deterministic reset starts with banks
4,5,6,7 mapped in order. Mapper state is therefore part of each E0 control-flow
edge: a selector can make the next opcode come from another physical 1K bank
even though the runtime PC simply advances normally.

E7 is modeled as 2K physical chunks with a selectable lower `$F000-$F7FF`
window and a fixed final physical 2K supplying `$FA00-$FFFF`.  The bytes that
would otherwise appear at `$F800-$F9FF` are overlaid by a fixed 256-byte RAM
window.  The lower selector table depends on the released image size: 8K uses
`$1FE4-$1FE7` for its four lower mappings, 12K uses the E7 alias table across
`$1FE0-$1FE7`, and 16K uses `$1FE0-$1FE7` directly.  Selecting the final lower
index maps 1K of RAM instead of ROM; `$1FE8-$1FEB` select one of four 256-byte
RAM blocks in the fixed upper window.  Both RAM areas use split aliases (lower
write `$F000-$F3FF`, read `$F400-$F7FF`; fixed write `$F800-$F8FF`, read
`$F900-$F9FF`), so a reachable RMW against either region contradicts E7.
Selector/configuration state is carried through branches, calls, jumps, and
speculative islands; decoded E7 selector traffic is positive evidence even
when the selector executes from fixed ROM and therefore does not change the
immediately following opcode fetch.

3F is modeled as 2K physical ROM banks. `$F800-$FFFF` always maps the final
physical 2K and supplies the vectors; `$F000-$F7FF` maps a selected 2K bank and
powers up on bank 0. The hardware watches every write to TIA `$00-$3F`; the
written value modulo the physical-bank count selects the lower bank. VCSC
therefore carries that selected bank in CFG state and treats the next opcode
fetch as a cross-bank edge when the lower mapping changes. Ordinary TIA writes
affect state once 3F is hypothesized but are not identification evidence;
explicit decoded writes to `$3F` and the historical repeated `STA $3F` pattern
are used to distinguish 3F from same-sized mapper candidates. Unknown write
values remain conservative rather than inventing a single bank.

A run that discovers zero instructions is an error. `vcsc-disas` does not call a
100%-`.byte` dump a successful disassembly; unsupported/raw layouts therefore
fail unless future mapper support or explicit analysis can establish executable
code. Raw `.byte` emission remains the exactness fallback for uncertain regions
inside an otherwise successful disassembly.

The generated header records the input size and SHA-256, mapper evidence,
physical banks, inferred bank origins and reset bank, video/controller evidence,
and the `vcsc-disas` version.  When several supported mapper models fit the same
physical size, `vcsc-disas` now tests those models as competing control-flow
hypotheses. Each hypothesis must first establish a cartridge-backed RESET entry;
speculative islands may extend that RESET-established graph but can never make an
unbootable hypothesis viable by themselves. The surviving hypothesis is then
traced through mapper transitions and credible speculative islands to a fixed
point. A reachable HLT/JAM/KIL normally eliminates a model, but abstract flow can
over-approximate data-dependent paths that real execution never takes. A mapper
that demonstrates a bank-changing edge through a narrow cartridge-specific
selector remains viable despite such a merely possible halt; hypotheses that
halt without demonstrating their switching mechanism are still eliminated.
Raw selector-hit counts are not compared across mapper families because broad
alias decoders can create misleadingly high counts. A selector transition that
demonstrably avoids an old-mapping HLT/JAM/KIL and resumes valid code in the new
mapping is especially strong control-flow evidence. Bank changes produced only
by broad partial-address decoders such as 0840/UA/0FA0 are not, by themselves,
allowed to outrank another mapper.
Deliberate VCSC mapper signatures and legacy raw-byte detector patterns are
tie-break evidence, not a reason to override contradictory executable control
flow. Dynamic/unresolved control-exit counts are likewise **not** ranked across
mapper hypotheses: a wrong mapping can appear artificially cleaner simply by
truncating the reachable graph. If viable models remain genuinely ambiguous,
the normal size/signature inference is preserved rather than rewarding the
model that happened to decode less code.

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

3E extends Tigervision 3F with banked cartridge RAM. A write to `$3E` selects
one of 32 RAM banks for the lower window; RAM is read through `$F000-$F3FF`
and written through `$F400-$F7FF`. A write to `$3F` restores a 2K ROM bank.
Pure `$3F` traffic is not 3E evidence; automatic inference requires the
distinguishing `$3E` RAM selector, an explicit VCSC signature, or the canonical
legacy `STA $3E` plus repeated `STA $3F` pattern. RMW against either RAM alias
contradicts the 3E hypothesis.

FE/SCABS is modeled as two 4K physical banks with the mapper's delayed
`$01FE` stack-bus latch. Released FE cartridges use a JSR idiom: the low return
address push hits `$01FE`, and the following JSR target-high byte determines the
bank that supplies the subroutine (`$E0-$FF` selects physical bank 0 and
`$C0-$DF` selects bank 1). `vcsc-disas` carries that selected bank across the
call while RTS returns to the caller continuation in its original bank. Automatic
FE inference requires one of the established released-cart FE call signatures,
so an ordinary JSR in an unrelated 8K ROM cannot promote the mapper merely by
having a convenient target high byte. `--mapper fe` forces the same mapping for
investigation of uncatalogued cases.

Split-address cartridge RAM is treated semantically rather than as a byte
signature. Superchip, CBS RAM Plus/FA, CommaVid CV, and WD all expose separate
CPU aliases for reading and writing the same physical RAM. A pure read from a
read alias is neutral mapper evidence because ordinary ROM can also be read at
that address, and an ordinary store is not compared as a positive score across
unrelated mapper families. Any reachable 6502 read-modify-write instruction
whose effective address lies in either alias is negative evidence for that
split-RAM mapper: an RMW uses one effective address for both phases, while no
single split alias supplies the intended RAM semantics for both the read and the
write. This contradiction can eliminate an otherwise size-compatible FA/CV/WD
mapper hypothesis.

Automatic Superchip promotion accepts either a decoded **write-only store** to
the `$x000-$x07F` write window or the conventional F8SC/F6SC/F4SC dump layout
where, in every 4K physical bank, bytes `$000-$07F` are duplicated at
`$080-$0FF`. The structural rule is not applied to lone 4K images. Reads from
`$x080-$x0FF` remain neutral. Any reachable RMW anywhere in `$x000-$x0FF` is
contradictory, and established RESET/control flow into the SC write port
`$x000-$x07F` vetoes automatic promotion because instruction fetches would hit
the write alias rather than ROM. The read port is not the same execution veto
because code may deliberately run from populated cartridge RAM.
`--mapper f8sc|f6sc|f4sc` remains available for ambiguous cases.
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


0FA0/Fotomania is an 8K two-bank layout with physical bank 1 as the hardware
default. `vcsc-disas` recognizes VCSC's `0FA0` tail signature or established
`BIT/STA/LDA $0FC0` detector sequences, reports the explicit `(A & $16E0)`
selector rule, and follows any matching alias in control-flow analysis. `$06A0`
selects physical bank 0 and `$06C0` selects physical bank 1 after masking.

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
that a halt is reachable. Each conditional-branch edge also constrains the tested
flag in its successor state, so mutually exclusive sequences such as `BMI`
fallthrough followed immediately by `BPL` cannot invent an impossible third path
into data. Mapper selector accesses are control-flow edges: the
next opcode is fetched at the same logical continuation address from the selected
physical bank. Therefore `LDA $hotspot` followed physically by JAM/KIL in the old
bank is not a failed path when the selected bank contains the valid continuation.
The same rule is used for RESET-reachable code, mapper-hypothesis testing, and
speculative islands. During mapper inference, however, an island is supplemental
evidence only: a candidate mapper with no cartridge-mapped RESET entry is rejected
before speculative island discovery, even if detached bytes would otherwise form
a credible routine. Speculative walks are bounded; a candidate that exceeds the
analysis budget stays inconclusive/raw rather than being guessed. The generated
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

## Concrete RESET discovery

For mapper layouts whose CPU-side bus model is implemented by the concrete probe,
`vcsc-disas` performs bounded execution from the hardware RESET vector using the
maintained `simulator/mos6502` core. This is positive reachability evidence, not a
replacement for recursive static analysis. The execution state includes exact
PC/A/X/Y/SP/P, the complete 128-byte RIOT RAM with stack-page aliases, RIOT timer and
TIA WSYNC CPU-side behavior, cartridge banking/RAM, and deterministic console/input
states. The concrete bus now covers every currently supported non-coprocessor mapper:
unbanked 1K/2K/4K, F8/F6/F4/FA (and supported Superchip overlays), CV, WD/WDSW, FC,
E0, E7, 3F, 3E, FE, JANE, 0840, UA/UASW, and 0FA0. DPC remains intentionally static
until its data-fetcher/register behavior is modeled faithfully; an unsupported
concrete model simply leaves static analysis authoritative.

Static analysis drains first. Only cartridge instruction starts observed concretely
but still missing from the static graph are then added as entry evidence. This ordering
is intentional: injecting every sampled PC with an unknown abstract state would destroy
useful static register/pointer facts at joins. Concrete execution is also gated on a
trusted mapper identity: unbanked topology, an explicit `--mapper`, or distinctive
family evidence. Weak size-default F8/F6/F4/FA guesses do not qualify.

H1 adds stack/interrupt-aware abstract flow. SP is part of abstract state; provable
RIOT-RAM/stack aliases are carried through pushes/pops, JSR/RTS, and memory writes.
A reachable `BRK` promotes the mapper-visible `$FFFE/$FFFF` target into the CFG.
A bounded local IRQ trace may additionally connect that BRK to a specific RTI continuation
when the saved stack return address remains provable, including deliberate modification
through RIOT-RAM's stack-page mirror. Unknown/external-input branch conditions retain both CFG
edges rather than letting one sampled execution history prove the other edge dead.

Concrete input discovery treats the console switches according to their hardware use.
SELECT and RESET are momentary and therefore start released/high. COLOR/BW and the left
and right difficulty switches are maintained controls with no universally known startup
position, so the first pass semantically exhausts all eight combinations of those three
SWCHB bits. The all-high case runs first; if that bounded execution never reads SWCHB,
the other seven settings are provably execution-equivalent and are counted as covered
without redundant emulator runs. Once SWCHB is observed, all remaining maintained-switch
combinations are executed explicitly. If SWCHB is actually read, `vcsc-disas` additionally runs a SELECT press-and-release and
a RESET press-and-release under each of the eight maintained-switch combinations. The
pulse begins after a bounded startup interval and remains asserted long enough for an
ordinary frame-polling loop to observe it before release. SWCHA joystick directions and
INPT inputs remain demand-driven one-active-low scenarios rather than a Cartesian product
of controller states. The generated header reports scenario count/productivity, executed
instruction totals, distinct ROM and RIOT-RAM instruction starts, RAM bytes written, and
the all-switches-high run's final CPU state.

When execution enters RIOT RAM, the probe snapshots the instruction bytes actually
executed there and tracks simple ROM-to-RAM write provenance. `vcsc-disas` prints that
RAM execution as a **comment-only** disassembly block, including source ROM file offsets
when known. Those comments add no cartridge bytes, so disassemble/reassemble identity
remains authoritative even for loaders and self-modifying/generated RAM code.

`c33caa7d6ac7251bb804e0473198901d.bin` is the regression case for the combined H0/H1
analysis. Its 1K loader uses SP-sensitive `TSX/PHA`, one-byte `BRK` calls whose IRQ
handler modifies the saved return PC before `RTI`, a SWCHA-gated loader path, and a
ROM-to-RIOT-RAM copy followed by `JMP $00C2`. H1's alternate SWCHA execution reaches
that loader and recovers the RAM-resident game as comment-only instructions with ROM
provenance. H2 now iterates static and concrete discovery to a bounded fixed point:
when static analysis reaches an entry with exact A/X/Y/SP, modeled flags, and all 128
RIOT-RAM bytes known, that complete state may continue in the concrete engine. Newly
observed ROM targets feed back into the CFG, and newly decoded static paths may expose
another exact seed. The process stops when no new reachability appears. Mapper families
with cartridge RAM or transient mapper state not represented by the abstract state are
excluded from static-to-concrete seeding rather than supplied guessed contents. Sampled
execution is never negative reachability proof.

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
perl disassembler/roundtrip.pl --stella stella INPUT_DIR OUTPUT_DIR
```

It processes every direct `.bin` in `INPUT_DIR` in lexical order. For each ROM
it keeps `NAME.s26` and a reconstructed `NAME.bin` in `OUTPUT_DIR`, prints the
original and reconstructed MD5 values, and also performs an exact size/byte
comparison. It continues after individual failures and exits nonzero unless the
entire corpus passes.

`--stella PATH` additionally runs `PATH -rominfo ROM` for every successfully
round-tripped cartridge and compares Stella's resolved `Bankswitch Type` with
the mapper in the generated vcsc-disas header.  This is a differential check,
not the byte-exact pass/fail authority: Stella combines its MD5-keyed properties
database with its own mapper autodetection, and either detector may expose a bug.
The input corpus must already be Atari 2600/VCS ROMs. Stella's mapper detector is
not a platform detector; an arbitrary same-sized blob from another 6502 system
can still fall through to a size-default VCS mapper and produce a meaningless
comparison. Stella reports a native 1024-byte cartridge as `2K* (1K)` because it
uses the 2K cartridge implementation internally; `roundtrip.pl` normalizes that
spelling to VCSC's physical-topology name `1K`, so it is a mapper match.
Mapper disagreements are therefore reported as `MISMATCH` and summarized without
failing the round-trip run.  `--stella-strict` makes any mapper mismatch fail the
command when a zero-mismatch corpus gate is desired.  Failure to run or parse an
explicitly requested Stella comparison is always an error.

The generated `.s26` header keeps SHA-256 as its input-integrity fingerprint.
The corpus verifier already computes MD5 because that is the identifier used by
Stella's ROM properties database, so no weaker digest needs to replace SHA-256
in vcsc-disas itself.

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

Mapper support beyond unbanked/F8/F6/F4/Superchip/FA/CV/E0/E7/3F/3E/FE/JANE/0840/UA/UASW/0FA0/DPC/WD/WDSW/FC is deliberately conservative.
GL, CM, DPC+, CDF/CDFJ/CDFJ+ and other coprocessor cartridges need separate mapper models rather than being mislabeled as supported families.
Unsupported layouts that yield no executable instructions fail explicitly rather
than producing a misleading 100%-data source file.

The bounded concrete/hybrid pass now exposes input-gated, self-modifying, and dynamically
constructed RIOT-RAM code while retaining static alternate branch edges. Concrete
execution remains intentionally gated on a trusted cartridge topology; a weak
size-default F8/F6/F4/FA guess is not enough because executing an unsupported mapper
through the wrong hotspot model can manufacture false reachability. DPC concrete execution and unresolved indirect tables remain active roadmap work.
Hybrid fixed-point continuation is implemented conservatively only when the complete
seed state is exact; mapper-owned RAM/latches that are not represented abstractly block
that direction of feedback instead of being guessed. None of these analyses may weaken
the byte-round-trip invariant.

The detailed implementation roadmap and analysis contracts live in
`../.../disassembler.txt`.

Video inference combines known RIOT timer values, parameterized timer-helper call sites, broad counted-WSYNC kernels, explicit NTSC/PAL/SECAM filename tokens, and a bounded stable-frame execution probe built on the shared `simulator/mos6502` core. Timing-only 50 Hz results remain PAL-family because PAL and SECAM share the frame layout.
