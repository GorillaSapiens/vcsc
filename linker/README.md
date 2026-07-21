```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# vcsc-ld

`vcsc-ld` is a small standalone linker for the VCSC-specific `.o26` objects emitted by `vcsc-as`, plus `.l26` archives produced by `vcsc-ar`.

## Command line

`vcsc-ld` uses a GNU-`ld`-style command line.

```sh
./vcsc-ld [options] file...
```

Supported options:
- `-o FILE` ... write Intel HEX output, or a flat binary when `FILE` ends in `.bin` (default: `a.hex`)
- `-T FILE` ... use `FILE` as the linker config/script
- `--script=FILE` ... same as `-T FILE`
- `-Map FILE` or `-Map=FILE` ... write a linker map file
- `-h`, `--help` ... show usage
- `-v`, `--version` ... print the linker name

Inputs are ordinary positional `.o26` and `.l26` files and may appear before or after the options.

Examples:

```sh
./vcsc-ld -T runtime.cfg -o out.hex -Map out.map crt0.o26 main.o26 libstuff.l26
./vcsc-ld -T runtime.cfg -o out.hex crt0.o26 main.o26
./vcsc-ld runtime.cfg crt0.o26 main.o26 out.hex
```

The linker also accepts this positional form:

```sh
./vcsc-ld [layout.cfg] input1.o26 [input2.l26 ... inputN.o26] output.hex [output.map]
```

## What it does

- reads relocatable `.o26` object files
- reads `.l26` archives created by `vcsc-ar`
- treats both command-line `.o26` files and `.l26` archive members lazily
- pulls in only objects that satisfy required symbols or later unresolved imports
- warns when a command-line `.o26` file is not used
- warns when a command-line `.l26` archive is completely unused
- collects selected `__init`/`__init_*` functions into a linker-generated null-terminated `__init_table`
- lays out `TEXT`, `DATA`, `BSS`, and `ZEROPAGE`
- resolves imports against exports
- writes Intel HEX output or a contiguous flat binary selected by the `.bin` suffix
- writes the 6502 vector table at `$FFFA` through `$FFFF` using these symbols:
  - `__nmi`
  - `__reset`
  - `__irqbrk`
- generates linker-defined startup symbols for initialized data and BSS
- optionally writes a map file

Selection starts from the root symbols `__reset`, `__nmi`, and `__irqbrk`.
From there, `vcsc-ld` repeatedly scans inputs to satisfy unresolved imports, pulling in only the object files that define needed symbols, until no new objects are selected.

Vector order is the normal 6502 order:
- `$FFFA/$FFFB` ... NMI
- `$FFFC/$FFFD` ... RESET
- `$FFFE/$FFFF` ... IRQ/BRK

## Linker-generated symbols

`vcsc-ld` generates these absolute symbols automatically:

- `__data_load_start`
- `__data_load_end`
- `__data_run_start`
- `__data_run_end`
- `__data_size`
- `__bss_start`
- `__bss_end`
- `__bss_size`
- `__init_table`
- `__stack_start`
- `__stack_top`

These are intended for startup code. `__init_table` points at a null-terminated table of 16-bit function addresses collected from selected object files that export `__init` or `__init_*`.

Typical `vcsc-ld` usage:
- copy initialized writable data from ROM at `__data_load_start` to RAM at `__data_run_start`
- copy `__data_size` bytes
- zero BSS starting at `__bss_start`
- zero `__bss_size` bytes

Conceptually:

```asm
; copy DATA from ROM load address to RAM run address
src = __data_load_start
src_end = __data_load_end

dst = __data_run_start

; zero BSS
bss = __bss_start
bss_end = __bss_end
```

If there is no initialized DATA or no BSS, the corresponding size symbol will be zero. `__stack_start` and `__stack_top` mark the bottom and top bytes of the remaining free RAM arena. The stock runtime provides neither a software stack, a frame pointer, nor a heap allocator.

## Linker script requirement

`vcsc-ld` has no implicit machine or memory map. Direct use requires `-T FILE`,
`--script=FILE`, or the compatibility positional `.cfg` argument. This keeps a
generic host-style layout from silently leaking into VCS builds. The high-level
`vcsc` driver supplies the bundled unbanked 4K VCS script automatically when
the user does not provide `-T`.

## Config support

`vcsc-ld` intentionally keeps the config parser simple. It understands the style shown above:
- `MEMORY { ... }`
- `SEGMENTS { ... }`
- `start = $1234`
- `size = $2000`
- `load = NAME`
- `run = NAME`
- `type = ro/rw/zp/data/bss`
- `define = yes/no`
- `callstack = callgraph/no`
- `callstack_extra = N` on the same writable region to reserve additional top-of-memory hardware-stack bytes required by included or separately assembled code

`callstack = callgraph` may be placed on one writable `MEMORY` region. After
all objects and archive members are selected, the linker computes the longest
acyclic source-level call path and shrinks that region from the top before
placing DATA/BSS/ZEROPAGE. The reserve is two bytes per function level for
active JSR return addresses, plus one fixed two-byte allowance when the selected
objects contain one or more runtime initializer functions. The extra pair holds
the stock startup's init-table cursor while it calls an initializer.

`callstack_extra = N` adds an explicit byte count to that reserve. It is for
stack use known by a source-integration contract but hidden from compiler call
metadata, such as an internal JSR in an included assembly kernel. It is rejected
unless the same region also uses `callstack = callgraph`. The selected value is
reported in the map and exported as `__call_stack_extra`; it does not attempt to
infer arbitrary inline-assembly pushes or stack-pointer manipulation.

Compiler-generated ordinary calls do not push parameter, return, or scratch-
base state. Assembly integrations remain responsible for declaring enough
`callstack_extra` space and for restoring S before returning to compiled code.

It is not trying to be a full `ld65` config parser.
## Compiler mem-region validation

Objects produced by `vcsc-cc1` include hidden metadata for each `mem` region that was used for symbol-backed storage. Before layout, `vcsc-ld` compares that metadata with the config `MEMORY` table.

The linker rejects the image if the config is missing the region, or if the `start`, `size`, or `type` differs from the compiler's `mem` declaration. The diagnostic reports both sides and tells the user to update either the N source declaration or the linker cfg so they match.

Named zero-page regions use suffixed zero-page segments such as `ZEROPAGE.register`, so the cfg must contain a matching `MEMORY` entry for the region name when such a region is used.


## Segment mapping

For the current object format subset, `vcsc-ld` maps o26 segments like this:
- o26 `TEXT` -> linker `CODE`
- o26 `DATA` -> linker `DATA`
- o26 `BSS` -> linker `BSS`
- o26 `ZP` -> linker `ZEROPAGE`

`DATA` bytes are stored in ROM in the output image, but symbols and relocations referring to `DATA` use the RAM run address.

## Map file

When you request a map file, `vcsc-ld` writes:
- effective memory regions after any call-graph stack reservation
- object placement
- the selected call-stack region, graph depth, byte reserve, and physical range
- linker-generated symbols
- all resolved global symbols

A call-graph-sized image also exports `__call_stack_depth`,
`__call_stack_extra`, `__call_stack_size`, `__call_stack_start`, and
`__call_stack_top`.

## Supported o26 subset

This linker is aimed at the object files generated by the companion assembler work. It supports:
- 16-bit object-mode o26 files
- 6502 text/data/bss/zp segments
- undefined symbol list
- exported global symbols
- low-byte, high-byte, and 16-bit word relocations
- absolute symbols

## Limitations

- branch relocations are not supported
- the linker accepts only the VCSC o26 magic and version emitted by the current `vcsc-as`
- the config parser is intentionally small and only covers the needed subset
- Intel HEX is emitted as sparse data records rather than one giant padded image dump
- Flat binary output spans the lowest through highest used address and fills internal gaps with `$FF`; a conventional VCS layout therefore produces exactly 4096 bytes for `$F000-$FFFF`

## Building

```sh
make
```


## Weak symbols

`vcsc-ld` supports a custom weak-symbol convention.
When a reference to `foo` cannot be satisfied by a strong exported `foo`, the linker falls back to `__weak_foo`.
Resolution is symbol-driven and left-to-right over the command line, but strong definitions are preferred globally over weak fallbacks for the same symbol.
For `.l26` inputs, only the single member object that defines the selected symbol is pulled in.
This matches the assembler's `.weak foo` directive, which exports a weak definition under the external name `__weak_foo`.
