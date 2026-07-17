# n65ld

`n65ld` is a small standalone linker for the 6502-oriented `.o65` objects emitted by this project family, plus `.a65` archives produced by `n65ar`.

## Command line

`n65ld` uses a GNU-`ld`-style command line.

```sh
./n65ld [options] file...
```

Supported options:
- `-o FILE` ... write Intel HEX output, or a flat binary when `FILE` ends in `.bin` (default: `a.hex`)
- `-T FILE` ... use `FILE` as the linker config/script
- `--script=FILE` ... same as `-T FILE`
- `-Map FILE` or `-Map=FILE` ... write a linker map file
- `-h`, `--help` ... show usage
- `-v`, `--version` ... print the linker name

Inputs are ordinary positional `.o65` and `.a65` files and may appear before or after the options.

Examples:

```sh
./n65ld -T runtime.cfg -o out.hex -Map out.map crt0.o65 main.o65 libstuff.a65
./n65ld -o out.hex crt0.o65 main.o65
./n65ld crt0.o65 main.o65 out.hex
```

The linker also accepts this positional form:

```sh
./n65ld [layout.cfg] input1.o65 [input2.a65 ... inputN.o65] output.hex [output.map]
```

## What it does

- reads relocatable `.o65` object files
- reads `.a65` archives created by `n65ar`
- treats both command-line `.o65` files and `.a65` archive members lazily
- pulls in only objects that satisfy required symbols or later unresolved imports
- warns when a command-line `.o65` file is not used
- warns when a command-line `.a65` archive is completely unused
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
From there, `n65ld` repeatedly scans inputs to satisfy unresolved imports, pulling in only the object files that define needed symbols, until no new objects are selected.

Vector order is the normal 6502 order:
- `$FFFA/$FFFB` ... NMI
- `$FFFC/$FFFD` ... RESET
- `$FFFE/$FFFF` ... IRQ/BRK

## Linker-generated symbols

`n65ld` generates these absolute symbols automatically:

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

Typical `n65ld` usage:
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

If there is no initialized DATA or no BSS, the corresponding size symbol will be zero. `__stack_start` marks the bottom of the remaining free RAM arena for the upward-growing N stack, and `__stack_top` marks the top free byte of that same arena for downward-growing `sbrk` use.

## Default memory layout

If no config file is supplied, `n65ld` uses this built-in layout:

```cfg
MEMORY {
    ZEROPAGE: start = $0000, size = $0100, type = rw, define = yes;
    CPUSTACK: start = $0100, size = $0100, type = rw, define = yes;
    RAM:      start = $0200, size = $1E00, type = rw, define = yes;
    ROM:      start = $2000, size = $E000, type = ro, define = yes;
}

SEGMENTS {
    ZEROPAGE: load = ROM, run=ZEROPAGE, type = zp,   define = yes;
    CODE:     load = ROM,          type = ro,   define = yes;
    RODATA:   load = ROM,          type = ro,   define = yes;
    BSS:      load = RAM,          type = bss,  define = yes;
    DATA:     load = ROM, run=RAM, type = data, define = yes;
}
```

## Config support

`n65ld` intentionally keeps the config parser simple. It understands the style shown above:
- `MEMORY { ... }`
- `SEGMENTS { ... }`
- `start = $1234`
- `size = $2000`
- `load = NAME`
- `run = NAME`
- `type = ro/rw/zp/data/bss`
- `define = yes/no`

It is not trying to be a full `ld65` config parser.
## Compiler mem-region validation

Objects produced by `n65c` include hidden metadata for each `mem` region that was used for symbol-backed storage. Before layout, `n65ld` compares that metadata with the config `MEMORY` table.

The linker rejects the image if the config is missing the region, or if the `start`, `size`, or `type` differs from the compiler's `mem` declaration. The diagnostic reports both sides and tells the user to update either the N source declaration or the linker cfg so they match.

Named zero-page regions use suffixed zero-page segments such as `ZEROPAGE.register`, so the cfg must contain a matching `MEMORY` entry for the region name when such a region is used.


## Segment mapping

For the current object format subset, `n65ld` maps o65 segments like this:
- o65 `TEXT` -> linker `CODE`
- o65 `DATA` -> linker `DATA`
- o65 `BSS` -> linker `BSS`
- o65 `ZP` -> linker `ZEROPAGE`

`DATA` bytes are stored in ROM in the output image, but symbols and relocations referring to `DATA` use the RAM run address.

## Map file

When you request a map file, `n65ld` writes:
- memory regions
- object placement
- linker-generated symbols
- all resolved global symbols

## Supported o65 subset

This linker is aimed at the object files generated by the companion assembler work. It supports:
- 16-bit object-mode o65 files
- 6502 text/data/bss/zp segments
- undefined symbol list
- exported global symbols
- low-byte, high-byte, and 16-bit word relocations
- absolute symbols

## Limitations

- branch relocations are not supported
- this is not a general-purpose o65 linker for every historical toolchain variant on earth
- the config parser is intentionally small and only covers the needed subset
- Intel HEX is emitted as sparse data records rather than one giant padded image dump
- Flat binary output spans the lowest through highest used address and fills internal gaps with `$FF`; a conventional VCS layout therefore produces exactly 4096 bytes for `$F000-$FFFF`

## Building

```sh
make
```


## Weak symbols

`n65ld` supports a custom weak-symbol convention.
When a reference to `foo` cannot be satisfied by a strong exported `foo`, the linker falls back to `__weak_foo`.
Resolution is symbol-driven and left-to-right over the command line, but strong definitions are preferred globally over weak fallbacks for the same symbol.
For `.a65` inputs, only the single member object that defines the selected symbol is pulled in.
This matches the assembler's `.weak foo` directive, which exports a weak definition under the external name `__weak_foo`.
