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
- writes same-stem `.map`, `.sym`, `.lst`, and `.cfg` sidecars by default

## Debugger sidecars

For `game.bin`, a successful link normally writes `game.map`, `game.sym`,
`game.lst`, and `game.cfg` beside it. Stella automatically consumes the latter
three when its debugger opens. The symbol file contains final ROM and RAM
addresses. The list file is a final linked-byte listing with DASM-compatible
RAM constant rows. The DiStella config classifies known executable layouts as
`CODE` and all other occupied bytes as `DATA`; font, graphics, color, and audio
ranges can be refined later with Stella's debugger.

The `.map` file is VCSC's fuller layout/usage report; Stella does not consume
it. VCSC deliberately does not create a ROM-specific `.script`, because Stella
uses that file for user-owned breakpoints, traps, watches, and debugger setup.

If the default same-stem `.cfg` name is already the linker script itself, the
linker preserves that input file and omits only the generated DiStella config.
Use `-Cfg OTHER_FILE` when a separate name is useful. Explicit output-name
collisions are errors.

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
- `bank = NAME` on a cartridge-output `MEMORY` region in a banked profile
- `mapper = F8/F6/F4`, `fillval = BYTE`, and `vectorbridge = OFFSET` inside `CARTRIDGE`
- `start`, `size`, `hotspot`, and `startup = yes/no` on a named `BANKS` entry

### Full-window banked image foundation

The first bank-aware image model uses the descending mirrored logical ranges
BANK0 `$F000-$FFFF`, BANK1 `$D000-$DFFF`, and so on. A banked cfg describes the
complete 4K output units separately from the allocatable `MEMORY` regions inside
them:

```text
CARTRIDGE {
    mapper = F8;
    fillval = $FF;
    vectorbridge = $0FE0;
}
BANKS {
    BANK0: start=$F000, size=$1000, hotspot=$1FF9, startup=yes;
    BANK1: start=$D000, size=$1000, hotspot=$1FF8, startup=no;
}
MEMORY {
    bank1:              start=$D000, size=$0FE0, type=ro, bank=BANK1;
    BANK1_VECTOR_BRIDGE: start=$DFE0, size=$0012,          bank=BANK1;
    BANK1_TAIL:          start=$DFF2, size=$0008,          bank=BANK1;
    BANK1_VECTORS:       start=$DFFA, size=$0006,          bank=BANK1;
    ROM:                 start=$F000, size=$0FE0, type=ro, bank=BANK0;
    BANK0_VECTOR_BRIDGE: start=$FFE0, size=$0012,          bank=BANK0;
    BANK0_TAIL:          start=$FFF2, size=$0008,          bank=BANK0;
    BANK0_VECTORS:       start=$FFFA, size=$0006,          bank=BANK0;
}
```

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
mapper's first hotspot plus that file index.  The linker validates the complete
table, including VCSC `BANK0` as the sole startup bank and final file chunk.

Every selector hotspot is reserved at the same low twelve-bit offset in every
bank. An ordinary `ro` or `data` segment region covering any selector is
rejected before placement, so code or ordinary ROM data cannot land on an
address whose access changes the selected bank. The configured
`vectorbridge` corridor is reserved the same way.

The current vector bridge is eighteen bytes: byte-identical NMI, RESET, and
IRQ/BRK entries are copied at that physical offset in every bank. Each entry is
`BIT BANK0_HOTSPOT; JMP handler`. The final six bytes of every bank contain the
same vector words, using BANK0's logical mirror of those three entries. This
makes reset deterministic from every initially selected bank and also makes
F4's `$1FFA/$1FFB` NMI-vector/selector overlap harmless.  In F4, the NMI
low-byte fetch at `$1FFA` selects physical/file chunk 6 (VCSC BANK1), and the
high-byte fetch at `$1FFB` selects chunk 7 (VCSC BANK0).  Identical vector bytes
make the fetched word stable, and the vector fetch ends with BANK0 selected.
The handlers and `main` must remain in BANK0.

Flat banked output must use `.bin`. The writer emits complete 4096-byte units in
ascending logical-address order, filling unoccupied bytes with the cartridge
fill value. Thus F8 writes VCSC BANK1 as physical/file chunk 0 and VCSC BANK0 as
chunk 1.  VCSC BANK0 occupies the final 4K of every F8/F6/F4 image. The map
reports mapper, exact output size, bridge offset/size, each VCSC bank's selector,
startup status, and physical file offset.

After final placement, the linker classifies every symbolic relocation by the
configured bank containing its serialized source bytes and the bank owning its
target symbol/address.  Same-bank ROM references and references to nonbanked
RAM or hardware continue normally.  Cross-bank ROM data references are hard
errors, including low-byte, high-byte, word, pointer-initializer, and indirect-
`JMP` vector relocations.  Retained relative branches and relaxed long
conditional branches are also rejected when their final target occupies a
different bank.

Current o26 objects preserve direct `JSR`, direct absolute `JMP`, and relaxed
conditional-branch intent in the relocation type.  The linker therefore
diagnoses cross-bank calls and jumps as such rather than misreporting them as
data reads.  Until the common trampoline-table roadmap items land, a proven
cross-bank `JMP` or `JSR` is rejected with a specific "trampoline generation is
not implemented yet" diagnostic; emitting the raw mirrored address would call
the wrong bytes.  Diagnostics identify the input object, movable source layout,
final source address and VCSC bank, target symbol/layout, final target address,
and destination VCSC bank.  Raw numeric addresses contain no relocation and,
as usual, cannot be checked by the linker.

`callstack = callgraph` may be placed on one writable `MEMORY` region. After
all objects and archive members are selected, the linker computes the longest
acyclic source-level call path and shrinks that region from the top before
placing DATA/BSS/ZEROPAGE. The reserve is two bytes per function level for
active JSR return addresses, plus one fixed two-byte allowance when the selected
objects contain one or more runtime initializer functions. The extra pair holds
the stock startup's init-table cursor while it calls an initializer.

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
zero page, or a source-declared `mem` region, and each region is independently
weighted along the call graph. Internal-linkage functions are qualified by
object identity, so identically named static helpers in different translation
units do not merge. Calls hidden inside assembly remain outside this analysis
and must obey the integration contract's non-reentry rules.

It is not trying to be a full `ld65` config parser.
## Compiler mem-region validation

Objects produced by `vcsc-cc1` include hidden metadata for each `mem` region that was used for symbol-backed storage. Before layout, `vcsc-ld` compares that metadata with the config `MEMORY` table.

The linker rejects the image if the config is missing the region, or if the `start`, `size`, or `type` differs from the compiler's `mem` declaration. The diagnostic reports both sides and tells the user to update either the VCSC source declaration or the linker cfg so they match.

Named zero-page regions use suffixed zero-page segments such as `ZEROPAGE.register`, so the cfg must contain a matching `MEMORY` entry for the region name when such a region is used.


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
translation-unit/template-instance owner. Same-owner uses and dead-code
references do not count. Unselected archive members are silent.

An unused `require` is a fatal, source-located link error. An unused `recommend`
is a source-located warning and the link continues. This metadata path also
handles true-inline calls and optimized-away object accesses that leave no
ordinary relocation.

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

Their map entries therefore report exact function size and page status.
Functions up to 256 bytes are kept within one page when an existing hole permits
it without increasing the region high-water mark. A function definition marked
`page` carries the hard flag and fails clearly when its final size exceeds one
page or no legal placement exists. Explicit non-`CODE` renderer segments are
not split automatically. Their complete layout may still receive the same
bounded branch-aware start-address search.
