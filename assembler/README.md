```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# vcsc-as

## Overview

`vcsc-as` is a custom two-pass 6502 assembler with:

- Intel HEX output
- relocatable o26 object output
- listing file output
- map output
- recursive `.include`
- expression evaluation
- labels and constants
- local labels
- addressing-mode specifiers
- relaxation from absolute-family encodings to zero-page-family encodings where legal
- simple source-level macros
- simple source-level textual aliases with `.def`
- rich opcode-table support via bundled `default.cfg`, optional `illegals.cfg`, and user-supplied opcode config files
- raw `opXX` opcode tokens for hand-written illegal or undocumented opcode includes
- multi-error reporting

It can operate in two primary modes:

- **relocatable object generation** with o26 output
- **VCSC-specific object identity** with magic prefix `01 00 6F 32 36` (`\x01\x00o26`)
- **final binary assembly** with Intel HEX output

Listing and map output can be requested alongside either mode.

See [`DESIGN_NOTES.md`](DESIGN_NOTES.md) for retained assembler design decisions,
including conditional-branch length and page-timing policy.

## Symbol names and local labels

Assembler identifiers may contain `?` and `@`, but symbols beginning with `@` are scoped/local labels and cannot be imported, exported, or marked weak. A linker-visible compiler-owned symbol may instead begin with `?@`; the leading `?` keeps it out of the local-label namespace.

## Command Line Parameters

`vcsc-as` follows the usual GNU `as` command-line shape:

- the input source is a positional operand
- `-o` selects the primary relocatable object output
- if no primary output is requested, the assembler writes an o26 object to `a.o26`

### Usage

```sh
vcsc-as [options] file
```

### Primary options

#### `file`

Input assembly source file.

#### `-o <file>`, `--output <file>`

Write relocatable o26 object output to `<file>`.

```sh
vcsc-as -o program.o26 program.s26
```

If neither `-o` nor `--hex` is given, `vcsc-as` writes relocatable output using the canonical default name `a.o26`.

```sh
vcsc-as program.s26
```

#### `-I <dir>`, `--include <dir>`

Add a directory to the include search path. May be repeated.

```sh
vcsc-as -I common -I board -o program.o26 program.s26
```

### Auxiliary outputs

These outputs are optional and keep the existing VCSC-specific spelling.

#### `--hex[=file]`

Write Intel HEX output. If no filename is supplied, the name is derived from the input path with a `.hex` extension.

```sh
vcsc-as --hex program.s26
vcsc-as --hex=program.hex program.s26
```

#### `--lst[=file]`

Write a listing file. If no filename is supplied, the name is derived from the input path with a `.lst` extension.

```sh
vcsc-as --lst program.s26
vcsc-as --lst=program.lst program.s26
```

#### `--map[=file]`

Write a map file. If no filename is supplied, the name is derived from the input path with a `.map` extension.

```sh
vcsc-as --map program.s26
vcsc-as --map=program.map program.s26
```

### Opcode-table options

#### `--opcode-cfg <file>`

Load an additional opcode configuration file after the bundled `default.cfg`. May be repeated. Later files can extend or override earlier mnemonic ... mode mappings, but they cannot assign an already-described opcode byte to a different addressing mode.

The opcode-table key is the pair **mnemonic + addressing mode**. If that same pair is defined more than once, the later definition silently replaces the earlier one; this applies both within one configuration file and across repeated `--opcode-cfg` options. For example, both bytes below are valid immediate-mode encodings:

```text
XXX  imm  $80
XXX  imm  $82
```

After loading those lines in that order, `XXX #$56` emits `$82,$56`; the `$80` mapping is no longer reachable through `XXX`. Exact raw spellings such as `op80 #$56` and `op82 #$56` remain available. Do not treat duplicate mnemonic/mode entries as a way to define an overloaded mnemonic.

Arbitrary examples such as `XXX imm $12` may instead be rejected because every opcode byte already has operand-shape metadata: `$12` is an implied-mode byte and therefore cannot be reassigned as immediate.

```sh
vcsc-as --opcode-cfg cpu65c02.cfg -o program.o26 program.s26
```

#### `--illegals`

Load the bundled `illegals.cfg` in addition to the always-loaded `default.cfg`. This enables named unofficial or illegal opcodes such as `LAX`, `SAX`, `DCP`, `ISC`, `SLO`, `RLA`, `SRE`, `RRA`, the retained-source aliases `ASR`/`ALR` and `SBX`/`AXS`, representative unofficial `NOP` forms, and representative halt names `KIL`, `JAM`, and `HLT`. Raw `opXX` byte validation does not require this flag, because `default.cfg` already contains operand-shape metadata for all 256 opcode bytes.

```sh
vcsc-as --illegals --hex=program.hex program.s26
```

### Input/output aliases

These forms are accepted in addition to the primary command-line shape.

#### `-i <file>`, `--input <file>`

Alias for the positional input file.

```sh
vcsc-as --input program.s26 --lst
```

#### `--o26[=file]`

Alias for object output.

- `vcsc-as --o26 program.s26` writes `program.o26`
- `vcsc-as --o26=custom.o26 program.s26` writes `custom.o26`

```sh
vcsc-as --o26 program.s26
vcsc-as --o26=program.o26 program.s26
```

### Help

#### `-h`, `--help`

Show usage and exit.

```sh
vcsc-as --help
```

## Examples

Generate a default object file named `a.o26`:

```sh
vcsc-as program.s26
```

Generate a named object file:

```sh
vcsc-as -o program.o26 program.s26
```

Generate Intel HEX plus listing and map files using derived names:

```sh
vcsc-as --hex --lst --map program.s26
```

Generate every output explicitly:

```sh
vcsc-as -o out.o26 --hex=out.hex --lst=out.lst --map=out.map test.s26
```

## Behavior Notes

### Optional argument syntax

For `--hex`, `--lst`, `--map`, and `--o26`, use the `=` form when supplying an optional filename:

```sh
vcsc-as --hex=program.hex --lst=program.lst --map=program.map --o26=program.o26 program.s26
```

Avoid relying on a space-separated optional value such as:

```sh
vcsc-as --hex program.hex program.s26
```

With `getopt_long()`, that extra token may be treated as a positional operand instead of an option value.

### Output defaults

- No primary output flags: write relocatable o26 output to `a.o26`
- `-o <file>`: write relocatable o26 output to `<file>`
- `--o26` without a filename: write relocatable o26 output to `<input>.o26`
- `--hex`, `--lst`, `--map` without filenames: derive names from the input path

## Source File Processing Order

The assembler preprocesses the root source before lexing/parsing:

1. `.include` expansion
2. macro definition collection
3. macro expansion
4. marker insertion for original file/line preservation
5. lexing/parsing
6. repeat expansion
7. pass 1 layout
8. relaxation
9. pass 2 emission

In flat output, a final numeric address in `$0000..$00FF` may select the
zero-page family. In relocatable o26 output, a small section-relative offset is
**not** proof of zero page: CODE, RODATA, DATA, and BSS symbols retain
absolute-family encodings unless their address size is independently known.
Relaxation is allowed for absolute expressions, true local ZP/ZEROPAGE symbols,
`.zpimport` symbols, and symbols covered by an explicit `.segmentaddrsize ...,
zp` contract (including affine constant addends which remain in range). Thus
bare `LDA glyph,X` is safe for a ROM glyph; `.ax` is not required as a
workaround.

A segment address-size contract applies to the named segment and its dotted
subsegments:

```asm
.segmentaddrsize "BSS", zp
.segmentaddrsize "BSS.slow_object", absolute
```

The most-specific matching declaration wins. The first line permits zero-page
relaxation for `BSS` and `BSS.*`; the second overrides it for one subtree.
Accepted size names are `zp`/`zeropage` and `absolute`/`abs`. Conflicting
contracts for the same exact name are errors. This directive is an assertion
about final linker placement, not a placement request. Use it only when the
source memory model or linker contract guarantees the range. VCSC emits the
BSS/DATA contracts automatically for targets whose default writable region is
wholly within page zero.

By default `vcsc-as` stays quiet on success. If you want to trace the relaxation work, enable the assembler xray:

```text
vcsc-as -X passes --hex=program.hex program.s26
```

That prints a pass-oriented trace: the first pass shows the full component sizes one item per line, later passes show only the fields that changed, and the stable pass prints the final sizes again. For example:

```text
pass 001: begin
   bytes: 2697
   instructions: 1147
   directives: 46
   labels: 19
   constants: 1
   zero-page encodings: 0
   absolute encodings: 438
   long branches: 7
   still relaxable: 3
   errors: 0
   bytes: 2697 -> 2466 (-231)
   zero-page encodings: 0 -> 222 (+222)
   absolute encodings: 438 -> 216 (-222)
   long branches: 7 -> 4 (-3)
   still relaxable: 3 -> 0 (-3)
pass 004: stable
   bytes: 2463
   instructions: 1147
   directives: 46
   labels: 19
   constants: 1
   zero-page encodings: 222
   absolute encodings: 216
   long branches: 3
   still relaxable: 0
   errors: 0
```

This means `.include` and macros are **source-level features**, not parser-level features.

## Syntax

### Rich opcode support

`vcsc-as` loads its opcode table from config files:

- `default.cfg` is always loaded automatically from the source-tree assembler directory or installed `share/cfg` directory
- `default.cfg` contains the official 6502 mnemonics plus `opXX` placeholder entries for otherwise unnamed opcode bytes, so raw opcode validation has metadata for all 256 byte values
- `--illegals` additionally loads `illegals.cfg`, which adds friendly names for the unofficial opcode subset that fits the rich-opcode table model, accepts `ASR` as an alias for `ALR` and `SBX` as an alias for `AXS`, and includes one representative name for each duplicate unofficial `NOP` addressing family plus representative `KIL`, `JAM`, and `HLT` halt spellings
- `--opcode-cfg <file>` loads one or more extra opcode tables

Opcode config files are line-oriented and use this syntax:

```text
MNEMONIC MODE OPCODE
```

For example:

```text
LDA imm  $A9
LDA zp   $A5
LDA abs  $AD
LAX imm  $AB
```

Supported mode names are:

- `imp`, `acc`, `imm`
- `zp`, `zpx`, `zpy`
- `abs`, `absx`, `absy`
- `ind`, `indx`, `indy`
- `rel`

Opcode bytes may be written as plain hex, `$xx`, or `0xXX`. Blank lines and lines beginning with `#` or `;` are ignored.

Once a mnemonic is present in the loaded opcode tables, the assembler picks the opcode byte from the parsed addressing mode and emits an error if that mnemonic has no mapping for the requested mode.

```asm
LDA #$42      ; uses LDA imm from default.cfg
LAX $10,Y     ; requires --illegals or an extra opcode config file
```

### `.def` textual aliases

`.def` performs a simple source-level textual replacement on identifier boundaries before lexing/parsing.

```asm
.def work _runtime_zp
.def XYZ LDA
```

That means opcode aliases work too:

```asm
XYZ #$42     ; same as LDA #$42
```

The replacement text runs to end-of-line (before any `;` comment), so it can also expand to other identifiers or tokens, not just a single bare word. The substitution is not applied inside strings or comments.

### Why `illegals.cfg` names only representative duplicate encodings

The bundled `illegals.cfg` is intentionally **not** a complete catalog of every known unofficial 6502 opcode encoding.

It deliberately enables two alternate spellings used by the retained standard-renderer source:

```text
ASR  imm  $4B    # same encoding as ALR
SBX  imm  $CB    # same encoding as AXS
```

The config file also carries a commented-out catalog of other established spellings and dialect families: `AAC`, `AAX`, `ASO`, `DCM`, `ISB`, `INS`, `LAR`, `LSE`, `SHA`, `AXA`, `SHS`, `SXA`, `SYA`, `SAY`, `ANE`, `DOP`, `TOP`, `LXA`, `OAL`, `ATX`, both incompatible meanings of `XAS`, and memory-addressed `AXS` as an alias for `SAX`. Each group records its historical usage and any ambiguity, instability, duplicate-encoding limitation, page-cross hazard, or naming conflict. They remain disabled until real imported source needs them.

The especially dangerous entries are comments on purpose. Immediate `$AB` (`LXA`/`OAL`/`ATX`) and the `$9B`/`$9E` high-byte-masked store family can vary with NMOS silicon and operating conditions. `XAS` is unusably ambiguous without choosing a source dialect because published tables apply it to both `$9B` (`TAS`) and `$9E` (`SHX`) in the same addressing mode. `AXS` is likewise already the active immediate name for `$CB`, although some assemblers reuse it for the memory-addressed `SAX` family. Exact `opXX` spelling is preferred when reproducing one of these encodings.

The current rich-opcode model is:

- one mnemonic
- one addressing mode
- one opcode byte

Internally, mnemonic plus addressing mode is a unique key. Loading that key again does not create ambiguity or retain both choices: the later byte silently replaces the earlier byte. Thus two active `DOP imm` lines would not make `DOP` select between two encodings; only the last line would survive.

That works well for most unofficial mnemonics such as `LAX`, `SAX`, `DCP`, `ISC`, `SLO`, `RLA`, `SRE`, and `RRA`, but it does **not** represent families where the same mnemonic has multiple opcode bytes for the **same** addressing mode.

For those duplicate families, `illegals.cfg` names one representative encoding and leaves the alternate bytes to the exact raw `opXX` form. In particular, it provides:

```text
NOP  imm  $80
NOP  zp   $04
NOP  zpx  $14
NOP  abs  $0C
NOP  absx $1C
KIL  imp  $02
JAM  imp  $12
HLT  imp  $22
```

`NOP imp $EA` already exists in `default.cfg`, so `illegals.cfg` does not add another implied `NOP` byte. Alternate halt encodings such as `$32`, `$42`, `$52`, `$62`, `$72`, `$92`, `$B2`, `$D2`, and `$F2`, and alternate unofficial `NOP` encodings such as `$82`, `$89`, `$C2`, and `$E2`, remain available as `opXX`.

Other unofficial encodings are omitted or only partially represented for similar reasons:

- duplicate same-mode aliases such as unofficial `SBC imm $EB`, because official `SBC imm $E9` already occupies that mnemonic ... mode slot in `default.cfg`
- duplicate same-mode encodings such as `ANC`, where only one immediate encoding is named in `illegals.cfg`

So `illegals.cfg` is best understood as a **useful named subset** of unofficial opcodes that fit the current table shape honestly, plus representative names for duplicate families. Raw `opXX` validation for omitted unofficial bytes does **not** depend on `--illegals`; `default.cfg` carries `opXX` placeholder entries for those bytes.

#### Workarounds when the config model is too small

When you need a non-representative duplicate unofficial encoding, there are two practical escape hatches.

##### 1. Use raw `opXX`

This is the most direct workaround, and it is why raw `opXX` support remains available:

```asm
KIL               ; representative halt spelling from --illegals
op32              ; alternate HLT/KIL/JAM encoding by exact byte
opEB #$42         ; unofficial SBC immediate encoding
op82 #$42         ; alternate unofficial NOP immediate encoding by exact byte
```

Because `default.cfg` includes `opXX` placeholders for otherwise unnamed byte values, raw `opXX` normally infers and validates the addressing mode from the byte itself even without `--illegals`.  Suffixes are allowed for explicitness, but they must agree with the byte's configured mode:

```asm
opAD $1234        ; official byte, inferred as absolute
op0C $1234        ; unofficial NOP absolute byte, inferred as absolute
op14 $20,X        ; unofficial NOP zero-page,X byte, inferred as zero page,X
op82 #$42         ; alternate unofficial NOP immediate byte, checked without --illegals
op14.zx $20,X     ; explicit suffix is also OK when it agrees
```

##### 2. Use `.def` as a source-level alias

If you want a nicer local spelling, `.def` can alias an identifier to a raw opcode token or to an existing mnemonic:

```asm
.def HLT op02
.def NOPABS op0C.a
.def XYZ LDA

HLT
NOPABS $1234
XYZ #$42
```

This is a textual alias, not a second rich-opcode table. It is useful for private include files or one-off projects where you are willing to choose the exact encoding yourself.

### Constants and mutable assembler variables

`NAME = expr` defines an immutable absolute equate.  Defining the same symbol again is an error.

`NAME ?= expr` defines an immutable absolute equate only when `NAME` is not already defined at that point in the source.  If `NAME` already has a value, the statement is ignored.

`.set NAME = expr` creates or updates a mutable assembler-time variable.  The right-hand side is evaluated immediately, using the current values of symbols at that source location.  `.set` can update a symbol previously created by `.set`, but it cannot update labels, ordinary equates, default equates that took effect, generated segment symbols, or other immutable symbols.

```asm
BASE = $8000
BANK ?= 4

.set i = 0
.byte i
.set i = i + 1
.byte i
```

Definedness tests treat ordinary equates, default equates that took effect, labels, generated segment symbols, and `.set` variables as defined.

### Expressions

Assembler expressions are used by instruction operands, `.if` / `.elif`, `.repeat`, `.org`, `.rorg`, `.align`, `.res`, `.byte`, `.word`, constants, default constants, and `.set`.  Directives use a leading dot, such as `.byte` or `.if`.

The current location counter is `*`.  There is no `.` alias for the current location counter.

Supported expression operators use C-style precedence and left associativity for binary operators.  Use braces, `{expr}`, to group subexpressions; parentheses are not expression grouping and are reserved for 6502 addressing syntax:

| Level | Operators | Meaning |
| ----- | --------- | ------- |
| unary | `+ - ! ~ < >` | positive, negative, logical not, bitwise not, low byte, high byte |
| multiplicative | `* / %` | multiply, divide, remainder |
| additive | `+ -` | add, subtract |
| shift | `<< >>` | left and right shift |
| relational | `< <= > >=` | comparisons, producing `0` or `1` |
| equality | `== !=` | equality comparisons, producing `0` or `1` |
| bitwise and | `&` | bitwise and |
| bitwise xor | `^` | bitwise xor |
| bitwise or | `|` | bitwise or |
| logical and | `&&` | logical and, producing `0` or `1` |
| logical or | `||` | logical or, producing `0` or `1` |

Logical `&&` and `||` short-circuit.  Division and remainder by zero are errors.  Negative shift counts and shift counts at least as wide as the host `long` are errors.

The low-byte and high-byte unary operators bind like other unary operators:

```asm
.byte <target + 2      ; low byte of target, plus 2
.byte <{target + 2}    ; low byte of target + 2
```

Forward references are accepted in expressions that can be resolved by later assembler passes, such as instruction operands, `.byte`, `.word`, and ordinary immutable equates.  Layout-control expressions for `.if`, `.elif`, `.repeat`, `.org`, `.rorg`, `.align`, and `.res` must resolve when the assembler needs them to determine layout or active source.

### Inline bank-call target metadata

`.banktarget expression` emits a relocatable 16-bit target followed by one linker-owned destination-descriptor byte. The target word has the same little-endian encoding as `.word`, but
marks the relocation as the inline logical target belonging to the immediately
preceding compiler-generated cross-bank `JSR`. It is linker protocol metadata,
not a general control-flow directive. The expression must be one relocatable
symbol. The linker consumes the word while the caller bank is still mapped and
rewrites the paired JSR to the fixed generic bank-call entry. Ordinary `.word`
and indirect `JMP` relocations remain distinct.

### Diagnostic directives

`.echo "message"` writes the decoded message to standard error during assembly.  It does not emit bytes and does not make assembly fail.

`.error "message"` reports the decoded message as an assembler error at that source location.  It does not emit bytes, and assembly fails.

Diagnostic directives obey conditional assembly and repeat expansion.  A diagnostic in an inactive conditional branch is ignored; a diagnostic inside a repeated block runs once per expanded copy.  Macro arguments can be used when they expand to a quoted string:

```asm
MACRO FAIL msg
   .error msg
ENDM

.ifndef bankswitch
   FAIL "bankswitch must be defined"
.endif
```

### Conditional assembly directives

Conditional assembly controls whether following statements participate in layout, symbol definition, and output.  Inactive branches are parsed, but their labels, constants, instructions, data directives, imports, and exports are ignored by the assembler passes.

The expression directives test whether an expression evaluates to a nonzero value:

```asm
.if feature_enabled
   .byte $01
.elif fallback_enabled
   .byte $02
.else
   .byte $00
.endif
```

The definedness directives test a single symbol name:

```asm
.ifdef bankswitch
   .byte bankswitch
.elifndef default_done
   bankswitch = 4
.endif
```

The conditional directive family is:

| Directive | Argument | Meaning |
| --------- | -------- | ------- |
| `.if expr` | expression | Assemble the branch when `expr` evaluates to nonzero. |
| `.elif expr` | expression | Start another expression-tested branch in the same conditional block. |
| `.ifdef name` | symbol name | Assemble the branch when `name` is already defined. |
| `.ifndef name` | symbol name | Assemble the branch when `name` is not defined. |
| `.elifdef name` | symbol name | Start another branch selected when `name` is already defined. |
| `.elifndef name` | symbol name | Start another branch selected when `name` is not defined. |
| `.else` | none | Start the fallback branch for the current conditional block. |
| `.endif` | none | End the current conditional block. |

`.ifdef`, `.ifndef`, `.elifdef`, and `.elifndef` are symbol-defined tests, not general expression tests.  Use `.if` or `.elif` when the value of an expression matters.

### Repeat directive

`.repeat expr` duplicates the statements up to the matching `.endrepeat` before the assembler layout and output passes run.  The expression must resolve to a non-negative value at repeat-expansion time.  It may use numeric expressions, ordinary equates, default equates that have taken effect, and `.set` variables that have already been defined in the source.  Nested repeat blocks are supported.

```asm
.repeat 3
   nop
.endrepeat

.repeat 2
   .repeat 2
      .byte $00
   .endrepeat
.endrepeat
```

`.repeat 0` is accepted and emits nothing for the block.  Labels inside a repeated block are duplicated like ordinary source text; defining the same label more than once is an error unless the labels are written to be unique.

### Alignment directive

`.align boundary` advances the current segment address to the next multiple of `boundary` and emits zero padding for the skipped bytes. `.align boundary, offset` instead advances until `address % boundary == offset`; `offset` must be from zero through `boundary - 1`. An optional third expression, `.align boundary, offset, fill`, selects the byte emitted for padding instead of zero; `fill` must be from 0 through 255. The boundary must be positive, and `.align 1` is accepted as a no-op.

```asm
.segmentdef "CODE", $8000, $0200
.segment "CODE"
.byte $AA
.align 4
next:
.byte $BB        ; next is $8004

; Place the next object at low byte $54 without a dummy source array.
.align 256, $54
timing_table:
.byte $CC        ; timing_table is $8054

; Place setup six bytes before a page boundary and make the skipped bytes NOPs.
.align 256, $FA, $EA
position_setup:
sta WSYNC        ; if the setup is six bytes, the following loop begins at xx00
```

For direct/HEX output, any positive boundary is valid because the assembler already knows the final address. For relocatable o26 output, `.align` boundaries must be powers of two from 1 through 32768. The assembler both emits the local padding **and records an implicit final segment-base alignment of the same boundary**, so after linking the requested `address % boundary == offset` relation is an absolute CPU-address contract rather than merely a section-relative coincidence. Multiple `.align` directives on one segment combine by keeping the strongest power-of-two base alignment.

While `.rorg` is active, `.align` still computes padding from the logical/runtime address, as described below. The o26 segment also carries the boundary alignment metadata for its physical placement; the `.rorg` value remains the authority for the logical CPU address.

### Relocatable origin directives

`.rorg expr` starts a logical/runtime origin for the current segment.  Bytes continue to be emitted at the current physical segment address, but labels, `*`, branch displacement calculations, and operand expressions use the logical address set by `.rorg`.  As bytes are emitted, both the physical address and logical address advance by the number of emitted bytes.

`.rend` ends the active logical origin for the current segment.  After `.rend`, labels and expressions use the physical segment address again.

`.org` is not allowed while `.rorg` is active.  End the logical origin with `.rend` before changing the physical origin.

```asm
.segmentdef "CODE", $8000, $1000
.segment "CODE"
.org $8100       ; physical/output address
.rorg $F000     ; logical/runtime address

start:
   jmp start    ; bytes at $8100, operand encodes $F000

.rend
.org $8120
```

`.align` uses the logical address while `.rorg` is active and still emits padding at the physical output address.

Direct Intel HEX output supports physical `.org` offsets through `$7FFFF` (512 KiB).
When output crosses a 64 KiB boundary, `vcsc-as` emits Intel HEX type-04 Extended
Linear Address records; `.rorg` remains a 16-bit CPU/runtime address. This lets a
large cartridge image preserve physical file-bank offsets without pretending the
6507 itself has an address wider than 16 bits.

### Raw `opXX` opcode form

The assembler accepts `opXX` where `XX` is a hexadecimal opcode byte.  `default.cfg` gives every byte a configured addressing mode, either through an ordinary mnemonic or through an `opXX` placeholder entry, so raw `opXX` is self-describing by default: the assembler uses the opcode byte's configured addressing mode and operand size, and rejects operands or suffixes that disagree with that mode.

```asm
opA9 #$42        ; $A9 is immediate
op8D $1234       ; $8D is absolute, no .a suffix required
opA5 $12         ; $A5 is zero page
opB5 $12,X       ; $B5 is zero page,X
opBD $1234,X     ; $BD is absolute,X
opA1 ($12,X)     ; $A1 is indexed indirect
opB1 ($12),Y     ; $B1 is indirect indexed
op6C ($1234)     ; $6C is indirect
opF0 target      ; $F0 is relative
opEA             ; $EA is implied
```

Mismatched raw-opcode operands are errors:

```asm
opA9 A           ; error: $A9 expects immediate syntax
opA9.a $12       ; error: .a selects absolute, but $A9 is immediate
opAD.z $12       ; error: .z selects zero page, but $AD is absolute
opA1 $12         ; error: $A1 expects indexed-indirect syntax without a suffix
```

Suffixes are available for explicitness. A suffix must agree with the opcode byte's addressing mode and with the operand syntax. The bundled `default.cfg` describes all 256 byte values, so raw opcode operand size is derived from the configured byte metadata.

Supported addressing-mode suffixes are:

| Suffix | Final addressing mode | Operand syntax normally used | Bytes emitted |
| ------ | --------------------- | ---------------------------- | ------------- |
| `.z`   | zero page             | `opA5.z $12`                 | opcode + 1 operand byte |
| `.zx`  | zero page,X           | `opB5.zx $12,X`              | opcode + 1 operand byte |
| `.zy`  | zero page,Y           | `opB6.zy $12,Y`              | opcode + 1 operand byte |
| `.a`   | absolute              | `opAD.a $1234`               | opcode + 2 operand bytes |
| `.ax`  | absolute,X            | `opBD.ax $1234,X`            | opcode + 2 operand bytes |
| `.ay`  | absolute,Y            | `opB9.ay $1234,Y`            | opcode + 2 operand bytes |
| `.i`   | indirect              | `op6C.i ($1234)`             | opcode + 2 operand bytes |
| `.ix`  | indexed indirect      | `opA1.ix ($12,X)`            | opcode + 1 operand byte |
| `.iy`  | indirect indexed      | `opB1.iy ($12),Y`            | opcode + 1 operand byte |

There are no addressing-mode suffixes for implied, accumulator, immediate, or
relative forms. Use normal operand syntax instead: no operand for implied, `A`
for accumulator, `#expr` for immediate, and a conditional-branch opcode such as
`opF0 target` for relative branches. `.i` means indirect, not immediate.

Relative conditional branches have a separate set of optional page-timing
suffixes:

```asm
bne       loop       ; flexible; linker prefers a same-page taken branch
bne.flex loop       ; explicit spelling of the default
bne.same loop       ; taken branch must remain on the same page
bmi.cross final     ; taken branch must cross a page
```

The page comparison uses the PC after the two-byte branch instruction, exactly
matching the NMOS 6502/6507 taken-branch timing rule. Relative displacement and
that page comparison use 16-bit CPU-PC wraparound, so a branch near `$FFFF` may
legitimately target `$00xx` with an ordinary signed 8-bit displacement. Bare
branches and `.flex` are placement preferences, not contracts: the linker
minimizes their page crossings but may allow one when other constraints require
it. `.same` and `.cross` are hard contracts and cause an error if no valid
placement exists.

These suffixes are valid only on the eight relative conditional branches (or
their matching raw-opcode spellings, such as `opF0.same`). A hard annotation
must remain a short relative branch; it may not relax into the assembler's
long-branch sequence. In relocatable output, the annotated source and target
must belong to the same movable code layout so the linker can control their page
relationship. In flat assembly, `vcsc-as` checks the final addresses directly.

Suffixes must agree with the operand syntax before the opcode table is consulted.  Expression-family suffixes use ordinary expression operands:

```asm
LDA.z  expr
LDA.zx expr,X
LDA.zy expr,Y
LDA.a  expr
LDA.ax expr,X
LDA.ay expr,Y
```

For those six suffixes, use `{expr}` for expression grouping.  Parentheses still do not group expressions, even when a suffix has already selected a non-indirect addressing family:

```asm
LDA.a  {foo + bar} + 1
LDA.zx {ptr + 1},X
LDA.ay {table + index},Y
```

Indirect-family suffixes keep 6502 addressing parentheses as addressing syntax:

```asm
JMP.i  (vector)
LDA.ix (ptr,X)
LDA.iy (ptr),Y
```

These are rejected because the suffix and operand shape disagree:

```asm
JMP.i  vector       ; .i requires indirect syntax
LDA.ix #$12         ; immediate syntax is not indexed-indirect syntax
LDA.iy (ptr,X)      ; indexed-indirect syntax is not indirect-indexed syntax
LDA.z  value,X      ; indexed syntax is not plain zero-page syntax
```

Outermost operand parentheses are always 6502 addressing syntax.  For example, `LDA (foo + bar)` is not expression grouping; it is an indirect-shaped operand and is rejected because `LDA` has no plain indirect addressing mode.  Use `LDA {foo + bar}` when the source needs expression grouping.

For ordinary mnemonics, suffixes force the final addressing family where the mnemonic supports it, and impossible mnemonic/mode combinations are rejected.  For example, `LDA.a $12` forces absolute encoding, while `JMP.ix ($20,X)` is rejected because `JMP` has no indexed-indirect encoding.

NMOS 6502/6507 indirect `JMP` has a silicon page-wrap bug: a vector operand at
`$xxFF` fetches its high byte from `$xx00`, not `$xx+1:00`.  The assembler
therefore rejects a resolved `JMP ($xxFF)`.  Relocatable indirect-JMP operands
carry a dedicated relocation flag so the linker can apply the same check after
final placement.  This does not reject ordinary indexed-indirect or
indirect-indexed zero-page operands such as `LDA ($FF),Y`; their `$FF` to `$00`
zero-page wrap is part of the documented addressing-mode semantics and may be
used intentionally.


The current o26 writer emits a per-layout flags byte followed by an indexed-
range start and maximum index. Bit 0 is the hard whole-layout page-containment
contract; bit 1 says that the indexed effective-address window is present. The
linker remains backward-compatible with all older layout records.

### Procedure layouts in named code regions

In relocatable o26 output, `.proc` inside `CODE` or any `CODE.*` segment becomes
an independently movable private layout. For example, a procedure in
`CODE.bank1` is recorded as `CODE.bank1.__vcsc_function$NAME`. The linker can
therefore pin one source-level function to a named memory region without merging
all functions assigned to that region into one indivisible layout. Procedures
in unrelated explicit segments retain their existing whole-segment behavior.

### Component-owned linker constraints

Relocatable assembly components may carry their own final-placement and hidden
hardware-stack requirements in reserved o26 metadata:

```asm
.segmentregion "RENDERER_CODE", startup
.segmentalign "RENDERER_CODE", 256
.segmentprivate "RENDERER_CODE"
.callstackextra 4
```

`.segmentregion "SEGMENT", REGION` requires the named final layout to use that
C26 `mem` region. The special identifier `startup` means the selected cartridge
topology's default/startup read-only region, so one component can compose with
4K, F8, F6, or F4 without naming `rom` or `bank0`. The named layout must exist.

`.segmentalign "SEGMENT", ALIGNMENT` explicitly requires the final layout base to have the specified power-of-two alignment from 1 through 32768, without inserting any padding at the declaration site. Relocatable `.align` now also contributes an implicit final base-alignment constraint in addition to its local padding; `.segmentalign` remains useful when the component needs a base constraint without moving the current location, or when the constraint is declared separately from the aligned code/data. Explicit `.segmentalign` and implicit `.align` requirements combine by using the strongest compatible power-of-two alignment.

For compiler-generated C26 objects, source `align(N)` is the user-facing spelling
for this layout-start constraint. The compiler accepts only compile-time positive
powers of two from 1 through 32768. It is intentionally separate from `page` /
`.pagecontain`: alignment constrains the first byte; page containment constrains
the complete object to one 256-byte page.


`.segmentprivate "SEGMENT"` records that the route belongs only to this object
component rather than defining a global cfg `SEGMENTS` rule for every object
using the same segment spelling. The linker reports private routes in the map.

`.callstackextra BYTES` records hardware-stack bytes consumed by assembly-only
calls, pushes, or stack-pointer use which are not visible in the compiler call
graph. The linker combines the component metadata with a generic
`callstack=callgraph` memory policy. Multiple declarations in one source must
agree; malformed constants and missing segments are assembly errors. A retained
cfg may duplicate a component constraint only when the region, alignment, and
hidden-stack byte count agree exactly.

These records complement `.pagecontain` and `.indexrange`, which remain the
hard page-placement metadata for complete layouts and timing-sensitive indexed
windows. Cartridge profile files describe hardware and allocatable memory; they
must not repeat component-specific constraints.

### `.pagecontain`

`.pagecontain` marks the current named segment as a hard page-contained o26 layout. It takes no arguments; keep one constrained object in that segment. The linker places the complete final-sized layout anywhere it fits within one 256-byte page.

### `.indexrange`

`.indexrange MAX_INDEX` requires offsets zero through `MAX_INDEX` from the
layout base to remain in one page. `.indexrange START_OFFSET, MAX_INDEX` applies
the same rule to a pointer beginning at `layout + START_OFFSET`. `MAX_INDEX`
must fit an 8-bit X/Y index and the complete declared range must lie within the
layout. The containing object may itself cross pages; only the timing-sensitive
effective-address window is hard. Use this for pointer-based or deliberately
partial table accesses whose legal index range cannot be inferred from the
object declaration.

After the layout table, current o26 objects also carry a compact relative-branch
table.  Each record preserves the coarse segment, packed source and target
offsets, actual branch opcode, and page policy. `B26\2` policy values encode
flexible, required-same-page, and required-crossing behavior; an omitted suffix
and explicit `.flex` serialize identically. Local-label branches are included
even though their displacement was fully resolved by the assembler. The records
are not relocations and never change branch bytes or displacements, but the
linker uses them both for final-address timing diagnostics and for its bounded
low-byte code-placement search.

Word relocations used by indirect `JMP` additionally carry the
`O26_RTYPE_INDIRECT_JMP` bit.  It does not change relocation arithmetic; it
identifies the final vector address for the linker's NMOS `$xxFF` hazard check.

The two low relocation-type bits preserve direct control-transfer intent:
ordinary data/address relocation, direct `JSR`, direct absolute `JMP`, or the
absolute `JMP` emitted while relaxing a conditional branch. The numeric
relocation arithmetic is unchanged. The bank-aware linker now uses direct
`JMP` intent to generate a common replicated cross-bank trampoline entry, keeps
direct `JSR` distinct for the pending return-stub implementation, and rejects
ROM-data and conditional-branch crossings. Ordinary two-byte relative branches
continue to live in the `B26` branch table; the relaxed long form carries both
its local inverse-branch record and conditional-branch intent on the generated
absolute target relocation.

Current version-2 o26 relocations against a symbol defined in the same object
also carry the exact serialized layout index containing that symbol. This is
required for affine expressions such as `table-$100`: after the constant is
applied, the packed numeric value may fall inside a different layout even
though the expression still denotes an address relative to `table`. The linker
must relocate against the defining layout, not guess a layout from the altered
numeric value. Imported-symbol relocations remain global-symbol plus addend and
do not carry a local layout index.
