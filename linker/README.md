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
- `mapper = F8/F6/F4`, `fillval = BYTE`, `trampoline = OFFSET`,
  `trampolinesize = SIZE`, and `vectorbridge = OFFSET` inside `CARTRIDGE`
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
    trampoline = $0F00;
    trampolinesize = $00E0;
    vectorbridge = $0FE0;
}
BANKS {
    BANK0: start=$F000, size=$1000, hotspot=$1FF9, startup=yes;
    BANK1: start=$D000, size=$1000, hotspot=$1FF8, startup=no;
}
MEMORY {
    bank1:               start=$D000, size=$0F00, type=ro, bank=BANK1;
    BANK1_TRAMPOLINE:    start=$DF00, size=$00E0,          bank=BANK1;
    BANK1_VECTOR_BRIDGE: start=$DFE0, size=$0012,          bank=BANK1;
    BANK1_TAIL:          start=$DFF2, size=$0008,          bank=BANK1;
    BANK1_VECTORS:       start=$DFFA, size=$0006,          bank=BANK1;
    ROM:                 start=$F000, size=$0F00, type=ro, bank=BANK0;
    BANK0_TRAMPOLINE:    start=$FF00, size=$00E0,          bank=BANK0;
    BANK0_VECTOR_BRIDGE: start=$FFE0, size=$0012,          bank=BANK0;
    BANK0_TAIL:          start=$FFF2, size=$0008,          bank=BANK0;
    BANK0_VECTORS:       start=$FFFA, size=$0006,          bank=BANK0;
}
```

The installed `libraries/vcs/vcs_8k_f8.cfg`, `vcs_16k_f6.cfg`, and
`vcs_32k_f4.cfg` profiles are the certified public full-window profiles.  Each
names every ordinary allocatable region `bankN`, reserves `$xF00-$xFFF`
identically in every physical chunk, and is selected explicitly with `-T`; the
default driver profile remains unbanked `vcs_4k.cfg`.

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
mapper's first hotspot plus that file index.  The linker validates the complete mapper table from logical starts and
hotspots and requires exactly one entry marked `startup=yes`. Bank labels are
configuration names rather than semantic `BANK0`/`BANK1` tokens; the public
profiles retain those conventional labels and place their startup bank in the
final file chunk.

Every selector hotspot is reserved at the same low twelve-bit offset in every
bank. An ordinary `ro` or `data` segment region covering any selector is
rejected before placement, so code or ordinary ROM data cannot land on an
address whose access changes the selected bank. The configured `trampoline`
corridor and `vectorbridge` corridor are reserved the same way. The trampoline
corridor must fit wholly below the final six vector bytes, and neither generated
corridor may overlap the other or a selector hotspot.

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

`STA` is intentional: F8/F6/F4 react to the hotspot access, while the store
preserves A and all processor flags just as the original direct `JMP` would.
The indirect pointer uses BANK0's logical mirror of the inline target word. The
upper mirror bits are absent from the cartridge bus, so after the bank switch it
still reads the same low-twelve-bit bytes from the selected physical bank. Every
bank contains identical entry bytes, which is required because instruction
fetch continues in the newly selected bank immediately after the hotspot
access.

Entries are deduplicated by final target address and destination hotspot. Each
call site receives its source bank's logical mirror of the common entry offset.
The allocator inserts a fill byte when necessary so the inline pointer never
begins at `$xxFF`, avoiding the NMOS 6502/6507 indirect-`JMP` page-wrap bug. A
full corridor is a link error. The map reports reserved, occupied, and total
replicated bytes plus every generated target entry.

A proven direct cross-bank `JSR` is redirected to a fifteen-byte source-aware
entry in the same common table:

```asm
    JSR body
return_to_source:
    STA source_hotspot
    RTS
body:
    STA destination_hotspot
    JMP (inline_target_pointer)
inline_target:
    .word final_target
```

The call-site JSR leaves the caller's real return address on the hardware stack.
The entry's internal JSR creates the synthetic return address without changing
A, X, Y, or processor flags. The destination function's RTS reaches the
byte-identical `return_to_source` stub, whose hotspot store restores the caller's
bank while preserving A and flags; its RTS then consumes the original call-site
return address. Internal JSR and indirect-pointer operands use BANK0's logical
mirror of the common table, so the encoded bytes are identical in every bank.
JSR entries are deduplicated by source hotspot, destination hotspot, and final
target. Nested cross-bank calls naturally restore banks in LIFO order.

Cross-bank ROM data and conditional branches remain permanent errors.
Diagnostics identify the input object, source layout/address/bank, target
symbol/address/bank, and the failed rule. Raw numeric addresses contain no
relocation and cannot be checked by the linker.

### Deterministic automatic bank placement

In a banked profile, compiler-private unmarked `CODE.__vcsc_function$...` and
`RODATA.__vcsc_object$...`/`RODATA.__vcsc_page$...` layouts are movable across
the configured full-window banks. Explicit named source `mem` modifiers produce
`CODE.region` or `RODATA.region` private layouts and are hard pins to that exact
MEMORY region. An unqualified `main`, startup/non-private runtime layouts, and
private runtime functions using reserved implementation names beginning with
`_` are pinned to the unique bank marked `startup=yes`. An explicitly qualified
`main` is accepted only when that MEMORY region belongs to the same bank. The
compiler does not interpret region names such as `bank0`; the public profiles
merely use BANK0 as their conventional startup label.

Before assigning addresses, the linker classifies relationships between ROM
layouts:

- every ROM data/address relocation and every retained branch is a hard
  same-bank edge;
- direct JSR and direct absolute JMP edges are soft because the common table can
  bridge them;
- repeated soft edges accumulate a deterministic weight of 15 per JSR and 8 per
  JMP, matching the corresponding trampoline-entry payload rather than claiming
  a runtime execution frequency.

Hard edges are collapsed transitively into indivisible components. A component
inherits any explicit or mandatory pin carried by a member; incompatible pins
are rejected before address layout. Fixed initialized-data images and generated
copy/zero/init tables are charged against their ROM regions before automatic
components are packed.

For each logical bank, the largest owned `type=ro` MEMORY entry is its default
automatic-placement region. Pinned components are assigned first in stable input
order. Remaining components are ordered by decreasing byte size, decreasing
soft-edge degree, then stable object/layout order. A component goes to the bank
with enough preliminary capacity that adds the least cut weight against already
assigned components. Ties prefer the startup bank, then the higher logical
address, then the bank name. The ordinary allocator still performs the final
alignment, page-containment, branch-page, and hole checks.

Failure never weakens the source contract: the linker does not split a hard
component, move a pin, duplicate code/data, or synthesize a far ROM read. A
capacity error reports the component size and free ordinary-ROM capacity of
every bank. The map's `BANK PLACEMENT` section records component number, pinned
or automatic assignment, bank, concrete MEMORY region, component bytes,
incident cut weight, layout, and input object. The later `TRAMPOLINES` section
reports the bridges actually created by the resulting cut call edges.

`callstack = callgraph` may be placed on one writable `MEMORY` region. After
all objects and archive members are selected, the linker computes the longest
acyclic source-level call path. For statically configured banked functions it
also computes a weighted depth which adds one hardware-return slot for every
simultaneously active cross-bank call edge. The region is shrunk from the top
before placing DATA/BSS/ZEROPAGE. The reserve is two bytes per weighted slot,
plus one fixed two-byte allowance when the selected objects contain one or more
runtime initializer functions. The extra pair holds the stock startup's
init-table cursor while it calls an initializer.

The map preserves the ordinary source-level `depth`, reports `weighted-depth`
and `bank-extra-slots`, and exports `__call_stack_weighted_depth` and
`__call_stack_bank_extra_slots`. Hand-written or separately assembled calls
which are absent from compiler call metadata still require an explicit
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
## Compiler mem-region validation

Objects produced by `vcsc-cc1` include hidden metadata for each `mem` region that was used for symbol-backed storage. Before layout, `vcsc-ld` compares that metadata with the config `MEMORY` table.

The linker rejects the image if the config is missing the region, or if the source and cfg disagree about its address, size, or type. Ordinary regions compare `start`, `size`, and `type`. Split-address regions compare `read_start`, `write_start`, `size`, and `type`; they must be `rw` and shared rather than assigned to one cartridge bank. Diagnostics report both sides and identify the mismatched property.

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

Named zero-page regions use suffixed zero-page segments such as `ZEROPAGE.register`, so the cfg must contain a matching `MEMORY` entry for the region name when such a region is used. Split-address DATA/BSS layouts use the read window as their canonical run address. Startup copy/zero records are translated to the corresponding write window.


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
- deterministic bank-placement components, pins, automatic assignments, cut
  weights, and concrete MEMORY regions for banked profiles
- object placement and generated cross-bank trampoline entries
- the selected call-stack region, ordinary/weighted graph depth, byte reserve,
  and physical range
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

Function modifiers are property-classified by the compiler: an order-insensitive
set of `$ro` regions is the code-placement ABI fact, while one `$rw` region is the
independent return-storage fact. Linker ABI diagnostics report `code regions`
mismatches separately from `return type` storage mismatches. A cfg that pins
source region `orchard` must provide a matching `CODE.orchard` segment rule;
named return segments continue to resolve through their matching writable MEMORY
region.

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
F8SC, F6SC, and F4SC use the ordinary F8/F6/F4 bank count, logical addresses,
file order, hotspots, trampolines, and reset bridges. The linker additionally
rejects any bank-owned read-only region which overlaps that bank's `$x000-$x0FF`
Superchip RAM-port prefix. Public SC profiles place ordinary ROM in
`$x100-$xEFF` and still emit complete 4096-byte physical chunks. Their shared
Superchip region is declared as:

```
superchip: read_start = $F080, write_start = $F000,
           size = $0080, type = rw, define = yes;
```

Source objects in `BSS.superchip` and `DATA.superchip`, including
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
