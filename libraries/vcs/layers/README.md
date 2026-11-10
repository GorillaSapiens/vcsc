```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Cooperating all-five layers — experimental

This file is covered under CC0-1.0. See libraries/LICENSE.txt.

This directory starts the component-based replacement for the private combined
colour previews. The intro and scenery sections work; **vertical object
advancement is not implemented yet**. Existing renderers and examples are unchanged.

## Horizontal intro

`all_five_intro.c26` owns no RAM. Its `establish()` entry positions P0, P1, M0,
M1 and Ball, applies HMOVE once, and restores both runtime NUSIZ values. It does
not reset vertical progress or touch graphics pointers, palettes, delayed
graphics configuration, or object enables.

Define the shared objects once, outside the component:

```c
include "vcs.c26"
uint8_t layers_object_x[5];
uint8_t layers_player0_nusiz;
uint8_t layers_player1_nusiz;
instantiate "layers/all_five_intro.c26" as intro
```

Object indices are P0, P1, M0, M1, Ball. X coordinates use the certified
divide-by-fifteen convention, 0 through 159. These are actual shared linker
symbols; C26 expression aliases do not substitute raw assembly operands.

Call `intro_establish()` during blanking, after any preceding component that
changes horizontal positioning. Its WSYNC cost depends on X; the enclosing
frame deadline must absorb that work. It does not turn off VBLANK or start the
visible display. A fixed-duration visible intro, including score-above placement,
is not certified by this initial implementation.

The normal-runner `test/vcs_layers_intro.pl` replaces only the certified
renderer’s positioning block with this component. It checks full-image exact
Stella equivalence at edge positions, unchanged RAM use, and rejection of a
missing-intro mutation. Vertical preparation and drawing remain independent.

## Scenery sections

Instantiate `layers/section.c26` with these four scenery parameters:

| Parameter | Meaning |
| --- | --- |
| `number_of_scanlines` | Positive even height, 2 through 254 |
| `playfield_row` | One asymmetric visual row, repeated for the whole section |
| `pf_color` | Playfield colour byte |
| `bk_color` | Background colour byte |

Instantiate another section to change either its row or its colours. There is no
fixed eight-section geometry and no separate playfield-row schedule.

```c
instantiate "layers/section.c26" as sky (
   number_of_scanlines:=6, playfield_row:=0x81244596,
   pf_color:=0x46, bk_color:=0xc2
)
instantiate "layers/section.c26" as ground (
   number_of_scanlines:=186, playfield_row:=0x3c96a569,
   pf_color:=0x8e, bk_color:=0x26
)
```

The row is a 32-bit left-to-right visual literal, using the same convention as
`VCS_PLAYFIELD_ROW()`. Binary visual literals can be used instead of hexadecimal.
The caller establishes `PF0 := 0` and reflected playfield order (`CTRLPF` bit 0
set), and owns frame timing and all other `CTRLPF` bits.

Call `sky_draw(); ground_draw();` directly after `vcs_ntsc_end_vblank()`.
Both draw entries require cycle 3 and return at cycle 3 on the following line;
**do not insert `vcs_ntsc_component_handoff()` between these sections**. Each
draw completes exactly its configured scanlines, with no leading WSYNC or blank
separator. Inline expansion is required; an ordinary JSR/RTS changes the phase.
The caller ensures that section heights fit its visible-frame budget. This
cycle-3 scenery-only contract is provisional: it must yield to the complete
shared object drawing schedule, not constrain that schedule into a broken seam.

Sections own no RAM and clobber only A, X and flags. Left PF1/PF2 writes are at
20/25; right PF2/PF1 writes are at 48/53. Equal constants retain the same phases.
Sections do not touch any object register, pointer or coordinate. They preserve
already-enabled TIA objects across a seam, but **do not yet start, stop or advance
those objects vertically**. Static object-latch transparency is not a substitute
for the missing all-five graphics pipeline.

The composed fixture is [test/fixtures/layers/sections.c26](../../../test/fixtures/layers/sections.c26).
From the repository root it can be built with:

```sh
driver/vcsc -I libraries/vcs test/fixtures/layers/sections.c26 -o /tmp/opencode/sections.bin
```

It uses 399 ROM bytes and 9 RAM bytes, including two hardware-stack bytes. The
seven data bytes belong to the intro's shared X/NUSIZ inputs, not the sections.
`test/vcs_layers_sections.pl` checks complete exact-RGB scenery at seams 2/6/190,
held-enable transparency for all five objects, repeated and three-instance
composition, parameter rejection, and 420-frame timing with all four PF writes
checked on every visible line. A shifted-write mutation must fail. It samples
palette RGB independently and expands the visual bitmap itself, rather than
inheriting the old renderer's terminal-row PF schedule.

## Remaining all-five integration

`all_five_objects.c26` now supplies a single shared vertical-state owner. Include
it once after `vcs.c26`, **instead of** separately declaring the intro's X/NUSIZ
inputs. Set its public coordinates, heights, graphics pointers and NUSIZ inputs,
then call `layers_prepare_vertical()` once during blanking, before the intro.
It builds the BL/M1/M0 masks and initial player counters without changing any
public input or TIA register. It owns 76 RAM bytes; its preparation helper needs
six hardware-stack bytes at peak. This is shared state, not per-section storage.

Coordinates and inclusive height limits retain the certified renderer's
two-scanline convention. A player height of seven permits eight graphics rows;
row zero is the blank row. This preparer does not read or duplicate graphics or
player colour tables. The normal sprite-table page contracts still apply.

`test/vcs_layers_objects.pl` checks its masks against direct interval arithmetic,
including wrapping and empty extents, poisoned initial RAM, repeated preparation,
and unchanged input pointers/coordinates/heights/NUSIZ. A wrong Ball bias must
fail. `test/vcs_layers_intro.pl` also adapts this state into the independent,
unchanged ancestor drawing schedule and checks complete exact images with
independent player-row colours, alternate pointers, short heights and NUSIZ
copies. **That test adapter is not a section implementation.**

Object progress must be shared, not allocated or restarted per section. Add the
cycle-defined graphics/enable pipeline while preserving runtime graphics pointers,
heights, NUSIZ and independent player-row colours, inside stock RAM and one drawing
bank. All five objects must move vertically through the two-section boundary.
That acceptance gate remains outstanding. These scenery tests do not certify it.
