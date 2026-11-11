```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Cooperating all-five layers — experimental

This file is covered under CC0-1.0. See libraries/LICENSE.txt.

`all_five_section.c26` now draws scenery **and advances all five objects through
adjacent, independently instantiated sections**. The minimum two-scanline section
works. No-score, score-above and score-below fixtures now run in one4K bank and
stock RAM, including runtime animation and score changes. This remains
experimental: full horizontal/copy certification and finished example leaves
are outstanding. Existing renderers and default examples are unchanged.

## Working all-five composition

Use `all_five_dense_objects.c26` once for shared state, `all_five_intro.c26` once
for horizontal positioning, and `all_five_section.c26` for each scenery section.
Do not include the alternative compact `all_five_objects.c26` at the same time.

Each section has exactly four configuration parameters:

| Parameter | Meaning |
| --- | --- |
| `number_of_scanlines` | Positive even height, 2 through 254 |
| `playfield_row` | One asymmetric visual32-bit row, repeated throughout |
| `pf_color` | Playfield colour byte |
| `bk_color` | Background colour byte |

```c
instantiate "layers/all_five_section.c26" as sky (
   number_of_scanlines:=6, playfield_row:=0x81244596,
   pf_color:=0x46, bk_color:=0xc2
)
instantiate "layers/all_five_section.c26" as ground (
   number_of_scanlines:=186, playfield_row:=0x3c96a569,
   pf_color:=0x8e, bk_color:=0x26
)
```

The application supplies page-safe `layers_player0_colors[8]` and
`layers_player1_colors[8]`, runtime graphics pointers/heights/NUSIZ, and the
shared coordinates. Graphics row zero is blank. Coordinates/heights retain
two-scanline units and inclusive extent limits. Player row colours are independent;
no sprite graphics are copied or mirrored.

The frame owner selects extended VBLANK. Its ordinary blanking callback calls
`layers_prepare_vertical(); intro_establish(); layers_prime();`. That callback
is outside the visible drawing schedule and needs no geometry list. It prepares
one96-byte Ball/M0/M1 enable stream, using at most seven constant runs, without
changing public coordinates/heights/pointers/NUSIZ. Each section consumes that
same stream and the same two player counters; it never initializes object progress.

After `vcs_ntsc_end_vblank()`, call `sky_first(); ground_draw();` with **nothing
inserted between them**. `first()` enters at cycle3; subsequent `draw()` entries
and all section exits are cycle74 of the preceding/final line. X is the live
shared pair cursor, Y the last P0 index. Registers, flags and delayed Ball state
are part of the handoff. There is no WSYNC, horizontal positioning, or separator
inside a section. After the final section, a NOP finishes its last two cycles
before the frame owner begins overscan. A no-score frame has192 gameplay lines;
the score compositions below allocate fewer gameplay lines within the same frame.

First-line PF stores are at3/32/48/53 (the first frame entry uses8 instead of3);
second-line stores are18/23/48/53. Both active/blank player branches are balanced.
The final pair uses a **four-cycle `.cross` branch**; ordinary pairs use the
untaken branch plus NOP, also four cycles. A never-executed ROM island makes
ordinary inline instances256 bytes, preserving these page contracts across any
sequence of heights. It adds ROM bytes, not scanlines or runtime delay. All
`.same`/`.cross` contracts remain checked by the assembler/linker.

The runnable fixture is
[all_five_sections.c26](../../../test/fixtures/layers/all_five_sections.c26).
From the repository root:

```sh
driver/vcsc -I libraries/vcs test/fixtures/layers/all_five_sections.c26 -o /tmp/opencode/layers.bin
driver/vcsc -DLAYERS_MOTION -I libraries/vcs test/fixtures/layers/all_five_sections.c26 -o /tmp/opencode/layers-moving.bin
driver/vcsc -DLAYERS_MOTION -DLAYERS_CONTROLS -I libraries/vcs test/fixtures/layers/all_five_sections.c26 -o /tmp/opencode/layers-controls.bin
```

The second build moves all five objects vertically and selects four distinct
animation frames through the runtime pointers. The third also changes runtime X
and cycles all eight player/missile copy/stretch modes in the bounded layouts
listed below. Static shared RAM is124/128 bytes
(122 data +2 stack); motion uses125/128. Interval consideration is expanded
inline during blanking, avoiding the previous nested JSR/RTS and recovering
two stack bytes without changing public inputs or visible timing.
No per-section RAM or cartridge RAM is
used. The fixture calibrates the blanked frame boundary to264 raw harness lines;
that calibration is not an extra line between visible components.

These motion/control builds are **stress tests**, not presentation demos: they
cycle a small vertical range and animation frames rapidly. To inspect their
seams, Stella defaults are Ctrl+Shift+S to slow down, Ctrl+S to speed up and
Ctrl+T to toggle turbo. The separate
[preview.c26](../../../test/fixtures/layers/preview.c26) traverses three64-line
bands at about30 pixels/second, reversing at the screen ends without teleporting
at scenery seams. Only its exhaust changes at7.5 fps. It uses127/128 RAM bytes.

```sh
driver/vcsc -I libraries/vcs test/fixtures/layers/preview.c26 -o /tmp/opencode/layers-preview.bin
stella /tmp/opencode/layers-preview.bin
```

## Cooperating score compositions

`score.c26` draws two packed-BCD fields using the shared immutable
`two_plus_two_score_support.c26` tables. It owns only two mutable bytes:
`left_score` and `right_score`. Its eight glyph-pointer bytes borrow
`layers_object_masks[88..95]`; gameplay must therefore total **176 lines or
fewer**, so none of those bytes is consumed by a section. No graphics or font
tables are mirrored. The no-score state owner and drawing schedule are unchanged.

Call `layers_prepare_vertical()` **before** `score_prepare()` during blanking.
Do not prepare the mask stream again between score preparation and drawing.
The frame owner declares the actual even gameplay total with `gameplay_scanlines`
(default176; allowed2..176); it is responsible for matching that declaration to
the sum of section calls. Independent sections do not gain a shared geometry list.

Other score parameters are `left_x` (0..64), `right_x` (32..144), `left_color`
and `right_color`. These positions/colours are compile-time configuration;
the BCD values remain runtime inputs. This is a RAM-constrained cooperating
score, not a replacement for the stock score component's independent runtime
position/colour controls. The existing score components and defaults are untouched.

Two runnable layouts:

| Fixture | Frame layout | Static / motion RAM |
| --- | --- | --- |
| [score_below.c26](../../../test/fixtures/layers/score_below.c26) |176 gameplay +12 score +4 blank tail |126 /127 bytes |
| [score_above.c26](../../../test/fixtures/layers/score_above.c26) |12 score +8 blanked intro +172 gameplay |126 /127 bytes |

Both gameplay layouts have independent scenery instances and an exact all-five
crossing at gameplay line64. Runtime graphics pointers/heights/NUSIZ and both
eight-row palettes remain shared, not reinitialized at the seam. Both fixtures
provide four upright animation frames; `-DLAYERS_MOTION` moves all five through
the seam, changes both graphics pointers and increments both runtime BCD scores.
This optional fast motion is a regression sweep, like the no-score stress test.

```sh
driver/vcsc -DLAYERS_MOTION -I libraries/vcs test/fixtures/layers/score_below.c26 -o /tmp/opencode/layers-score-below.bin
driver/vcsc -DLAYERS_MOTION -I libraries/vcs test/fixtures/layers/score_above.c26 -o /tmp/opencode/layers-score-above.bin
```

Score-below enters the score at cycle3 immediately after the last gameplay line;
its first setup line clears scenery/enables and flushes delayed Ball/player
graphics. HMOVE owns a separate setup line so it cannot clip the first digit row
at X0. After twelve complete lines, both player graphics are cleared in the
following horizontal blank; the score returns at **cycle8**, not cycle0. The
frame owner absorbs those eight cycles in its four-line blank tail or the
score-above setup region. This preserves the last wide digit row through X144.
There are no inter-section separator lines.

Score-above repositions all five objects after the score with the intro's new
`establish_visible()` entry. **Every object X must be0..119 for this bounded
setup contract.** It enters at cycle3 and returns at cycle15 five lines later;
priming and a final WSYNC consume the rest of the frame owner's setup budget.
The frame owner alone asserts/clears VBLANK around all eight setup lines, so
positioning/priming cannot leak graphics into the score gap. It does not restart
the RIOT timer. Gameplay begins exactly20 lines after the score's first line.
This bounded intro timing is distinct from general visible drawing correctness.

The regression compares every gameplay, score, setup and tail pixel, using
independent canonical decimal glyphs. Values00/99,12/34,56/78,90/12 and all four
sprite frames pass both layouts. Score placement pairs0/144 and64/32 also pass
with different field colours, including the first and final digit rows. Each
layout also passes40 consecutive moving
frames with40 independently checked score values and a complete all-five seam
crossing. CPU checks cover420 frames, active stream bytes, reserved pointer
bytes, all PF/object phases and score-above RESP phases. Zero/max119/mixed X
vectors retain the positioning deadline. A mutant moving the score workspace
into active stream bytes must fail the memory oracle. Invalid declared gameplay
totals reject. The slower preview has a separate800-frame rate/pose/animation
model, covering both end-of-screen turnarounds and clock wrap.

`test/vcs_layers_all_five.pl` independently expands all192 lines of PF, glyphs,
per-row colours and enables into exact RGB. Only RGB palette conversion comes
from an independent solid-background witness. All five objects must be visibly
present on both sides of seams2,6,190. Short heights and alternate pointers pass;
40 consecutive moving frames must follow the independent pose model, include a
complete all-five seam crossing, and use all four animation frames. Additional
checks cover all96 enable bytes, preserved inputs, final counters, seven-run/wrap
preparation, repeated/three-instance compositions, equal constants, parameter
rejection, shifted-write rejection, and420-frame exact PF/object-write timing.

The logical oracle also models runtime horizontal positions, all eight NUSIZ
copy/stretch modes, missile copy offsets/widths and hardware overlap priority
(`P0/M0 > P1/M1 > PF/Ball`). It paints back to front independently of TIA writes.
All eight modes pass complete images at X coordinates `[10,40,30,65,120]`
(P0/P1/M0/M1/Ball), including overlapping copies and stretched players. Ordinary
player modes also pass `[0,0,30,65,120]`, `[1,1,30,65,120]` and
`[80,100,50,110,80]`. These are tested layouts, not a proved continuous X range.
Public X values, NUSIZ and graphics pointers are checked unchanged after drawing.
Another40 consecutive snapshots verify the live control changes against the
pose model, with all eight modes and four animation frames required to appear.
The original40-frame all-five visible seam-crossing test remains unchanged.

### Remaining limits

The immediate-player schedule writes P0 colour/graphics late in the previous
line and P1 colour late in its first line. Right-edge failures are now
**reproduced**, not merely uncertified: ordinary P0 at X150, ordinary P1 at X150,
and an M1 copy at X142 (base110 + mode2 offset32) fail the logical row image while
still passing all CPU frame/write-phase checks. The test retains explicit
known-defect witnesses for those right-edge pixels; they must be recertified
and converted into passing cases when the schedule is repaired. Shared player
colour deadlines therefore affect missiles as well as players.

**Do not infer full horizontal correctness** from the passing NUSIZ matrix or
the intro's separate positioning tests. These deadline cases still need a
schedule change. Runtime controls are retained, not frozen constants.

RAM remains tight: one byte is free in moving score/preview builds. General
application controls still need a lifetime/RAM plan. Score cleanup at arbitrary
hostile left-edge gameplay placements and runtime score-position/colour controls
are not certified. Finished independent example leaves are still outstanding.
The new components remain uninstalled and do not replace the existing default
or bounded-score renderers.

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
visible display. `establish_visible()` shares the exact same positioning body,
with a cycle3 entry replacing the initial WSYNC/BIT phase. Its bounded0..119
setup contract is used by score-above as described above. Choose either entry;
the former mandatory `establish()` call is no longer required when using the
alternate entry.

The normal-runner `test/vcs_layers_intro.pl` replaces only the certified
renderer’s positioning block with this component. It checks full-image exact
Stella equivalence at edge positions, unchanged RAM use, and rejection of a
missing-intro mutation. Vertical preparation and drawing remain independent.

## Earlier scenery-only timing experiment

`section.c26` is the earlier scenery-only experiment, **not** the all-five
component described above. Its cycle3 contract and tests remain separate.

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

## Compact-state preparation witness

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

Its eleven-cycle `layers_step_player0/1()` primitives preserve A/X and return
the shared row index in Y and the range test in C. The ancestor witness now
consumes those shared counters directly throughout drawing, rather than copying
them into old mask lanes. `all_five_section.c26` instead uses the dense stream;
the compact owner is retained as independently tested implementation evidence.
