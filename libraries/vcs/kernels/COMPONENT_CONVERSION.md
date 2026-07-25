```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Maintained gameplay-kernel component conversion baseline

This file freezes the starting point for roadmap task 22i.  It is a conversion
contract, not a description of a completed component API.  The working
monolithic profiles remain installed until their replacements have emulator and
map evidence strong enough to retire them.

## Profiles in scope

| Profile | Gameplay objects | Public display RAM | Private RAM | Total module RAM | Embedded score ROM |
| --- | --- | ---: | ---: | ---: | ---: |
| `standard_4k_ntsc` | P0, P1, M0, M1, BL | 23 bytes | 57 bytes | 80 bytes | 88 bytes |
| `standard_4k_ntsc_playercolors` | P0, P1, BL plus per-row P0/P1 colors | 17 bytes | 60 bytes | 77 bytes | 88 bytes |

Both current objects reserve a `$0300` `KERNEL_CODE` window and a `$0058`
page-contained `KERNEL_RODATA` score table.  Those are baseline costs, not
budgets granted to the replacements.

## Score ownership that must disappear

Each monolith currently owns four unambiguously score-only RIOT bytes:

- a three-byte packed score;
- one score-color byte.

Removing those declarations gives a first, mechanically provable public-state
floor of 19 bytes for the all-five profile and 13 bytes for the player-color
profile.  This is only a floor.  The twelve-byte `*_pointer_workspace` is mixed:
its first six bytes hold score pointers, while the remaining bytes are reused by
horizontal positioning, object counters, Y restoration, and score drawing.
No portion of that workspace may be advertised as saved until the extracted
component's map proves it is absent or smaller.

The 88-byte decimal font table and the score drawing/pointer code must also
vanish from a gameplay-only link.  A cartridge that instantiates no
`six_glyph_component.c26` must contain none of these symbols:

```text
vcs_standard_score
vcs_standard_score_color
vcs_standard_score_table
vcs_standard_color_score
vcs_standard_color_score_color
vcs_standard_color_score_table
```

## Frame ownership that must move to the application

The current entry points are whole-frame drivers.  They wait for overscan,
generate VSYNC, start RIOT timers, position objects during VBLANK, draw the
playfield/object field, draw the embedded score, assert VBLANK, call an overscan
hook, and return.

A lifecycle replacement must not write `VSYNC`, `VBLANK`, or a RIOT timer.  Its
visible `draw()` may use `WSYNC` internally because the kernel is inherently
scanline scheduled, but it must enter and leave on documented cycle-zero
boundaries and consume exactly its published visible-line count.  `init()`,
`vblank()`, and `overscan()` must publish conservative cycle budgets and must not
hide frame padding.

## The 192-line composition constraint

The inherited gameplay field is already:

```text
12 playfield rows * 16 scanlines per row = 192 scanlines
```

The embedded score is drawn in addition to that field by the old whole-frame
schedule.  Therefore the component conversion cannot preserve a 192-line
gameplay field and merely append the eleven-line reusable score inside a new
192-line scheduler region.  The replacement must choose and test an explicit
composition profile—for example a shorter gameplay row schedule—or document
that a particular full-height gameplay profile cannot be composed with a score
inside 192 visible lines.  The application, not either component, emits every
remaining blank line.

No row-height or cropping choice is made by this baseline step.  It must be
selected with raster evidence during extraction rather than guessed here.

## Evidence required before retiring a monolith

For each profile, the replacement must provide all of the following:

1. A gameplay-only lifecycle component and assembly object with no embedded
   score state, font, pointer setup, drawing code, or update path.
2. Exact map evidence for public/private RAM, ROM sections, call-stack depth,
   page placement, and the absence of every forbidden score symbol above.
3. Emulator evidence for object positions, playfield phases, colors, collision
   clearing, TIA cleanup, entry/exit cycles, frame length, and legal opcodes.
4. Static and motion applications that compose gameplay and score in both
   visible orders, using machine-readable line counts and explicit blank lines.
5. Source-tree and staged installed-toolchain builds of the same private golden
   fixtures.

The existing monolithic tests remain predecessor oracles.  They must not be
weakened or rewritten to accept the replacement; new component fixtures compare
against them where the selected composition profile is intended to preserve
behavior.
