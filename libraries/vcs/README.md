```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Atari 2600 / VCS support files

This directory contains target support files for the Atari 2600 / VCS.

Files:

- `vcs.c26` ... VCS machine definition with types, memory regions, and hardware includes
- `tia.c26` ... TIA hardware register bindings
- `riot.c26` ... RIOT I/O and timer register bindings plus RIOT RAM region names
- `vcs.cfg` ... reduced operational linker policy shared by C26 cartridge profiles
- `vcs_2k.c26` ... conventional unbanked 2K topology mapped at `$F800-$FFFF`
- `vcs_4k.c26` ... conventional unbanked 4K topology and allocatable ROM
- `vcs_8k_f8.c26`, `vcs_16k_f6.c26`, `vcs_32k_f4.c26` ... inspectable selector-controlled C26 profiles with exact output order and generated corridors
- `vcs_8k_f8sc.c26`, `vcs_16k_f6sc.c26`, `vcs_32k_f4sc.c26` ... matching Superchip profiles with a reserved physical prefix and shared split-address RAM
- `vcs_direct_8k.c26` ... generic two-chunk directly mapped packaging profile used to certify selector-free output
- `vcs_*.cfg` ... retained legacy profile descriptions for simulator input and compatibility/differential certification; public builds use the C26 profiles
- `bankswitching_diagnostic_suite.c26` ... parameterized F8/F6/F4 all-transition diagnostic used by `vcsc-sim` and authoritative Stella certification
- `color_ntsc.c26` ... readable aliases defined through the compile-time `__builtin_ntsc_rgb(r, g, b)` NTSC palette matcher
- `frame_ntsc.c26` ... shared NTSC phase constants, scanline waiting, VSYNC, and scheduler-owned VBLANK/overscan deadlines
- `playfield.c26` ... compile-time `VCS_PLAYFIELD_ROW()` conversion from left-to-right 32-bit visual rows to the four asymmetric TIA playfield bytes
- `sound_ntsc.c26` ... NTSC TIA audio-control, note-frequency, volume, and frame-timing aliases
- `six_glyph_component.c26` ... repeatable lifecycle-template centered 48-pixel/six-glyph display with fixed bright-white color and hostile-state-safe reflection reset
- `six_glyph_wide_component.c26` ... separate mutable-color six-glyph profile with origins at X=36,52,68,84,100,116, an 88-pixel span, and the compact delayed-player pipeline
- `six_glyph_left_component.c26` ... eleven-line fixed-color variant justified at X=0..47
- `six_glyph_right_component.c26` ... eleven-line fixed-color variant justified at X=112..159
- `six_glyph_color_component.c26` ... timing-compatible centered mutable-color twin used by interactive score diagnostics, with the same hostile-state-safe reflection reset
- `two_plus_two_score_support.c26` ... shared page-contained compact decimal glyph and calibrated horizontal-position tables for two-plus-two scores
- `two_plus_two_score_component.c26` ... repeatable eleven-line P0/P1 score with independent packed-BCD left/right values, colors, and X positions; each three-bit digit is doubled to six visible pixels with a two-pixel inter-digit gap
- `renderers/COMPONENT_CONVERSION.md` ... measured predecessor baseline, machine-readable visible-component handoff/TIA ownership table, and the explicit 181-line score-composable, 192-line scoreless, and matched unofficial profile contracts
- `renderers/faithful_legacy_multisprite/` ... faithful unbanked/non-Superchip multisprite source-integration baseline: P0 plus five logical P1 sprites, integrated score/playfield, exact 122-byte legacy state, six-byte hardware stack, 264-line timing, and retained unofficial-opcode behavior
- `renderers/all_five_181/` ... official-opcode 181-line P0/P1/M0/M1/BL lifecycle component, derived from the proven player-color raster and using solid player colors, for composition with an independent eleven-line score
- `renderers/all_five_181_unofficial/` ... matched stable/common-NMOS experimental twin with the same API, RAM contract, and corrected raster schedule
- `renderers/all_five_192/` ... distinct official-opcode 192-line scoreless P0/P1/M0/M1/BL lifecycle component, derived from the proven player-color raster and using solid player colors
- `renderers/player_color_181/` ... official-opcode 181-line P0/P1/BL lifecycle component with page-contained per-row P0/P1 colors and tested centered, left-, right-, two-plus-two, and poison composition in both orders
- `renderers/player_color_181_unofficial/` ... matched stable/common-NMOS experimental twin of the 181-line player-color component; currently raster-identical and size-identical after direct-countdown conversion
- `renderers/player_color_192/` ... distinct official-opcode 192-line scoreless P0/P1/BL lifecycle component with page-contained per-row P0/P1 colors
- `renderers/poison_debug_score/` ... one-byte adversarial eleven-line score-profile component that trashes deterministic P0/P1 state while preserving playfield, missile, and Ball geometry
- `renderers/standard_4k_ntsc/` ... legacy monolithic all-five-object solid-color component whose generated assembly object carries its own placement, page, and hidden-stack contracts; certified with generic 4K/F8/F6/F4/F8SC C26 profiles through a VBLANK-only banked overscan hook
- `renderers/standard_4k_ntsc_playercolors/` ... legacy monolithic P0+P1+BL player-color profile retained for compatibility and regression
- `fonts/` ... eight shared 8x8 score-font families plus the six-slice `logo_font.c26` VCSC mark
- `../../examples/README.md` ... renderer-grouped public example index
- `../../examples/01_basic/` ... standalone cartridges and reusable-component examples
- `../../examples/02_faithful_legacy_playercolors/` ... faithful legacy interactive compatibility diagnostic
- `../../examples/03_player_color_192/` ... full-height scoreless interactive player-color diagnostic
- `../../examples/04_player_color_181/` ... official-opcode twelve-cartridge centered/left/right/two-plus-two/poison/wide matrix for 181-line player-color gameplay
- `../../examples/05_all_five_192/` ... official-opcode full-height all-five interactive diagnostic
- `../../examples/06_all_five_181/` ... official-opcode ten-cartridge centered/left/right/two-plus-two/poison matrix for 181-line all-five gameplay
- `../../examples/07_player_color_181_unofficial/` ... matched unofficial-opcode ten-cartridge player-color matrix, built explicitly with `-Wa,--illegals`
- `../../examples/08_all_five_181_unofficial/` ... matched unofficial-opcode ten-cartridge all-five matrix, built explicitly with `-Wa,--illegals`
- `../../examples/09_bankswitching/` ... parameterized F8/F6/F4 transition diagnostic with visible PASS/FAIL frames
- `../../examples/10_faithful_legacy_multisprite/` ... fixed faithful P0-plus-five-P1 multisprite reference cartridge used to anchor roadmap item 28

## Bank-switching diagnostic suite

`bankswitching_diagnostic_suite.c26` is compiled with `MAPPER_BANKS` and,
for the Superchip twins, `SUPERCHIP_TEST`. One cartridge internally executes the
complete ordered source-bank to destination-bank direct-JMP matrix for its
mapper. Every source bank also verifies a same-bank JSR/RTS path; BANK0 adds a
nested BANK0-to-BANK1 call and return. RIOT-RAM signatures, matrix counts, and
hardware-stack balance are checked before the cartridge settles on a green
background with a white **P** or a dark-red background with a white **F**. Both
glyphs are copied from `fonts/default_ascii.c26`. Their ordinary
`lda glyph,x` references remain absolute-X because the symbols are relocatable
ROM; each `GRP0` update is aligned to `WSYNC`, and the complete frame is exactly
262 scanlines.

The editable wrapper and Makefile live under
`examples/09_bankswitching/01_diagnostic/`. Each diagnostic includes the selected C26 cartridge profile. `vcs.c26` now
describes only the common machine types, registers, and RIOT RAM; the profile
supplies the cartridge topology and allocatable ROM. The default driver adds
`vcs_4k.c26`, whose `mem rom` spans `$F000-$FFF9` and excludes the six vector
bytes from allocation.

A normal build emits the six mapper
images—F8, F6, F4, F8SC, F6SC, and F4SC—plus `poisoned.bin`, a deliberately
failing F8SC image for inspecting and grading the FAIL frame. The normal
simulator regression runs the six mapper images from every physical startup
bank; SC runs begin with hostile RAM, poison it, reset, and pass a second time.
Stella runs the same forced and randomized startup-bank matrix and presses
console Reset before grading each SC frame, including the poisoned FAIL image.

## NTSC color matching

`__builtin_ntsc_rgb(r, g, b)` accepts three compile-time integer RGB components
in `0..255` and folds them to the nearest of the 128 meaningful even NTSC TIA
color bytes. Matching uses squared RGB distance; exact ties choose the lower TIA
byte. There is no cartridge-resident palette and no generated runtime search.
For example:

```vcsc
COLUP0 := __builtin_ntsc_rgb(0xfd, 0x86, 0x85); // folds to TIA $4e
```

`color_ntsc.c26` uses that builtin to define selected human-readable
`VCS_NTSC_*` aliases. Each definition retains the reference RGB triplet and the
resulting TIA value in its comment, so the names remain readable labels rather
than a second independently maintained numeric palette. The RGB table is the
Stella-compatible NTSC reference palette used by the project; real hardware,
television decoding, capture equipment, and emulator palette settings can all
produce different displayed RGB values.

The compiler-side matcher is structured so later PAL and SECAM builtins can
reuse the same nearest-palette machinery while supplying their own reference
tables.

Typical use:

```vcsc
include "vcs.c26"
include "frame_ntsc.c26"

void main(void) {
   vcs_ntsc_vsync();
   vcs_ntsc_begin_vblank();
   /* Run component vblank callbacks here. */
   vcs_ntsc_end_vblank();

   /* The first component enters at the canonical measured phase. Between
      adjacent visible components call vcs_ntsc_component_handoff(). For a
      blank gap immediately before a component, use
      vcs_ntsc_wait_component_scanlines() instead of the generic WSYNC loop.
      If the visible composition ends with blank scanlines, use
      vcs_ntsc_wait_visible_tail_scanlines() for that final gap before
      vcs_ntsc_begin_overscan(). */
   /* Draw exactly VCS_NTSC_VISIBLE_SCANLINES here. */

   vcs_ntsc_begin_overscan();
   /* Run component overscan callbacks here. */
   vcs_ntsc_end_overscan();
}
```


`vcs_ntsc_wait_scanlines()` promises only a count of WSYNC boundaries; its
post-WSYNC return cycle is deliberately not part of the API.
`vcs_ntsc_wait_component_scanlines()` has a calibrated cycle-3 entry contract
for a following visible component. `vcs_ntsc_wait_visible_tail_scanlines()` has
a separate calibrated return contract for the final blank visible tail before
asserting overscan VBLANK. Keeping those contracts explicit prevents ordinary
compiler lowering improvements from silently moving beam-sensitive work.

`vcs_ntsc_begin_vblank()` and `vcs_ntsc_begin_overscan()` assert VBLANK and
start scheduler-owned TIM64T deadlines. Their matching end operations wait only
for the unused part of the phase, detect RIOT timer underflow without mistaking
a wrapped `INTIM` value for remaining time, issue the final `WSYNC`, and return
`void`. A missed deadline cannot be repaired generically, so the production path
continues at the next scanline boundary and produces one long frame rather than
waiting on wrapped timer state. `vcs_ntsc_end_vblank()` clears VBLANK;
`vcs_ntsc_end_overscan()` leaves it asserted for VSYNC. Component callbacks must
not touch VBLANK, INTIM, TIMINT, or a timer-start register, and must not
perform the final phase transition. They may use WSYNC for bounded internal
blanking work; those stalled cycles consume the already-running shared deadline.

Define `alias VCS_NTSC_DIAGNOSTICS 1` before including `frame_ntsc.c26` to add a
sticky `vcs_ntsc_overrun_flags` byte. Bits `VCS_NTSC_VBLANK_OVERRUN` and
`VCS_NTSC_OVERSCAN_OVERRUN` identify missed deadlines. Production builds omit
that RAM byte and all flag-setting code.


## Left/right two-plus-two score component

Include the immutable support module once, then instantiate the component as
many times as RAM permits:

```vcsc
include "two_plus_two_score_support.c26"
template "two_plus_two_score_component.c26" as score

score_left_score := 12;
score_right_score := 34;
score_left_color := 0x3e;
score_right_color := 0xce;
score_left_x := 32;
score_right_x := 96;
```

Each field is one double-width player containing two spaced three-bit decimal
glyphs. The blank source bit between them becomes a visible two-color-clock gap. `left_x` supports 0 through 64 and `right_x` supports 32 through 144;
the defaults leave a wide center gap. `vblank()` samples all six public fields,
so animation must update the score instance's own X variables during overscan.
The component consumes exactly eleven visible scanlines, owns all P0/P1 state it
needs on every draw, clears HMM0/HMM1/HMBL before its HMOVE so preserved
missile/Ball geometry cannot move, and returns with both player pipelines empty.
Use `vcs_ntsc_component_handoff()` before an adjacent visible component.

## Poison debug score renderer

`renderers/poison_debug_score/poison_debug_score.c26` is a deterministic
adversarial component, not a production score renderer. It consumes exactly
11 visible scanlines and owns one caller-set exit-background byte. While its
red diagnostic band is visible it deliberately leaves hostile P0/P1 graphics,
colors, reflection, vertical delay, copy/size, coarse position, fine motion,
and HMOVE state. Like a real P0/P1 score component, it preserves playfield,
missile, and Ball geometry. It never owns VSYNC, VBLANK, the RIOT timer, or
collision-latch clearing.

Use it wherever an ordinary short score component would be composed:

```vcsc
template "renderers/poison_debug_score/poison_debug_score.c26" as poison
```

Set `poison_exit_background` to the background expected by the following
component. A following gameplay component must produce the same raster and
P0/P1/Ball positions after `poison_draw()` as it does after friendly state.
Failures are intentionally loud and repeatable; the component uses fixed
patterns rather than random values. The maintained composition matrix now proves hostile-state recovery for all
four 181-line gameplay families in both score orders. The player-color and
all-five physical-pixel models cover ordinary and clipped object endpoints; all
four gameplay components explicitly restore normal player reflection before
installing gameplay graphics.

## Target type definitions

`vcs.c26` supplies the stock VCS names for signed and unsigned 8-, 16-, 24-,
and 32-bit binary integers, plus `bcd8_t`, `bcd16_t`, `bcd24_t`, and
`bcd32_t` packed-decimal types. The BCD widths hold two, four, six, and eight
decimal digits and are especially useful for scores and counters.

The complete language rules for integer flags, literal conversion, arithmetic,
casts, packed BCD, parameters, and memory-backed returns belong to the compiler
and are documented in [`../../compiler/README.md`](../../compiler/README.md).
This directory documents only the names and target bindings supplied by the VCS
machine definition.

Compile with an include path that can see this directory, for example:

```sh
vcsc-cc1 -I libraries/vcs source.c26
```

Build a raw 4K cartridge directly with the driver:

```sh
vcsc -I libraries/vcs source.c26 -o game.bin
```

A `.bin` output name asks the linker for a contiguous flat binary; this VCS
layout produces exactly 4096 bytes mapped at `$F000-$FFFF`.

Build a full-window bank-switched cartridge by compiling an inspectable C26
profile as a configuration-only input:

```sh
vcsc -I libraries/vcs -T libraries/vcs/vcs.cfg \
  libraries/vcs/vcs_8k_f8.c26 source.c26 -o game-f8.bin
vcsc -I libraries/vcs -T libraries/vcs/vcs.cfg \
  libraries/vcs/vcs_16k_f6.c26 source.c26 -o game-f6.bin
vcsc -I libraries/vcs -T libraries/vcs/vcs.cfg \
  libraries/vcs/vcs_32k_f4.c26 source.c26 -o game-f4.bin
```

When source uses `bank0`, `bank1`, or another named placement modifier, include
the profile instead of merely passing it as a separate input:

```vcsc
include "vcs_8k_f8.c26"

bank1 void remote_code(void) {
   // ...
}
```

The build still uses `-T libraries/vcs/vcs.cfg`; no profile-specific cfg and no
special suppression macro are required.

The profiles use descending VCSC logical banks with BANK0 at `$F000-$FFFF` as
the home/startup bank and final 4K file chunk.  File order and selectors are:

```text
profile  first file chunk          final file chunk          selector range
-------  ------------------------  ------------------------  --------------
F8       BANK1 $D000 via $1FF8     BANK0 $F000 via $1FF9    $1FF8-$1FF9
F6       BANK3 $9000 via $1FF6     BANK0 $F000 via $1FF9    $1FF6-$1FF9
F4       BANK7 $1000 via $1FF4     BANK0 $F000 via $1FFB    $1FF4-$1FFB
```

Every bank allocates ordinary ROM only through `$xEFF`.  `$xF00-$xFDF` is the
byte-identical trampoline table, `$xFE0-$xFF1` is the byte-identical vector
bridge, and the remaining tail contains reserved selector bytes and vectors.
F4 selectors `$1FFA/$1FFB` overlap the NMI vector bytes; identical vectors in
every physical bank make the fetch deterministic and leave BANK0 selected.

Unmarked functions and const objects are placed automatically.  Hard source
pins use named memory modifiers matching the profile:

```vcsc
include "vcs_8k_f8.c26"

bank1 void remote_code(void) {
   // ...
}
```

Plain `void main(void)` needs no bank qualifier. The linker pins it, startup,
and required runtime material to the profile's unique `startup=yes` bank (BANK0
in these public profiles). Direct cross-bank `JSR` and `JMP` are rewritten
through the replicated common table. Ordinary cross-bank ROM data references
remain errors.

Immutable code and data that must be directly available in several banks can be
replicated explicitly:

```vcsc
bank0 bank1 const uint8_t table[2] := { 0x31, 0x42 };

bank0 bank1 uint8_t lookup(uint8_t index) {
   return table[index];
}
```

The modifier set is order-insensitive. The linker emits one object and function
copy in each listed bank, binds a caller or data reference to its bank-local copy,
and reports every copy and its physical ROM cost in the map. Object references
from a bank without a listed copy are errors. Function calls from such a bank may
fall back to a replicated body in another bank through the ordinary trampoline.
Copies are independently packed and need not occupy the same offset.

Notes:

- `vcs.c26` is the easiest entry point for a VCS target. It defines the machine types and memory regions, then includes `tia.c26` and `riot.c26`.
- Compiled BCD arithmetic scopes decimal mode to the actual `ADC`/`SBC` chain and executes `CLD` afterward. Inline assembly that executes `SED` remains responsible for clearing decimal mode itself.
- `tia.c26` and `riot.c26` can also be included separately if you already have your own base machine definition.
- `vcs_2k.c26` describes a 2048-byte cartridge linked at `$F800-$FFFF`, with vectors in its final six bytes; select it explicitly through reduced `vcs.cfg`.
- `vcs_4k.c26` describes the standard 4K cartridge mapped at `$F000-$FFFF` with vectors at `$FFFA-$FFFF`; the driver compiles it automatically when no `-T` is supplied.
- The F8/F6/F4 and SC `.c26` profiles are installed beside `vcs.cfg` and emit exact 8K, 16K, and 32K images. The old profile-specific cfg files remain installed temporarily for compatibility and simulator selection.
- `vcsc` discovers `vcs.cfg` and `vcs_4k.c26` in the source tree or installed `share/vcs` directory and uses both by default. Pass `-T vcs.cfg` plus another C26 profile to select a different cartridge layout.
- The 128 physical RIOT RAM bytes are not double-counted. `vcs.c26` declares the full `$80-$FF` block and reduced `vcs.cfg` asks `vcsc-ld` to reserve the top bytes dynamically from the whole-program source call graph before placing ordinary storage. The page-1 addresses `$0180-$01FF` are mirrors of `$80-$FF`, not separate RAM.
- Current stack sizing accounts automatically for source-level JSR return addresses; ordinary generated calls push no compiler state. Assembly components use `.callstackextra` object metadata for calls, pushes, or stack-pointer use hidden from the source call graph. C26 renderer templates emit the same assembler directive through inline assembly, including an explicit zero when an audited hidden JSR fits entirely inside the source-call reserve. `player_color_192` now flattens its two single-use mask-preparation wrappers and declares `.callstackextra 0`; the standard and multi-object renderers still declare their measured four supplementary bytes for deeper/repeated helper chains. The standard renderer also exports its assembly-initiated overscan-hook edge. Component code and score-table layouts carry startup-region, page-alignment, private-route, `.pagecontain`, and `.indexrange` facts in the object instead of renderer-specific cfg products. Arbitrary inline-assembly stack use must still be declared explicitly.
- Example 04 uses one balanced `PHP`/`PLA` pair per probe to read P and verifies that the linked map leaves the byte immediately below the call-stack reserve unused.
- `legacy-basic-renderers/` remains untouched reference/source material imported from upstream legacy BASIC. The all-five solid-color profile and the separate no-missile per-row-player-color profile are reproducibly normalized beside their contracts and exercised by complete cartridges. See `LEGACY_RENDERER_CONVERSION.md` for the staged conversion inventory.
- The VCS hardware mirrors TIA and RIOT addresses heavily. The bindings use the conventional canonical addresses.

### Superchip profiles and allocatable RAM

The public `vcs_8k_f8sc.c26`, `vcs_16k_f6sc.c26`, and `vcs_32k_f4sc.c26`
profiles use the same logical-bank and hotspot order as F8/F6/F4 while reserving
the first 256 bytes of every physical 4K chunk for the shared 128-byte
Superchip RAM ports. Ordinary ROM placement begins at `$x100`; complete 4K
chunks are still emitted. Hardware power-on contents are unspecified. VCSC
startup therefore clears every allocated Superchip BSS object and copies every
allocated DATA initializer through `$F000-$F07F` on every reset. Mapper switches
preserve the shared physical bytes; reset intentionally reinitializes them.
Unallocated bytes have no compiler/runtime lifecycle guarantee.

Include `superchip.c26` after `vcs.c26` to obtain the allocatable named
region:

```c
mem superchip { $read_start:0xF080 $write_start:0xF000 $size:0x0080 $rw };
```

Applications may allocate persistent globals, arrays, automatic locals,
function-scope static locals, value parameters, and function return objects
directly:

```c
superchip uint8_t foo;
superchip uint8_t buffer[32];

void update(superchip uint16_t value) {
   superchip uint8_t scratch := foo;
   static superchip uint8_t calls;
   value += 1; // caller writes $F000 alias; this load/store uses both aliases
   scratch++;
   calls++;
   foo := scratch;
}

superchip uint16_t current_value(void) {
   $$ := foo;       // write through $F000
   $$ += 1;         // read through $F080, write through $F000
   return;
}
```

A split declaration spells the read address first and the write address second;
their numerical ordering is unrestricted. For the Superchip profile, loads use
`$F080-$F0FF`; stores, initializer copies, BSS clearing, local initializer
writes, parameter copies, and return writes use `$F000-$F07F`. Automatic locals
keep VCSC's fixed, non-reentrant
backing storage and participate in the call-graph activation overlay; inline
expansions receive private local symbols. Function-scope `static superchip`
objects instead occupy persistent `BSS.superchip` or `DATA.superchip` storage.
Their constant and runtime initializers run through the ordinary startup paths
exactly once, not whenever control reaches the declaration. The 128 physical
bytes are shared by every ROM bank and counted once in the map.

Direct and runtime indexing, compound assignment, increment/decrement, and
bitfield updates are alias-aware: they load through the read port and store
through the write port. Plain address-taking, pointer decay, and passing a split
object to an ordinary `ref T` remain rejected because the object has no single
read/write address.
A split object may bind to `ref const T`, which passes its `$F080` read alias, or
`ref writeonly T`, which passes its `$F000` write alias. Both remain ordinary
one-address reference arguments; no fat pointer is introduced. Split-address
value parameters are supported: callers copy through the write alias using the
ordinary selective-staging rule, while callees load through the
read alias and store through the write alias. Only an argument which must
survive a function call in a later argument remains in caller scratch. A
non-void function may likewise use `superchip` to place its exact-sized hidden
return object in the shared window. `return expression;` and assignments to `$$`
write through `$F000`, while callee and caller reads use `$F080`. One or more separate
read-only bank modifiers may independently select function-body copies, for
example `bank0 bank1 superchip uint16_t sample(void)`. Modifier order is
irrelevant; bodies use `CODE.bank0` and `CODE.bank1` while every copy shares the
single `sample$__return` object in Superchip RAM. A bank-local call is preferred;
a caller in another bank may use a normal trampoline to the primary copy.

A Superchip result function may declare one automatic local in the same
`superchip` region and return that local on every return path. When its type and
storage contract match exactly and its address does not escape, VCSC aliases the
local with `function$__return`: initialization and later stores use `$F000`,
reads use `$F080`, no second Superchip allocation is made, and the final copy is
omitted. Explicit `$$` access, a `ref` escape, a different region name, or any
other contract mismatch retains the normal separate local and result objects.
The map's `RETURN COALESCING` section records the optimization and both aliases.

Directional ref capability is part of same-translation-unit function
compatibility and linker-visible ABI fingerprints, while ordinary `ref T` still
requires a single
shared address.
Absolute bindings may not overlap the allocator-managed Superchip windows,
so persistence probes must own storage through `superchip` like ordinary
application objects. The maintained diagnostic suite occupies all 128 bytes as
mixed BSS and DATA, starts the simulator from a hostile nonzero fill, checks
initialization and aliases throughout the complete bank-transition matrix,
poisons the region, resets without clearing RAM externally, and passes only if
startup restores the declarations. Stella performs the same poison/reset/pass
lifecycle with its console-reset key. The map lists every copy and clear in
`STARTUP INITIALIZATION`; deterministic allocation overflow remains a linker
error naming the object which does not fit.

## License

Everything under `libraries/` is covered under CC0-1.0. See `libraries/LICENSE.txt`.
