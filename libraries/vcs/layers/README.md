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
experimental: score-above positioning and full application RAM still have the
limits documented below. Right-edge player output now passes the full X sweep.
Existing renderers and default examples are unchanged.

Three independent presentation layouts are available in
[`examples/04_renderers/cooperating_layers/`](../../../examples/04_renderers/cooperating_layers/):
`no_score`, `score_above`, and `score_below`. Each has its own Makefile and edits
its automatic scenery directly in `main.c26`; `interactive.c26` adds independent
joystick control using the established example sprites. Run `make play` for the
automatic preview or `make play-interactive` for controls. Neither variant
depends on test fixtures or another leaf. Automatic no-score uses46/128 RAM
bytes; automatic score leaves use56/128 including stack. Interactive versions
use46/58/58 bytes respectively. Score-above clamps object X to0..119; the others
allow0..159. These bounded examples do not certify arbitrary score-above
placements. Controls are documented in the example family guide.

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
`layers_player1_colors[8]`, runtime graphics pointers/heights, and the
shared coordinates. Graphics row zero is blank. Coordinates/heights retain
two-scanline units and inclusive extent limits. Player row colours are independent;
no sprite graphics are copied or mirrored.

The frame owner selects extended VBLANK. Its ordinary blanking callback calls
`layers_prepare_vertical(); intro_establish(); layers_prime();`. That callback
is outside the visible drawing schedule and needs no geometry list. It prepares
one14-byte Ball/M0/M1 run list, using at most seven constant runs, without
changing public coordinates/heights/pointers. NUSIZ values are intro parameters,
not RAM inputs. Each section consumes that
same run list and two player counters; it never initializes object progress.

After `vcs_ntsc_end_vblank()`, call `sky_first(); ground_draw();` with **nothing
inserted between them**. `first()` enters at cycle3; subsequent `draw()` entries
and all section exits are cycle53 of the preceding/final line. X holds the next
P0 glyph and Y its normalized row index. The event stack and live TIA enables
are also part of the handoff.
There is no WSYNC, horizontal positioning, or separator inside a section.
After the final section, call **`layers_finish()`**: it restores the ordinary
hardware stack and finishes the last23 cycles at cycle0 before overscan or score.
Do not retain
the old NOP finish. A no-score frame has192 gameplay lines;
the score compositions below allocate fewer gameplay lines within the same frame.

First-line PF stores are at18/33/48/51; a section boundary uses23 instead of18,
and the first frame entry uses8. Second-line stores are19/24/48/53. Both active/blank
player paths are balanced and all `.same` branch contracts are linker checked.

Player colour/graphics transfer exclusively in horizontal blank: P0 at10/13,
P1 at0/3. NMOS LAX reads each original ROM glyph into A/X without a RAM graphics
copy. Its explicit raw opcode is accepted by the ordinary assembler invocation.
The immediate LAX zero operand is used only to produce unconditional zero.
First, loop and terminal paths are explicit. All instances share one loop byte;
the height remains the same direct C26 parameter. No graphics tables are mirrored.

Each event record is `[duration, mask]`, with D0=M1, D1=Ball and D2=M0. The first
record supplies initial state; at most six further transitions need twelve bytes.
The final duration255 prevents an offscreen read past the initialized records.
Preparation merges coincident times. A countdown consumes the next record only
when due, with event/no-event paths balanced. No-event islands live inside skipped
player branches, avoiding an extra JMP on the worst-case event path.

`first()` saves the ordinary stack pointer, then uses S to read the existing
event array with PLA. This reuses the array itself; it does not reserve another
fourteen stack bytes. **No ordinary calls, pushes or pops may occur from first()
through the last draw().** `layers_finish()` must run before any score, overscan
callback or return. The supplied inline frame loop retains a two-byte ordinary
stack peak; additional wrappers still require checking the compiler's RAM report.

Ball/M1 update on odd-line9/14; M0 on even-line3, all before the beam. Both player
counters advance on the even line after P1 selection. Public Y and visible rows
are unchanged. Boundary background/PF colours arrive by18/28.

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
with constant intro NUSIZ parameters. Separate builds cover all eight
player/missile copy/stretch modes. Static shared RAM is44/128 bytes
(42 data +2 stack); motion uses45/128. Interval consideration is expanded
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
at scenery seams. Only its exhaust changes at7.5 fps. It uses47/128 RAM bytes.

```sh
driver/vcsc -I libraries/vcs test/fixtures/layers/preview.c26 -o /tmp/opencode/layers-preview.bin
stella /tmp/opencode/layers-preview.bin
```

## Cooperating score compositions

`score.c26` draws two packed-BCD fields using the shared immutable
`two_plus_two_score_support.c26` tables. It owns two BCD bytes, `left_score` and
`right_score`, plus eight glyph-pointer bytes. These pointers no longer overlap
the object schedule: there is no96-byte buffer tail to borrow. No graphics or
font tables are mirrored. The no-score state owner and drawing schedule are unchanged.

Call `layers_prepare_vertical()` **before** `score_prepare()` during blanking.
Both preparers have independent storage. Do not rebuild object progress during drawing.
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
| [score_below.c26](../../../test/fixtures/layers/score_below.c26) |176 gameplay +12 score +4 blank tail |54 /55 bytes |
| [score_above.c26](../../../test/fixtures/layers/score_above.c26) |12 score +8 blanked intro +172 gameplay |54 /55 bytes |

Both gameplay layouts have independent scenery instances and an exact all-five
crossing at gameplay line64. Runtime graphics pointers/heights and both
eight-row palettes remain shared, not reinitialized at the seam. Both fixtures
provide four upright animation frames; `-DLAYERS_MOTION` moves all five through
the seam, changes both graphics pointers and increments both runtime BCD scores.
This optional fast motion is a regression sweep, like the no-score stress test.

```sh
driver/vcsc -DLAYERS_MOTION -I libraries/vcs test/fixtures/layers/score_below.c26 -o /tmp/opencode/layers-score-below.bin
driver/vcsc -DLAYERS_MOTION -I libraries/vcs test/fixtures/layers/score_above.c26 -o /tmp/opencode/layers-score-above.bin
```

Score-below calls `layers_finish()` then enters the score at cycle3 immediately
after the last gameplay line;
its first setup line clears scenery/enables and flushes Ball/player
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
crossing. CPU checks cover420 frames, event records, dedicated pointer
bytes, all PF/object phases and score-above RESP phases. Zero/max119/mixed X
vectors retain the positioning deadline. A mutant shifting score pointer stores
must fail the memory oracle. Invalid declared gameplay
totals reject. The slower preview has a separate800-frame rate/pose/animation
model, covering both end-of-screen turnarounds and clock wrap.

`test/vcs_layers_all_five.pl` independently expands all192 lines of PF, glyphs,
per-row colours and enables into exact RGB. Only RGB palette conversion comes
from an independent solid-background witness. All five objects must be visibly
present on both sides of seams2,6,190. Short heights and alternate pointers pass;
40 consecutive moving frames must follow the independent pose model, include a
complete all-five seam crossing, and use all four animation frames. Additional
checks cover all initialized event bytes, preserved inputs, final counters, seven-run/wrap
preparation, repeated/three-instance compositions, equal constants, parameter
rejection, shifted-write rejection, and420-frame exact PF/object-write timing.

`test/vcs_layers_events.pl` independently decodes all96 pair masks from the compact
records during4096 frames of varied positions/extents, including wrapping and
coincident transitions. It checks initial state, final sentinel, unchanged public
inputs and an untouched poisoned tail/stack canary. This preparation-only oracle
is separate from exact visible images and never substitutes for them.

The logical oracle also models runtime horizontal positions, all eight NUSIZ
copy/stretch modes, missile copy offsets/widths and hardware overlap priority
(`P0/M0 > P1/M1 > PF/Ball`). It paints back to front independently of TIA writes.
All eight modes pass complete images at X coordinates `[10,40,30,65,120]`
(P0/P1/M0/M1/Ball), including overlapping copies and stretched players. Ordinary
player modes also pass `[0,0,30,65,120]`, `[1,1,30,65,120]` and
`[80,100,50,110,80]`. These overlap cases complement the isolated exhaustive
player sweeps below; they do not enumerate every combination of five positions.
Public X values and graphics pointers are checked unchanged after drawing.
Another40 consecutive snapshots verify the live control changes against the
pose model, with all eight modes and four animation frames required to appear.
The original40-frame all-five visible seam-crossing test remains unchanged.

### Remaining limits

The former right-edge failures at ordinary P0/P1 X150 and M1-copy X142 are now
positive full-image regressions. Player graphics and independent row colours no
longer change during right-edge output. An additional80 cases cover both players,
all eight modes and X0/127/143/150/159, including stretched and wrapped copies.
The independent model wraps player, missile and Ball output modulo160, matching
the hardware instead of silently clipping right-edge pixels.

The exhaustive two-player/eight-mode/**X0..159** matrix passes all2560 full images.
Each player is tested unoccluded with its missile and Ball, both extreme glyph
bits exercised, four animation frames and all four missile widths across the
sweep. The16 private ROMs change X and graphics pointers at runtime;
each contributes160 consecutive snapshots, not just a stationary compiled layout.
Each also passes420 CPU frames with independent per-frame X/pointer/counter/
mask checks. Eight shards run with eight workers and300-second workload budgets;
each snapshot sequence retains the common60-second deadline and process cleanup.

All95 even splits2..190 also pass full images, all-five crossings and60-frame
timing/memory checks. A single192-line instance passes timing; all even component
heights192..254 compile/link, without claiming that a254-line section fits a
192-line NTSC visible budget. The geometry proof retains all branch contracts
and caught/fixed a fixture substitution collision specifically at height186.

X, heights and graphics pointers remain runtime inputs. Missiles still
share their player's colour, including its per-row changes; independent missile
colours are not promised. The event kernel passes the focused edge/geometry gates
and both score compositions. Its fresh full eight-worker suite passes1327/1327.

RAM headroom is now73 bytes in moving score builds and72 in presentation scores. General
application controls still need a lifetime/RAM plan. Score cleanup at arbitrary
hostile left-edge gameplay placements and runtime score-position/colour controls
are not certified. Independent example leaves are available as linked above.
The components are installed for the independent examples, but do not replace
the existing default or bounded-score renderers.

## Horizontal intro

`all_five_intro.c26` owns no RAM. Its `establish()` entry positions P0, P1, M0,
M1 and Ball, applies HMOVE once, and restores both constant NUSIZ values. It does
not reset vertical progress or touch graphics pointers, palettes, delayed
graphics configuration, or object enables.

Define the shared objects once, outside the component:

```c
include "vcs.c26"
uint8_t layers_object_x[5];
instantiate "layers/all_five_intro.c26" as intro (
   player0_nusiz:=0x20, player1_nusiz:=0x20
)
```

Object indices are P0, P1, M0, M1, Ball. X coordinates use the certified
divide-by-fifteen convention, 0 through 159. These are actual shared linker
symbols; C26 expression aliases do not substitute raw assembly operands.

`player0_nusiz` and `player1_nusiz` are compile-time byte parameters, both
defaulting to `0x20`. They include player copy/stretch and missile-width bits.
The intro restores them after score drawing without any RAM shadows. Runtime
NUSIZ changes are no longer part of this component's interface. The two immediate
loads plus padding preserve the former total setup timing for both entry paths.

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

It uses 7 RAM bytes, including two hardware-stack bytes. The
five data bytes belong to the intro's shared X inputs, not the sections.
`test/vcs_layers_sections.pl` checks complete exact-RGB scenery at seams 2/6/190,
held-enable transparency for all five objects, repeated and three-instance
composition, parameter rejection, and 420-frame timing with all four PF writes
checked on every visible line. A shifted-write mutation must fail. It samples
palette RGB independently and expands the visual bitmap itself, rather than
inheriting the old renderer's terminal-row PF schedule.

## Compact-state preparation witness

`all_five_objects.c26` now supplies a single shared vertical-state owner. Include
it once after `vcs.c26`, **instead of** separately declaring the intro's X
inputs. Set its public coordinates, heights and graphics pointers,
then call `layers_prepare_vertical()` once during blanking, before the intro.
It builds the BL/M1/M0 masks and initial player counters without changing any
public input or TIA register. It owns 74 RAM bytes; its preparation helper needs
six hardware-stack bytes at peak. This is shared state, not per-section storage.

Coordinates and inclusive height limits retain the certified renderer's
two-scanline convention. A player height of seven permits eight graphics rows;
row zero is the blank row. This preparer does not read or duplicate graphics or
player colour tables. The normal sprite-table page contracts still apply.

`test/vcs_layers_objects.pl` checks its masks against direct interval arithmetic,
including wrapping and empty extents, poisoned initial RAM, repeated preparation,
and unchanged input pointers/coordinates/heights. A wrong Ball bias must
fail. `test/vcs_layers_intro.pl` also adapts this state into the independent,
unchanged ancestor drawing schedule and checks complete exact images with
independent player-row colours, alternate pointers, short heights and NUSIZ
copies. **That test adapter is not a section implementation.**

Its eleven-cycle `layers_step_player0/1()` primitives preserve A/X and return
the shared row index in Y and the range test in C. The ancestor witness now
consumes those shared counters directly throughout drawing, rather than copying
them into old mask lanes. `all_five_section.c26` instead uses the compact event list;
the compact owner is retained as independently tested implementation evidence.
