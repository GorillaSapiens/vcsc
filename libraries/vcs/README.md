```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Atari 2600 / VCS support files

This directory contains target support files for the Atari 2600 / VCS.

Files:

- `vcs.c26` ... VCS machine definition with types, memory regions, and hardware includes
- `tia.c26` ... TIA hardware register bindings
- `riot.c26` ... RIOT I/O and timer register bindings plus RIOT RAM region names
- `vcs_4k.cfg` ... linker configuration for a conventional unbanked 4K cartridge
- `color_ntsc.c26` ... readable aliases defined through the compile-time `__builtin_ntsc_rgb(r, g, b)` NTSC palette matcher
- `frame_ntsc.c26` ... shared NTSC phase constants, scanline waiting, VSYNC, and scheduler-owned VBLANK/overscan deadlines
- `playfield.c26` ... compile-time `VCS_PLAYFIELD_ROW()` conversion from left-to-right 32-bit visual rows to the four asymmetric TIA playfield bytes
- `sound_ntsc.c26` ... NTSC TIA audio-control, note-frequency, volume, and frame-timing aliases
- `six_glyph_component.c26` ... repeatable lifecycle-template centered 48-pixel/six-glyph display with fixed bright-white color and hostile-state-safe reflection reset
- `six_glyph_left_component.c26` ... eleven-line fixed-color variant justified at X=0..47
- `six_glyph_right_component.c26` ... eleven-line fixed-color variant justified at X=112..159
- `six_glyph_color_component.c26` ... timing-compatible centered mutable-color twin used by interactive score diagnostics, with the same hostile-state-safe reflection reset
- `renderers/COMPONENT_CONVERSION.md` ... measured predecessor baseline, machine-readable visible-component handoff/TIA ownership table, and the explicit 181-line score-composable, 192-line scoreless, and matched unofficial profile contracts
- `renderers/all_five_181/` ... official-opcode 181-line P0/P1/M0/M1/BL lifecycle component, derived from the proven player-color raster and using solid player colors, for composition with an independent eleven-line score
- `renderers/all_five_181_unofficial/` ... matched stable/common-NMOS experimental twin with the same API, RAM contract, and corrected raster schedule
- `renderers/all_five_192/` ... distinct official-opcode 192-line scoreless P0/P1/M0/M1/BL lifecycle component, derived from the proven player-color raster and using solid player colors
- `renderers/player_color_181/` ... official-opcode 181-line P0/P1/BL lifecycle component with page-contained per-row P0/P1 colors and tested score-above/score-below composition
- `renderers/player_color_181_unofficial/` ... matched stable/common-NMOS experimental twin of the 181-line player-color component; measured zero-byte saving
- `renderers/player_color_192/` ... distinct official-opcode 192-line scoreless P0/P1/BL lifecycle component with page-contained per-row P0/P1 colors
- `renderers/poison_debug_score/` ... one-byte adversarial eleven-line score-profile component that trashes deterministic P0/P1 state while preserving playfield, missile, and Ball geometry
- `renderers/standard_4k_ntsc/` ... legacy monolithic all-five-object solid-color profile retained for compatibility and regression
- `renderers/standard_4k_ntsc_playercolors/` ... legacy monolithic P0+P1+BL player-color profile retained for compatibility and regression
- `fonts/` ... eight shared 8x8 score-font families plus the six-slice `logo_font.c26` VCSC mark
- `../../examples/README.md` ... renderer-grouped public example index
- `../../examples/01_basic/` ... standalone cartridges and reusable-component examples
- `../../examples/02_faithful_legacy_playercolors/` ... faithful legacy interactive compatibility diagnostic
- `../../examples/03_player_color_192/` ... full-height scoreless interactive player-color diagnostic
- `../../examples/04_player_color_181/` ... official-opcode interactive score-above and score-below 181-line player-color diagnostics
- `../../examples/05_all_five_192/` ... official-opcode full-height all-five interactive diagnostic
- `../../examples/06_all_five_181/` ... official-opcode interactive score-above and score-below 181-line all-five diagnostics
- `../../examples/07_player_color_181_unofficial/` ... matched unofficial-opcode player-color examples, built explicitly with `-Wa,--illegals`
- `../../examples/08_all_five_181_unofficial/` ... matched unofficial-opcode all-five examples, built explicitly with `-Wa,--illegals`

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
      vcs_ntsc_wait_component_scanlines() instead of the generic WSYNC loop. */
   /* Draw exactly VCS_NTSC_VISIBLE_SCANLINES here. */

   vcs_ntsc_begin_overscan();
   /* Run component overscan callbacks here. */
   vcs_ntsc_end_overscan();
}
```


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
patterns rather than random values. The maintained player-color fixtures now
prove that handoff for both score orders over every X coordinate from 0 through
159, including clipped horizontal endpoints and terminal gameplay lines.

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

Notes:

- `vcs.c26` is the easiest entry point for a VCS target. It defines the machine types and memory regions, then includes `tia.c26` and `riot.c26`.
- Compiled BCD arithmetic scopes decimal mode to the actual `ADC`/`SBC` chain and executes `CLD` afterward. Inline assembly that executes `SED` remains responsible for clearing decimal mode itself.
- `tia.c26` and `riot.c26` can also be included separately if you already have your own base machine definition.
- `vcs_4k.cfg` assumes a standard 4K cartridge mapped at `$F000-$FFFF` with vectors at `$FFFA-$FFFF`.
- `vcsc` discovers this file in the source tree or installed `share/vcs` directory and uses it by default. Pass `-T` only to select a different cartridge layout.
- The 128 physical RIOT RAM bytes are not double-counted. `vcs_4k.cfg` declares the full `$80-$FF` block and asks `vcsc-ld` to reserve the top bytes dynamically from the whole-program source call graph before placing ordinary storage. The page-1 addresses `$0180-$01FF` are mirrors of `$80-$FF`, not separate RAM.
- Current stack sizing accounts automatically for source-level JSR return addresses; ordinary generated calls push no compiler state. A linker configuration may add `callstack_extra` bytes for hardware-stack use declared by an included assembly module. Both maintained standard-renderer objects export their assembly-initiated overscan-hook edge and use four supplementary bytes for the deeper internal mask-preparation chain. Arbitrary inline-assembly pushes and stack-pointer manipulation are still not inferred.
- Example 04 uses one balanced `PHP`/`PLA` pair per probe to read P and verifies that the linked map leaves the byte immediately below the call-stack reserve unused.
- `legacy-basic-renderers/` remains untouched reference/source material imported from upstream legacy BASIC. The all-five solid-color profile and the separate no-missile per-row-player-color profile are reproducibly normalized beside their contracts and exercised by complete cartridges. See `LEGACY_RENDERER_CONVERSION.md` for the staged conversion inventory.
- The VCS hardware mirrors TIA and RIOT addresses heavily. The bindings use the conventional canonical addresses.
