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

A lifecycle replacement must not write `VSYNC`, `VBLANK`, or a RIOT timer. Its
visible `draw()` uses `WSYNC` internally because the kernel is inherently
scanline scheduled, but it must enter and leave on documented cycle-zero
boundaries and consume exactly its published visible-line count. Blanking
callbacks may use WSYNC for bounded internal scheduling such as horizontal
positioning; every stalled cycle is charged to the scheduler-owned deadline and
included in the published maximum-cycle budget. Only the scheduler may wait on
or read the timer, write VBLANK, or issue the final phase-transition WSYNC.
`init()`, `vblank()`, and `overscan()` must not hide frame padding.

## Selected visible-profile matrix

The conversion no longer leaves the shorter composition profile open-ended.
Each maintained gameplay family has these explicit products:

| Profile | Gameplay lines | Score ownership | Opcode policy |
| --- | ---: | --- | --- |
| score-composable | 181 | none; `main()` must compose the independent 11-line six-glyph component | official 6502/6507 only |
| full-height scoreless | 192 | none; no score fits beside it inside the standard visible field | official 6502/6507 only |
| score-composable unofficial twin | 181 | none; same application contract as the official 181-line component | reviewed stable/common NMOS unofficial forms allowed |

The ordinary score-bearing application contract is exact:

```text
181 gameplay scanlines + 11 six-glyph scanlines = 192 visible scanlines
```

The gameplay component therefore publishes `VISIBLE_SCANLINES := 181`; the
existing six-glyph component publishes eleven. `main()` must call both draw
operations and may place the score above or below gameplay. It must not add
another hidden blank-line allowance or silently crop either component. The
component implementation owns the complete internal accounting needed to enter
and leave on its documented scanline boundaries.

The full-height component is a separate, explicitly named 192-line scoreless
profile. It preserves the predecessor's full gameplay-height use case without
pretending an eleven-line score can also fit inside the same 192-line field.
This is not a compile-time switch hidden inside the 181-line source: maps,
fixtures, timing contracts, and diagnostics must identify which profile was
linked.

The unofficial-opcode experiment is likewise a separate source/profile, not a
hidden alias. Its public API, public and private RAM layout, visible TIA-write
schedule, object positions, collision behavior, entry/exit cycles, and 181-line
contract must match the official score-composable component. Only then may the
linked executable-byte totals be compared. The report must state the official
and unofficial linked ROM byte counts and their signed difference; a zero or
negative saving is a valid result. Only reviewed stable/common NMOS 6502/6507
forms are eligible. Silicon-sensitive or unstable forms remain forbidden.

The inherited monolith's gameplay field is twelve 16-line rows, or 192 lines.
Producing the new 181-line profile therefore requires an explicit retimed or
reduced gameplay schedule. The extraction regression must lock that internal
choice; neither this contract nor an application may disguise the missing
11 lines as scheduler padding.

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
