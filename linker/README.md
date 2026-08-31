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
- `-Map FILE`, `-Map=FILE`, or `--map=FILE` ... rename the linker map
- `-Sym FILE`, `-Sym=FILE`, or `--sym=FILE` ... rename the Stella/DASM symbol file
- `-List FILE`, `-List=FILE`, or `--list=FILE` ... rename the Stella/DASM list file
- `-Cfg FILE`, `-Cfg=FILE`, or `--cfg=FILE` ... rename the Stella/DiStella config file
- `--no-map`, `--no-sym`, `--no-list`, `--no-cfg` ... suppress an individual sidecar
- `--bank-placement=optimized|simple` ... select the automatic bank-placement policy (`optimized` is the default)
- `--explain-bank-placement` ... write a component-by-component placement trace to standard error
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
- automatically selects the compact stock startup for simple RIOT-RAM-only
  initialization and preserves the full stock startup when DATA, runtime
  initializers, or cartridge/split RAM require it
- generates linker-defined startup tables for the full startup path
- writes same-stem `.map`, `.sym`, `.lst`, and `.cfg` sidecars by default

## Debugger sidecars

For `game.bin`, a successful link normally writes `game.map`, `game.sym`,
`game.lst`, and `game.cfg` beside it. Stella automatically consumes the latter
three when its debugger opens. The symbol file contains final ROM and RAM addresses. The list file is a
human-readable final linked listing: each maintained C26/S26 source statement is
shown before the generated assembly it produced, with final linked logical
addresses, relocated bytes, and readable assembler text. Three-byte 6502
instructions also show their resolved 16-bit operand (`=> $xxxx`), so split
read/write aliases such as Superchip RAM are visible directly. Compiler-created
code without a source statement is labeled `<compiler-generated>`; linker tables,
vectors, legacy-object bytes, and other unattributed material are retained in a
separate section instead of being hidden. DASM-compatible RAM constant rows are
preserved so Stella can continue consuming the same `.lst` sidecar. The
DiStella config classifies known executable layouts as `CODE` and all other
occupied bytes as `DATA`; font, graphics, color, and audio ranges can be refined
later with Stella's debugger.

The `.map` file is VCSC's fuller layout/usage report; Stella does not consume
it. VCSC deliberately does not create a ROM-specific `.script`, because Stella
uses that file for user-owned breakpoints, traps, watches, and debugger setup.

If the default same-stem `.cfg` name is already the linker script itself, the
linker preserves that input file and omits only the generated DiStella config.
Use `-Cfg OTHER_FILE` when a separate name is useful. Explicit output-name
collisions are errors.

Selection starts from the root symbols `__reset`, `__nmi`, and `__irqbrk`.
From there, `vcsc-ld` repeatedly scans inputs to satisfy unresolved imports, pulling in only the object files that define needed symbols, until no new objects are selected.

In banked links, lazy archive selection is unchanged.  Once selected, an archive
member participates in the same hard placement constraints and automatic bank
placement as a command-line object.  The map preserves the
`archive.l26(member.o26)` origin on each placed layout and symbol, reports the
member's logical bank/region, and lists every cross-bank bridge it caused.
Stella `.sym` and `.lst` sidecars use the final mirrored logical addresses, not
physical file offsets.

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
- `__copy_table`
- `__zero_table`
- `__init_table`
- `__stack_start`
- `__stack_top`

These are intended for the full startup code. `__init_table` points at a
null-terminated table of 16-bit function addresses collected from selected
object files that export `__init` or `__init_*`. The compact stock startup does
not import these tables, so the linker omits the table storage and symbols when
it selects that path.

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

The legacy contiguous DATA/BSS symbols remain available when applicable.
`__copy_table` and `__zero_table` are the authoritative object-by-object startup
records. Each copy record contains ROM load address, runtime write address, and
size; each zero record contains runtime write address and size. Consequently a
split-address object is allocated once but initialized through its write alias.
The map's `STARTUP INITIALIZATION` section reports each object's load, readable
runtime address, writable runtime address, size, and `split=yes` when the aliases
differ. Its policy line is `every-reset bss=zero data=copy-through-write-alias` for the
full startup. A compact selection reports `policy=compact-riot-clear`; any ZERO
rows shown there are informational objects satisfied by the blanket RIOT clear,
and the generic startup tables are not generated.

If there is no initialized DATA or no BSS, the corresponding table is empty and
the legacy size symbol is zero. `__stack_start` and `__stack_top` mark the bottom
and top bytes of the remaining free RAM arena. The stock runtime provides neither
a software stack, a frame pointer, nor a heap allocator.

## Linker script requirement

`vcsc-ld` has no implicit machine or memory map. Direct use requires `-T FILE`,
`--script=FILE`, or the compatibility positional `.cfg` argument. This keeps a
generic host-style layout from silently leaking into VCS builds. The high-level
`vcsc` driver supplies the bundled unbanked 4K VCS script automatically when
the user does not provide `-T`.

## Config support

`vcsc-ld` intentionally supports a small, strict cfg language. Unknown blocks,
properties, malformed entries, and duplicate names are errors rather than being
silently ignored. It understands:

- `CARTRIDGE { ... }` for banked mapper and fill metadata
- `BANKS { ... }` for complete physical bank units
- `MEMORY { ... }`
- `SEGMENTS { ... }`
- `start = $1234`
- `size = $2000`
- `load = NAME`
- `run = NAME`
- `type = ro/rw/zp/data/bss`
- `define = yes/no`
- `align = N` on a segment rule, where N is a power of two
- `callstack = callgraph/no`
- `callstack_extra = N` on the same writable region to reserve additional top-of-memory hardware-stack bytes required by included or separately assembled code
- `read_hazard = yes/no` on a `MEMORY` region whose write/start window has side effects when the CPU performs a read bus cycle
- `bank = NAME` on a cartridge-output `MEMORY` region in a banked profile
- `mapper = F8/F6/F4/FE`, `fillval = BYTE`, `trampoline = OFFSET`,
  `trampolinesize = SIZE`, and `vectorbridge = OFFSET` inside `CARTRIDGE`
- `start`, `size`, `hotspot`, and `startup = yes/no` on a named `BANKS` entry

### C26 cartridge topology metadata

The compiler may carry an explicit output topology in ordinary `.o26` metadata:

```vcsc
cartridge { $fill:0xff };

bank low {
   $image_size:0x1000 $file_index:0 $image_offset:0
   $link_start:0x3000 $cpu_start:0x3000 $map_size:0x1000
};

bank rom {
   $image_size:0x1000 $file_index:1 $image_offset:0
   $link_start:0xf000 $cpu_start:0xf000 $map_size:0x1000
};
```

A bank without `$select_access` is directly mapped. All direct CPU mappings must
be nonoverlapping. One direct region may carry `$startup`; for a selector-free
topology that marker names only the startup/home placement region and does not
request wrong-bank recovery, selector accesses, vector bridges, or trampolines.
Cross-chunk calls, jumps, and data references remain ordinary absolute operations.
Flat output is emitted
in `$file_index` order with each physical chunk padded to `$image_size` using the
cartridge fill byte. An optional C26 `$signature:TEXT` is 1-4 ASCII alphanumeric
bytes; it is NUL-padded to four bytes and emitted eight bytes before the end of
the last CPU-mapped bank in file order; later `$data_only` chunks are not
modified. For the usual 4K banks this is `$0FF8-$0FFB`;
for a 2K CV image it is `$07F8-$07FB`. This is raw image metadata, so hotspot addresses are safe
locations: autodetection reads the file before mapper hardware exists, while on
hardware the access address, not the stored byte value, causes selection. No
selector, vector bridge, or trampoline is generated merely because multiple
direct banks exist.

FE/SCABS is one deliberate exception to the ordinary nonoverlapping-direct
rule. A C26 cartridge with signature `FE`, exactly two 4K banks, file bank 0
linked/visible at `$F000`, file bank 1 linked/visible at `$D000`, and startup on
bank 0 is recognized as `mode=fe-delayed`. Those aliases describe alternate
mapper states, not simultaneously visible direct regions. FE has no generated
selector hotspot or trampoline corridor: automatic ROM remains in startup bank
0, explicit `bank1` placement is allowed, and only a direct cross-bank JSR from
top-level `main` is accepted. Nested cross-bank calls and cross-bank data, JMP,
or branch relocations are rejected because the released FE protocol depends on
the exact `$01FE` stack-bus sequence rather than a generic bridge.

A bank with `$select_access` is selector-controlled. CPU-mapped banks in the
current selector model must have the same full-window shape, selectors must be
unique within `$1000-$1fff`, exactly one CPU bank must carry `$startup`, and the
cartridge must supply bounded, nonoverlapping trampoline, vector-bridge, and
vector ranges. The current implementation deliberately rejects a mixture of
direct and selector-controlled CPU banks; independently switched windows require
a later explicit window/device model.

A topology bank may instead carry `$data_only`. Such a bank has physical image
size and file index but no CPU/link mapping, selector, or startup state. Source
objects reach it through a read-only `mem` declaration with
`$data_bank:bankName` and no `$start`. Allocation is in bank-local file-offset
space, flat output includes the bytes normally, and the map reports
`mode=data-only`. Executable layouts and ordinary CPU-address relocations to
these objects are link errors. The DPC profile uses this for its 2K display ROM
and 255-byte Poly8 tail while retaining two ordinary F8-style program banks.

After lazy archive selection, identical topology declarations merge across
objects. Conflicting declarations identify both origins. The linker validates
dense unique file indices, image offsets and mapped bounds, nonoverlapping
synthetic link mappings, direct CPU mappings, selectors, startup cardinality,
and generated ranges. The map contains a `C26 CARTRIDGE TOPOLOGY` section with
the output size, fill, generated ranges, physical order, mappings, access mode,
selector, startup status, and defining object.

C26 topology is authoritative for physical output packaging and selector
machinery, and complete C26 `mem` declarations are authoritative for allocator
geometry and ordinary segment routing. When C26 topology is present, the linker
constructs its internal direct or selector-controlled bank model from those
records; a cfg `CARTRIDGE` or `BANKS` block is neither required nor consulted.
The reduced VCS compatibility cfg retains only operational properties such as
call-stack reservation. Legacy profile cfg files remain accepted when no C26
topology is present and are exercised by differential tests. A legacy cfg bank
tag cannot turn an authoritative writable or split-address C26 region into
bank-local storage; those regions remain shared and their stale association is
discarded.

Command-line objects carrying complete `cartridge`, `bank`, or `mem` metadata
are selected even when they contain no ordinary referenced symbol. This permits
an inspectable profile to be compiled as a configuration-only C26 input. Source
which uses a named placement modifier must instead include the profile so the
compiler can resolve that `mem` name while compiling the declaration.

### Destructive CPU read/dummy-read hazards

A C26 `mem` declaration may carry `$read_hazard`; legacy cfg input expresses the
same property as `read_hazard = yes`. For a split-address region the hazardous
range is its write alias, and for a single-address region it is the ordinary
start/size range. This models devices such as Superchip cartridge RAM where a
CPU read cycle to the write port is not harmless.

Before placement is finalized, `vcsc-ld` derives constraints from relocatable
6502 operands whose statically knowable reads or dummy reads could enter one of
those ranges. It models the final linked NMOS bus behavior for all 256 opcode
bytes, including unofficial encodings and handwritten `opXX` assembly. Covered
static cycles include instruction/operand fetches, zero-page indexed dummy
reads, absolute indexed page-cross/pre-write/RMW reads, indirect pointer reads,
JMP-indirect vector reads, branch dummy reads, stack-read cycles, BRK/vector
reads, implied/accumulator next-PC reads, and KIL/JAM reads. Runtime-computed
indirect effective addresses and return targets cannot be inferred by the
linker and therefore are not guessed.

When the referenced object is movable, the linker keeps the instruction and its
timing unchanged and chooses a placement that makes every statically considered
bus read safe. If fixed handwritten assembly or other placement constraints
leave a hazardous read, the link fails with the final PC/operand, bus-cycle kind,
hazardous address/range, mapper memory name, and available source/assembly
provenance. A stable indexed STA pre-read of the exact write-port byte that the
same instruction immediately overwrites is permitted; wrong-high-byte dummy
reads and RMW pre-reads remain hazards.

### C26 cartridge-profile foundation

Public VCS cartridge topology is described by inspectable C26 profile files.
For example, the F8 profile declares the output-wide fill policy, two physical
4K chunks, their selector-controlled CPU mappings, and the allocatable ROM
inside each synthetic linker range:

```c
cartridge {
    $fill: 0xff
    $trampoline_offset: 0x0f00
    $trampoline_size: 0x00e0
    $vector_bridge_offset: 0x0fe0
    $vector_bridge_size: 0x0012
    $vectors_offset: 0x0ffa
    $vectors_size: 0x0006
};

bank bank0 {
    $image_size: 0x1000
    $file_index: 1
    $image_offset: 0x0000
    $link_start: 0xf000
    $cpu_start: 0xf000
    $map_size: 0x1000
    $select_access: 0x1ff9
    $startup
};

bank bank1 {
    $image_size: 0x1000
    $file_index: 0
    $image_offset: 0x0000
    $link_start: 0xd000
    $cpu_start: 0xf000
    $map_size: 0x1000
    $select_access: 0x1ff8
};

mem bank0 { $start:0xf000 $size:0x0f00 $ro $priority:2 };
mem bank1 { $start:0xd000 $size:0x0f00 $ro };
```

The installed `4K/mapper.c26`, `F8/mapper.c26`, `FA/mapper.c26`, `FA2/mapper_24k.c26`,
`FA2/mapper_28k.c26`, `F6/mapper.c26`, `F4/mapper.c26`, and matching RAM/Superchip files are the certified public
profiles. `vcs.c26` describes the common machine only; the driver implicitly
adds `4K/mapper.c26` when no explicit `-T` profile selection is made. Public
banked builds pass the reduced `vcs.cfg` for operational policy and add one C26
profile as a normal configuration input or source include. The old full profile
cfg files remain accepted for compatibility, differential certification, and
simulator mapper selection, but no longer define public-build topology.

Each profile names every ordinary allocatable region `bankN`, reserves the
final generated corridor through the cartridge declaration, and derives bank
behavior entirely from declared values rather than filenames. Superchip
profiles keep 4K physical chunks while mapping ROM from physical offset `$0100`
and declare the shared split-address RAM separately. FA also keeps complete 4K
chunks but begins ROM at physical offset `$0200` because its 256-byte write and
256-byte read RAM ports occupy the first 512 bytes. The selector-free
The test-only `test/vcs_direct_8k.c26` profile proves that the same topology model also packages
directly mapped output chunks without hotspots or trampolines.

The linker treats three identities as separate: the VCSC logical `BANKn`
name, the zero-based physical/file chunk index, and the mapper selector hotspot.
Do not read an external phrase such as "bank 0" as VCSC `BANK0` unless it
explicitly means the `$F000` home-bank namespace.

VCSC writes complete 4K chunks in ascending logical-address order.  Mapper
hotspots increase with physical/file chunk index, so they run in the opposite
direction from VCSC logical bank numbers:

```text
mapper  file index  VCSC bank  linker range  selector
------  ----------  ---------  ------------  --------
F8      0           BANK1      $D000-$DFFF   $1FF8
        1           BANK0      $F000-$FFFF   $1FF9

FA      0           BANK2      $B000-$BFFF   $1FF8
        1           BANK1      $D000-$DFFF   $1FF9
        2           BANK0      $F000-$FFFF   $1FFA

F6      0           BANK3      $9000-$9FFF   $1FF6
        1           BANK2      $B000-$BFFF   $1FF7
        2           BANK1      $D000-$DFFF   $1FF8
        3           BANK0      $F000-$FFFF   $1FF9

F4      0           BANK7      $1000-$1FFF   $1FF4
        1           BANK6      $3000-$3FFF   $1FF5
        2           BANK5      $5000-$5FFF   $1FF6
        3           BANK4      $7000-$7FFF   $1FF7
        4           BANK3      $9000-$9FFF   $1FF8
        5           BANK2      $B000-$BFFF   $1FF9
        6           BANK1      $D000-$DFFF   $1FFA
        7           BANK0      $F000-$FFFF   $1FFB
```

Equivalently, `file_index(BANKn) = bank_count - 1 - n`, and the selector is the
mapper's first hotspot plus that file index.  The linker validates the complete mapper table from logical starts and
hotspots and requires exactly one entry marked `startup=yes`. Bank labels are
configuration names rather than semantic `BANK0`/`BANK1` tokens; the public
profiles retain those conventional labels and place their startup bank in the
final file chunk.

Selector hotspots inside the cartridge `$1000-$1FFF` window are reserved at the same low twelve-bit offset in every
bank. An ordinary `ro` or `data` segment region covering such a selector is
rejected before placement, so code or ordinary ROM data cannot land on an
address whose access changes the selected bank. Selectors below `$1000`, such as
0840/EconoBanking `$0800/$0840` and UA/UASW `$0220/$0240`, are physical bus triggers rather than cartridge
ROM addresses and therefore reserve no corresponding `$Fxxx` bytes. The configured `trampoline`
corridor and `vectorbridge` corridor are reserved the same way. The trampoline
corridor must fit wholly below the final six vector bytes, and neither generated
corridor may overlap the other or a selector hotspot.

The current vector bridge is eighteen bytes: byte-identical NMI, RESET, and
IRQ/BRK entries are copied at that physical offset in every bank. For ordinary
cartridge-window selectors each entry is `BIT BANK0_HOTSPOT; JMP handler`. For
below-window selectors the access is undocumented NMOS `NOP absolute` (`$0C`)
instead, preserving registers/flags without writing the mirrored console device. The final six bytes of every bank contain the
same vector words, using BANK0's logical mirror of those three entries, before
optional cartridge metadata is applied. This makes RESET and IRQ/BRK
deterministic from every initially selected bank. When a cartridge signature is
present, its final two bytes replace `$xFFA/$xFFB` only in the final physical
bank, so that bank deliberately no longer carries a usable NMI vector. This is
safe on the Atari 2600 because the 6507 has no NMI input; F4 may therefore use
its `$1FFA/$1FFB` selector hotspots as signature storage without depending on a
hypothetical NMI fetch. RESET at `$xFFC/$xFFD` and IRQ/BRK at `$xFFE/$xFFF`
remain ordinary vectors in every bank. The handlers and `main` must remain in
BANK0.

Flat banked output must use `.bin`. The writer emits complete 4096-byte units in
ascending logical-address order, filling unoccupied bytes with the cartridge
fill value. Thus F8 writes VCSC BANK1 as physical/file chunk 0 and VCSC BANK0 as
chunk 1. VCSC BANK0 occupies the final 4K of every F8/F6/F4 image. The map
reports mapper, exact output size, trampoline and vector-bridge reservations,
each VCSC bank's selector, startup status, and physical file offset.

After final placement, the linker classifies every symbolic relocation by the
configured bank containing its serialized source bytes and the bank owning its
target symbol/address.  Same-bank ROM references and references to nonbanked
RAM or hardware continue normally.  Cross-bank ROM data references are hard
errors, including low-byte, high-byte, word, pointer-initializer, and indirect-
`JMP` vector relocations.  Retained relative branches and relaxed long
conditional branches are also rejected when their final target occupies a
different bank.

Current o26 objects preserve direct `JSR`, direct absolute `JMP`, and relaxed
conditional-branch intent in the relocation type. The linker therefore
distinguishes trampoline-eligible control flow from forbidden ROM-data
references without guessing from neighboring opcode bytes.

A proven direct cross-bank `JMP` is redirected to a deduplicated eight-byte
entry in the common trampoline corridor. The linker emits the occupied portion
of that corridor byte-for-byte identically at the same physical offset in every
bank:

```asm
    STA destination_hotspot
    JMP (inline_target_pointer)
inline_target:
    .word final_target
```

`STA` is intentional for cartridge-window selectors: F8/F6/F4 react to the hotspot access, while the store
preserves A and all processor flags just as the original direct `JMP` would.
The indirect pointer uses BANK0's logical mirror of the inline target word. The
upper mirror bits are absent from the cartridge bus, so after the bank switch it
still reads the same low-twelve-bit bytes from the selected physical bank. Every
bank contains identical entry bytes, which is required because instruction
fetch continues in the newly selected bank immediately after the hotspot
access.

Below-window selector trampolines (0840/EconoBanking, UA/UASW, and 0FA0) substitute NMOS
absolute NOP-read opcode `$0C` for those selector stores. The undocumented NOP
performs the required bus read while preserving A/X/Y and processor flags, so a
mapper transition does not also write a mirrored TIA/RIOT register.

Entries are deduplicated by final target address and destination hotspot. Each
jump site receives its source bank's logical mirror of the common entry offset.
The allocator inserts a fill byte when necessary so the inline pointer never
begins at `$xxFF`, avoiding the NMOS 6502/6507 indirect-`JMP` page-wrap bug. A
full corridor is a link error. The map reports reserved, occupied, and total
replicated bytes plus every generated target entry.

The public selector-controlled direct-call ABI is defined in
[`../BANKSWITCHING.md`](../BANKSWITCHING.md). Its target linked form is:

```asm
    JSR __bankcall
    .banktarget final_target    ; 16-bit CPU target + 1-byte destination descriptor
```

Under that ABI `.banktarget` occupies three bytes. The target address says where
to enter after selection; the opaque mapper descriptor says which bank/state to
select. The caller bank's source descriptor is baked into its fixed
mapper-specific replicated entry/return instance, pushed as call-frame metadata,
and consumed directly by the return half before the final `RTS` to the unchanged
logical continuation PC. Same-bank calls remain ordinary JSRs. This removes the
old requirement that either source or destination bank be recoverable from a
16-bit PC and allows multiple banks to share one CPU link window.

The linker emits the descriptor ABI now. F8/F8SC/F6/F6SC/F4/F4SC, FA, DPC,
FA2-24/28, and JANE use 69-byte descriptor-aware blocks with 72 bytes reserved
(`generic-jsr=$048`); each bank copy has its own patched source descriptor.
0840, UA/UASW, and 0FA0 remain pending: their call sites already carry the third
byte, but their mapper-local trampolines still skip it and use the previous
PC-derived selector logic. They consume no per-target JSR entries while being
migrated one family at a time.

Call-bundle page carry, indivisible placement, A:X preservation, nested LIFO
returns, hardware-stack accounting, and ordered source/destination diagnostics
remain required. The descriptor ABI advances the original stacked return PC by
three inline bytes rather than two.

Cross-bank ROM data and conditional branches remain permanent errors.
Diagnostics identify the input object, source layout/address/bank, target
symbol/address/bank, and the failed rule. Raw numeric addresses contain no
relocation and cannot be checked by the linker.

### Deterministic automatic multi-region placement

Compiler-private unmarked `CODE.__vcsc_function$...` and
`RODATA.__vcsc_object$...`/`RODATA.__vcsc_page$...` layouts are movable whenever
a cartridge topology exposes multiple compatible read-only placement regions.
This policy applies both to selector-controlled banks and selector-free directly
addressed regions. Explicit named source `mem` modifiers produce `CODE.region`
or `RODATA.region` private layouts and are hard pins to that exact MEMORY
region. An unqualified `main`, startup/non-private runtime layouts, and private
runtime functions using reserved implementation names beginning with `_` are
pinned to the unique region marked `$startup`. An explicit contradictory
placement of `main` or an `_` startup/runtime helper is a link error. The
compiler does not interpret region names such as `bank0`; public profiles merely
use those names conventionally.

Writable-memory placement is deliberately separate. Ordinary unqualified
DATA/BSS/ZEROPAGE continue to use the configured default writable region, while
named regions such as `cartram` remain programmer-selected. The linker does
not spill an object from zero page into cartridge RAM automatically; code and
assembly may depend on zero-page addressing and timing.

Before assigning addresses, the linker classifies relationships between ROM
layouts according to the topology:

- in selector-controlled cartridges, every ordinary nonreplicated ROM data/address
  relocation and every retained branch is a hard same-bank edge;
- selector-controlled direct JSR and direct absolute JMP edges are soft because
  the common trampoline table can bridge them;
- repeated selector-controlled soft edges accumulate deterministic static weights
  equal to each bridge form's payload and one-execution penalty: 15 bytes and 25
  extra cycles per JSR relocation site, or 8 bytes and 6 extra cycles per JMP
  site;
- in selector-free direct mappings, absolute JSR/JMP/data references between
  regions are ordinary 16-bit references and create neither same-region unions
  nor trampoline/cut costs;
- retained relative branches and explicit layout constraints remain hard where
  the instruction encoding requires them.

Hard edges are collapsed transitively into indivisible components. A component
inherits any explicit or mandatory pin carried by a member; incompatible pins
are rejected before address layout. Fixed initialized-data images and generated
copy/zero/init tables remain fixed ROM consumers.

For each logical placement region, the largest owned `type=ro` MEMORY entry is
its default automatic-placement region. Both placement modes assign pinned
components first and preserve all hard constraints:

- `optimized`, the default, orders movable components by decreasing byte size,
  decreasing soft-edge byte degree, then stable object/layout order. It selects
  the compatible region that minimizes incremental selector-switch cut cost,
  using deterministic startup/address/name preference for ties. A deterministic
  local search then repairs profitable selector-controlled moves without
  increasing weighted hardware-return depth.
- `simple` ignores the soft-edge graph, takes movable components in stable input
  order, and uses the normal deterministic region preference. It exists for
  straightforward packing and optimizer comparisons.

The preliminary byte ledger provides a fast capacity filter, but it is not the
final authority: before a candidate assignment is accepted, the linker now
dry-runs the actual ROM allocator in source order, including alignment,
page/branch low-byte constraints, holes, initialized-DATA load images, and the
generated copy/zero/init tables. This prevents a raw-byte fit from becoming a
later layout overflow. Functions and private RODATA layouts remain whole; they
are never split across regions.

Ties prefer the startup/home region, then the higher logical address, then the
region name. `--explain-bank-placement` remains the compatibility spelling for
the diagnostic interface and reports both switched banks and direct regions.
The map's `BANK PLACEMENT` section records mode, component number, pinned or
automatic assignment, logical region, concrete MEMORY region, component bytes,
incident cut weight, layout, and input object. A `TRAMPOLINES` section appears
only when the selected topology actually requires selector-controlled bridges.
Through the public driver, pass the controls with, for example,
`-Wl,--bank-placement=simple,--explain-bank-placement`.

`callstack = callgraph` may be placed on one writable `MEMORY` region. After
all objects and archive members are selected, the linker computes the longest
acyclic source-level call path. For statically configured banked functions it
also computes a weighted depth which adds one hardware-return slot for every
simultaneously active cross-bank call edge. The region is shrunk from the top
before placing DATA/BSS/ZEROPAGE. The reserve is two bytes per weighted active return slot. Because stock startup
tail-jumps to `main`, the entry into `main` contributes no slot; its ordinary
callee edges do. The reserve also includes one fixed two-byte allowance when the
selected objects contain one or more runtime initializer functions. The extra
pair holds the full startup's init-table cursor while it calls an initializer.
Selecting the full table-driven startup also reserves its real two-byte transient
PHA/PLA workspace; the compact startup has no such hidden stack requirement.

The map preserves the ordinary source-level `depth`, reports `weighted-depth`
and `bank-extra-slots`, and exports `__call_stack_weighted_depth` and
`__call_stack_bank_extra_slots`. Its `CALL GRAPH` section lists every compiled
direct-call edge, the number of simultaneously active stack slots contributed by
that edge (including a cross-bank bridge slot when applicable), one deterministic
deepest weighted path, every object-level `.callstackextra` contribution, and a
source/hidden/total byte reconciliation. Hand-written or separately assembled
calls which are absent from compiler call metadata still require an explicit
`callstack_extra` allowance.

`callstack_extra = N` adds an explicit byte count to that reserve. It is for
stack use known by a source-integration contract but hidden from compiler call
metadata, such as an internal JSR in an included assembly renderer. It is rejected
unless the same region also uses `callstack = callgraph`. The selected value is
reported in the map and exported as `__call_stack_extra`; it does not attempt to
infer arbitrary inline-assembly pushes or stack-pointer manipulation.

Compiler-generated ordinary calls do not push parameter, return, or scratch-
base state. Assembly integrations remain responsible for declaring enough
`callstack_extra` space and for restoring S before returning to compiled code.

## Whole-program activation overlay

`vcsc-cc1` emits parameters, automatic locals, return objects, and pooled
expression scratch in function-owned activation segments. After archive
selection, `vcsc-ld` lays those segments out with the same complete acyclic call
graph used for stack sizing. For each physical memory region, a callee begins
after its caller's live activation bytes. Sibling functions and other functions
that cannot be active simultaneously may therefore share addresses.

The overlay is region-local: a function may own pieces in the default RAM,
zero page, or a source-declared `mem` region, including a shared split-address
region such as Superchip RAM, and each region is independently weighted along
the call graph. Split-region activation layouts may contain parameters,
automatic locals, return objects, and compiler scratch. They use the read alias
as their run address, the write alias for startup zeroing and
generated stores, and consume each physical byte only once. Direct-call ABI
metadata preserves split parameter region identity and both aliases across
separate compilation. Internal-linkage functions are qualified by
object identity, so identically named static helpers in different translation
units do not merge. Calls hidden inside assembly remain outside this analysis
and must obey the integration contract's non-reentry rules.

It is not trying to be a full `ld65` config parser.

## Frame-phase object overlay

After activation planning metadata is collected but before writable-memory
placement, the linker consumes compiler `__phaseuse$V1$Mxx$symbol` records plus
explicit `__phaseworkspace$V1$symbol` eligibility records. VSYNC, VBLANK,
visible draw, and overscan are the ordered frame phases. Scoped uses are unioned
and expanded to the conservative contiguous interval from the first to the last
observed phase; any `M00` unscoped use makes the object ineligible.

A file-scope object is not reusable merely because its accesses happen to be
phase-confined. It must also carry the workspace-eligibility contract, which
means prior-frame contents are disposable outside the inferred interval.
Compiler-owned scratch emits that contract automatically when every acquisition
is phase-scoped. Only explicitly eligible, uninitialized writable BSS/zero-page
objects are candidates; DATA/ROM-backed initializers, activation blocks,
unmarked objects, unknown/unscoped use, and intersecting intervals remain
distinct.

The linker forms compatible sharing groups independently of declaration order
and member size, but a group with only one member is left in ordinary allocation
order. A real multi-member group allocates one slot at its earliest ordinary
member, sized/aligned for the largest/strictest member, and every other member
reuses that address. This recovers phase RAM without gratuitously moving stable
component state. Page and alignment constraints still apply. The map annotates
observed object phases as `phase=$xx` or `phase=unscoped`.

Compiler scratch has no language-level initial value and is written before every
use, so its standalone phase object does not receive a startup zero-table record.
Ordinary source BSS workspaces keep their normal startup clearing even when
phase-disjoint layouts share physical bytes. RAM accounting counts shared bytes
once.

## Component-owned placement and hidden-stack contracts

Assembler objects may export reserved component metadata for one named layout's
required C26 memory region, final power-of-two alignment, object-private routing,
and assembly-only hardware-stack bytes. The linker applies these records after
merging C26 topology and authoritative `mem` declarations but before validating
and allocating the final image.

A region requirement names a C26 `mem` region or the special `startup` role.
`startup` resolves through the synthesized ordinary `CODE` route, allowing the
same renderer object to follow the selected 4K or banked cartridge profile.
Object metadata wins over generic segment fallback. A retained exact cfg route
or alignment may duplicate the object contract only when it agrees; a mismatch
is a fatal diagnostic naming the segment, object, and competing values.

`.callstackextra` records are combined with the one writable MEMORY region which
requests `callstack=callgraph`. They replace component-specific cfg
`callstack_extra` fields. A retained cfg value is accepted only when it exactly
matches the object-owned total. Missing or multiple callgraph regions and
conflicting values are errors.

The map's `OBJECTS` entries report `component-region`, `component-align`, and
`component-private` beside each constrained layout. Existing hard
`.pagecontain` and `.indexrange` metadata continues to report whole-layout and
effective-index-window page requirements independently.

Source-language `align(N)` on a file-scope data-object definition is carried into
its private layout as the same power-of-two alignment contract used by
`.segmentalign`. `N` is restricted by the compiler to a compile-time positive
power of two from 1 through 32768. The linker applies that alignment to the
object's ROM/load start and, for writable DATA/BSS/zero-page objects, to the
runtime start as well. This is independent of `.pagecontain`: `align(256)` means
"start at `$xx00`" and may span pages, while `page` means "the complete object
must fit in one page" and does not by itself require a zero low byte.

Cartridge topology and authoritative memory declarations therefore describe
hardware and allocatable bytes only. Renderer and assembly-component constraints
travel with the object which needs them; no renderer x mapper cfg product is
required.

## Authoritative C26 memory regions

Every complete C26 `mem` declaration is carried in hidden object metadata even
when the declaring translation unit does not currently allocate an object there.
After archive selection, `vcsc-ld` merges identical declarations and rejects
conflicts with both original C26 source locations. These declarations create or
overwrite allocator regions before cfg validation and layout. A cfg `MEMORY`
entry is no longer required, and stale cfg start, size, type, or missing-region
facts do not override source.

Compatibility cfg entries may temporarily retain operational properties such as
`callstack`, `callstack_extra`, file backing, or fill policy. Their allocator
geometry is replaced by the source declaration. The linker synthesizes ordinary
`STARTUP`, `CODE`, `RODATA`, `DATA`, `BSS`, `ZEROPAGE`, and region-suffixed rules
from access type, priority, zero-page range, and startup-bank ownership while
preserving explicit alignment and start constraints on existing rules.

For each source-declared region, output ownership is inferred only from unique
containment of its complete synthetic allocation range inside one C26 bank's
`link_start..link_start+map_size` range. One owner yields `direct` or `switched`
according to that bank's selector mode; no owner yields `shared`; multiple owners
are an error naming the candidate banks. Names and CPU-visible mirrors are never
used for inference. Direct owners use ordinary absolute references. Distinct
selector-controlled owners use the existing bridge/trampoline machinery. Shared
regions never cause a transition.

Split-address handling is name-agnostic. The read window may be above or below
the write window, the aliases need not be adjacent or page-aligned, and each
region keeps its declared size. Allocation and overflow accounting use one
physical high-water mark for the region rather than inferring any Superchip-
specific `$80` delta or 128-byte capacity.

A non-void function may select one writable ordinary or split-address region for
its hidden `function$__return` object. The compiler emits that object in the
function's activation segment for the selected region and records the region
independently from code placement in the function ABI. Ordinary regions use their
declared run address and address size. Split regions export the read address and
record both window starts. The linker overlays and counts either form exactly
like any other region-local activation piece. Map output reports the result
layout separately from the function's CODE layout; split results show both
`run=` and `write=`. Separately compiled declarations and definitions with
different result regions are rejected before layout.

Named zero-page regions use synthesized suffixed segments such as
`ZEROPAGE.register`; no matching cfg `MEMORY` or `SEGMENTS` entry is required.
Split-address DATA/BSS layouts use the read window as their canonical run address.
Startup copy/zero records are translated to the corresponding write window.


## Segment mapping

For the current object format subset, `vcsc-ld` maps o26 segments like this:
- o26 `TEXT` -> linker `CODE`
- o26 `DATA` -> linker `DATA`
- o26 `BSS` -> linker `BSS`
- o26 `ZP` -> linker `ZEROPAGE`

`DATA` bytes are stored in ROM in the output image, but symbols and relocations referring to `DATA` use the RAM run address.

## Declaration-use contracts

Compiler-emitted `__contractmeta$V1$` and `__usemeta$V1$` exports remain
reserved linker metadata and never become program globals or consume memory.
After archive-member selection and ordinary symbol resolution, `vcsc-ld` builds
whole-program reachability from `main` and runtime initializer roots using the
compiler call graph plus any hidden assembly edges. A `require` or `recommend`
contract is satisfied only by a reachable semantic use from a different
translation-unit/instantiation owner. Same-owner uses and dead-code
references do not count. Unselected archive members are silent.

An unused `require` is a fatal, source-located link error. An unused `recommend`
is a source-located warning and the link continues. Object warnings print the
source-level declared type spelling rather than the compiler's internal ABI
fingerprint; the canonical fingerprint remains present separately in metadata.
This metadata path also handles true-inline calls and optimized-away object
accesses that leave no ordinary relocation.

## Memory usage and map file

After every successful link, `vcsc-ld` prints one `MEMORY USAGE` summary.
Every MEMORY region is reported on its own line. Cartridge regions used as the
load target of a read-only or initialized-data segment include occupied bytes,
free bytes, and percentages. ROM counts come from the final output
occupancy bitmap after relocation and linker-generated tables are written:
alignment holes remain free, while initializer tables and vectors count as used.

Each writable MEMORY region reports unique runtime object occupancy, the
hardware-stack reservation, their combined used total, and remaining physical
RAM. Runtime DATA, BSS, and zero-page layouts are counted by address, so
activation overlays sharing the same bytes are counted once rather than added
together. `objects=` excludes the stack; `hardware-stack=` is the call-graph
reservation, including configured supplementary stack bytes. The percentage
and `free=` fields use the original physical region size, before the linker
shrinks the allocatable range to reserve the stack. A failed link emits no
success summary.

For example, a 128-byte VCS RAM region might report:

```text
MEMORY USAGE
  ROM        used=2515 bytes (61.40%) free=1581 bytes (38.60%)
  RAM        used=19 bytes (14.84%) free=109 bytes (85.16%) objects=13 bytes hardware-stack=6 bytes
```

When you request a map file, `vcsc-ld` writes the same unified memory-usage section plus:
- effective memory regions after any call-graph stack reservation, including
  each C26 region's declaration location, priority, inferred output bank, and
  direct/switched/shared mode
- deterministic bank-placement components, pins, automatic assignments, cut
  weights, and concrete MEMORY regions for banked profiles
- object placement and generated cross-bank trampoline entries
- the selected call-stack region, ordinary/weighted graph depth, byte reserve,
  and physical range
- linker-generated symbols
- all resolved global symbols
- a `RETURN COALESCING` section for each automatic local sharing its function's
  hidden return object, including the source local, ABI symbol, region, relocated
  read/write aliases, width, and defining object

`RETURN COALESCING` is descriptive rather than a second allocation request. The
compiler places a reserved metadata label at the same relocated address as
`function$__return`; the linker reports that address after activation-overlay
placement. Split-address regions therefore show the physical read alias and its
corresponding write alias, while writable-memory occupancy is still counted
once. The metadata symbol itself is reserved and does not appear as an ordinary
user global.

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
- direct `JSR`, direct absolute `JMP`, and relaxed conditional-branch intent on
  relocations
- exact defining-layout identity for version-2 local affine relocations
- absolute symbols

## Limitations

- external relative-branch relocations are not supported; local relative
  branches are preserved in the `B26` branch table and validated after layout
- the linker accepts only the VCSC o26 magic and version emitted by the current `vcsc-as`

For a local relocatable expression such as `table-$100`, the assembler records
the layout that actually defines `table`. The final numeric addend is allowed
to point before that layout; the linker applies it to that layout's final base.
It never infers the target layout merely by asking which packed interval happens
to contain the altered value. That distinction is essential for the standard
VCS renderer's negative-Y fine-motion lookup.

The current assembler nevertheless preserves every actual relative branch as
placement metadata, including branches to assembler-local labels. The current
`B26\2` table adds a page policy byte to every record; the linker still accepts
older `B26\1` tables and treats their branches as flexible. Policies are:

- `flex`: the default for a bare branch and the explicit `.flex` spelling;
- `same`: the source used `.same`, requiring no taken-branch page crossing;
- `cross`: the source used `.cross`, requiring the taken branch to cross.

Linker maps contain a `BRANCHES` section with final source and target addresses
and report both `taken-page=same|crossing` and `policy=flex|same|cross`. The page
classification compares the target with the PC after the two-byte branch
instruction, matching the NMOS 6502/6507 extra-cycle rule.

For each code layout containing retained branches, the linker exhaustively
scores every aligned start in existing holes plus one bounded 256-byte sweep at
the region high-water mark. It first rejects candidates that violate `.same`
or `.cross`, then minimizes crossings among `flex` branches, followed by image
growth, page status, and address. Hard annotations must have source and target
inside the same movable layout; otherwise the linker rejects them because it
cannot guarantee their relationship while placing that layout. Existing-hole
choices are zero-growth local moves; farther starts are not useful because they
repeat a low-byte phase while wasting at least one complete page. The search is
greedy in input order, deterministic, and deliberately bounded rather than an
unbounded global code-layout optimizer.
- the config parser is intentionally small, strict, and only covers the documented subset
- Intel HEX is emitted as sparse logical-address records for unbanked profiles
- Unbanked flat binary output spans the lowest through highest used address and fills internal gaps with `$FF`; a conventional VCS layout therefore produces exactly 4096 bytes for `$F000-$FFFF`
- Banked flat binary output concatenates complete 4K bank units from lowest logical address to highest, so BANK0 is last

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

### Page-aware object placement

The current o26 layout tail carries a flags byte plus an indexed-range start
and maximum index for each named layout. Bit 0 (`O26_LAYOUT_PAGE_CONTAINED`) is
a hard placement constraint: the complete layout must reside within one
256-byte page. Bit 1 (`O26_LAYOUT_INDEX_RANGE`) requires the effective range
`layout + start` through `layout + start + max_index` to stay within one page.
The latter may constrain only part of an object, so an object larger than 256
bytes can remain legal. The linker derives legal low-byte placements and rejects
malformed ranges deterministically. Older o26 layout tails remain readable.

Every named ROM or RAM layout also receives a soft page-containment preference.
Alignment and hard-placement gaps are retained as per-MEMORY-region holes. An
object of at most 256 bytes is placed in the earliest hole where it fits wholly
inside one page; if no such hole exists, the linker keeps compact high-water
placement rather than adding padding merely to satisfy the preference. Text,
constant data, initialized-data load images, BSS, zero-page data, activation
overlays, and linker-generated initialization tables all use this policy. Named
text and initializer layouts are written independently, so one translation
unit's arrays and scalars do not inherit a single packed placement.

The map reports `page=hard`, `page=preferred`, or `page=crossing`. Initialized
RAM objects report both `load-page=` and `run-page=`. A `crossing` report means
the object could not be kept within one page without increasing the occupied
region extent; it is not a link error unless the hard flag is present.

The `INDEXED RANGES` map section reports each hard effective-address window,
its final base, start offset, maximum index, final address interval, and page
status. A whole object may report `page=crossing` while its required indexed
window correctly reports `page=same`.

### NMOS page-wrap hazards

The linker rejects a relocatable indirect-`JMP` vector whose final address has
low byte `$FF`. On the NMOS 6502/6507, `JMP ($xxFF)` fetches the vector high
byte from `$xx00`; silently accepting that placement would redirect control to
an address assembled from two different pages. The assembler marks only real
indirect-JMP word relocations, so ordinary data words containing `$6C` are not
misidentified as instructions.

Every contiguous zero-page layout must also end at or before `$00FF`. In
particular, a two-byte pointer cannot begin at `$FF`; the linker relocates it
when another address is available and otherwise fails with an explicit
diagnostic. Intentional zero-page wrap remains possible, but it must be stated
as separate one-byte objects (for example one byte at `$FF` and one at `$00`).
The linker deliberately does not reject instruction operands such as
`LDA ($FF),Y`, whose pointer-byte wrap is normal 6502 addressing behavior.

Compiler and assembler procedures in `CODE` or a named `CODE.*` region are
represented as independent private layouts. Ordinary functions use
`CODE.__vcsc_function$NAME`; a function marked with source mem region `bank1`
uses `CODE.bank1.__vcsc_function$NAME`. The linker first looks for the longest
matching segment rule, so `CODE.bank1` controls that private layout before the
ordinary `CODE` fallback is considered.

Function modifiers are property-classified by the compiler: an order-insensitive
set of `$ro` regions is the code-placement ABI fact, while one `$rw` region is the
independent return-storage fact. Linker ABI diagnostics report `code regions`
mismatches separately from `return type` storage mismatches. The linker synthesizes `CODE.orchard`, `RODATA.orchard`, and the corresponding
writable region routes directly from authoritative C26 declarations. Retained cfg rules may duplicate a component-owned alignment during migration
only when the values agree; they do not choose another allocator region.

For a multi-region code contract, compiler metadata identifies one logical
function and every requested `$ro` region. The linker clones the compiler's
private body layout and its relocations into each named region. A direct `JSR` or
`JMP` from a bank containing a copy resolves to that local body; only a caller
without a local copy falls back to the deterministic primary body through the
ordinary cross-bank trampoline. All copies continue to use the one activation
record and optional shared named return object.

A multi-region `const` object is handled similarly. Each physical RODATA copy is
placed independently, and a relocation binds to the copy in the referencing
layout's bank. A pinned source bank without an object copy is a hard error rather
than a cross-bank ROM-data access. Automatic placement constrains an unpinned
referencing component to banks containing a copy. Copies need not share an
offset within their banks.

The map's `REPLICATED ROM` section lists every logical replicated symbol, each
region/bank/load-address/layout copy, bytes per copy, per-symbol physical total,
and the total physical ROM consumed by all extra copies. Replication metadata is
validated against bank-owned read-only MEMORY regions; it is rejected for
unbanked layouts, writable regions, missing segment rules, and ambiguous or
contradictory definitions.

Their map entries therefore report exact function size and page status.
Functions up to 256 bytes are kept within one page when an existing hole permits
it without increasing the region high-water mark. A function definition marked
`page` carries the hard flag and fails clearly when its final size exceeds one
page or no legal placement exists. Explicit non-`CODE` renderer segments are
not split automatically. Their complete layout may still receive the same
bounded branch-aware start-address search.

Superchip full-window profiles
------------------------------
4KSC uses one direct 4K chunk; F8SC, F6SC, and F4SC use the ordinary F8/F6/F4 bank count, logical addresses,
file order, hotspots, trampolines, and reset bridges. The linker additionally
rejects any bank-owned read-only region which overlaps that bank's `$x000-$x0FF`
Superchip RAM-port prefix. Public SC profiles place ordinary ROM in
`$x100-$xEFF` and still emit complete 4096-byte physical chunks. Their shared
Superchip region is declared as:

```
cartram: read_start = $F080, write_start = $F000,
           size = $0080, type = rw, define = yes;
```

Source objects in `BSS.cartram` and `DATA.cartram`, including
function-scope static locals, are allocated once in the read window. Static
locals use persistent layouts rather than call-graph activation overlays.
Relocations from every ROM bank may target either alias without being mistaken
for cross-bank ROM references. Loads resolve to `$F080-$F0FF`; stores and
startup DATA/BSS or runtime-initializer writes resolve to `$F000-$F07F`. The map
reports physical occupancy once and prints both `run` and `write` addresses for
each allocated object. Absolute external `@[read_address/write_address]`
bindings are deliberately excluded from allocator-managed windows: a readable
binding range may not overlap a managed read/ordinary window, and a writable
binding range may not overlap a managed write/ordinary window. This prevents a
non-owning alias from silently colliding with an allocated Superchip byte or any
other linker-owned storage.

A nonzero `$image_offset` is also the generic hidden-prefix contract for direct
profiles such as 4KSC. Compiler-declared read-only storage may not occupy that
hidden physical prefix even when no selector machinery exists.

## Banked standard-renderer composition

The maintained standard all-five renderer is certified with the generic F8,
F6, F4, and F8SC C26 topologies. Its object-owned `startup` contracts keep
renderer CODE and RODATA in the startup bank, while application `bank0 page
const` objects combine explicit ownership with hard page containment. The
consolidated diagnostic places a real overscan hook in bank1. That edge is
VBLANK-only: the renderer asserts VBLANK before the generated cross-bank JSR,
and the trampoline restores bank0 before the next beam-critical phase.

The linker map is the measurement contract. It reports the pinned renderer and
hook components, one JSR bridge, per-bank ROM usage, replicated bridge bytes,
RIOT/Superchip allocation, and hardware-stack reservation. The current bridge
executes in 37 cycles including call and return, 25 cycles above direct JSR/RTS.
Shared Superchip regions have no output-bank owner and therefore never acquire
selector code.
