```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Maintained gameplay-renderer component conversion baseline

This file freezes the starting point and retirement gates for roadmap task 22i.
It also records completed lifecycle profiles as they satisfy those gates. The
working monolithic profiles remain installed until every required replacement
has emulator and map evidence strong enough to retire them.

## Profiles in scope

| Profile | Gameplay objects | Public display RAM | Private RAM | Total module RAM | Embedded score ROM |
| --- | --- | ---: | ---: | ---: | ---: |
| `standard_4k_ntsc` | P0, P1, M0, M1, BL | 23 bytes | 57 bytes | 80 bytes | 88 bytes |
| `standard_4k_ntsc_playercolors` | P0, P1, BL plus per-row P0/P1 colors | 17 bytes | 60 bytes | 77 bytes | 88 bytes |

Both current objects reserve a `$0300` `RENDERER_CODE` window and a `$0058`
page-contained `RENDERER_RODATA` score table.  Those are baseline costs, not
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
visible `draw()` uses `WSYNC` internally because the renderer is inherently
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

## Completed official all-five 181-line profile

`renderers/all_five_181/all_five_181.c26` is the official-opcode, score-composable
P0/P1/M0/M1/BL lifecycle component. It publishes an exact 181-line visible
contract and requires a page-contained 44-byte, eleven-row playfield supplied by
the application. Its measured implementation retains eleven 16-line gameplay
rows and accounts for the remaining setup and cleanup scanlines inside the
component; the application does not provide hidden padding.

The extracted component owns no score, font, score pointers, VSYNC, VBLANK, or
RIOT timer state. Its exact map contract is:

| Resource | Bytes |
| --- | ---: |
| public gameplay state | 19 |
| private workspace and masks | 50 |
| total component RAM | 69 |
| application playfield ROM | 44 |

The six former score-pointer workspace bytes are gone, and removing the unused
final-row scratch entry reduces the object-mask array from 44 to 43 bytes. The
remaining six-byte workspace is gameplay-only. The standard linker profile's
four-byte hidden call-stack allowance covers the inline VBLANK preparation
subroutine.

Emulator regressions lock a stable 262-line scheduler frame when the application
reserves the independent score's eleven visible lines, strict intended-pixel
playfield checks across all eleven 16-line rows, alternating left-half writes at
8/28 and 24/31 with right-half writes at 38/45, and visible object counts P0=7, P1=7, M0=6, M1=8, BL=4. Source inspection rejects score/font
imports, frame/timer ownership, and unofficial opcodes, while map inspection
locks RAM, page placement, and stack depth. All four lifecycle requirements have
component-specific omission diagnostics.

Static and asynchronous-motion fixtures now compose this component with the
independent six-glyph score in both visible orders. Emulator evidence locks the
exact line split (40..220 gameplay and 221..231 score, or 40..50 score and
51..231 gameplay), stable 262-line frames, complete score/all-five activity,
360-frame full-range X motion, and restored application Y state. Map evidence
measures 69 gameplay bytes plus 17 independent score bytes and separately proves
that a gameplay-only link contains no score state or font.

That motion evidence exposed and fixed an extraction error: M0 had only an
88-line VBLANK bias in the shortened profile because the predecessor's final-row
DEC was removed. Reconstruction now adds 88 rather than 89, restoring the exact
application M0 Y coordinate at the lifecycle boundary.

## Completed unofficial all-five 181-line matched profile

`renderers/all_five_181_unofficial/all_five_181_unofficial.c26` is the
separately named experimental twin of the official 181-line component. It has
the same lifecycle API, 19-byte public state, 50-byte private state, 69-byte
total RAM layout, 44-byte playfield contract, and score-above/score-below
application fixtures. It must be assembled with `-Wa,--illegals`.

Only reviewed stable/common NMOS forms are present. Four `AXS #252` sites
replace row-index `TXA`/`ADC`/`TAX` idioms, with one-byte NOP padding retaining
the official sequences' exact byte and cycle counts. Three zero-page unofficial
NOPs (`$04`) replace dead-flag `BIT $00` padding after the PF1 staging repair; both forms are two bytes and
three cycles. No silicon-sensitive or unstable opcode is used.

The maintained smoke links measure:

```text
official linked ROM bytes:   1421
unofficial linked ROM bytes: 1421
signed saving:                  0
```

This zero-byte result is intentional evidence, not a failed optimization.
Removing the compensating NOPs would shrink code only by changing lifecycle or
visible-renderer cycle boundaries. Pairwise emulator comparison locks every
visible TIA write and 42 stable 262-line frames for the smoke, both static score
orders, and both moving score orders. The existing 360-frame motion oracle also
locks full-range asynchronous object movement and Y-coordinate preservation for
both unofficial score orders. Map evidence requires every RAM symbol to retain
the official address.

## Completed official all-five 192-line scoreless profile

`renderers/all_five_192/all_five_192.c26` is the distinct official-opcode,
full-height P0/P1/M0/M1/BL lifecycle component. It owns the complete 192-line
visible gameplay field, takes a page-contained 48-byte/twelve-row playfield,
and cannot be combined with the eleven-line score inside the standard visible
region. The predecessor's twelfth-row path is retained, and the final gameplay
state is held through the lines that the 181-line profile assigns to the score.

Its exact map contract is 19 public bytes plus 51 private bytes: six gameplay
workspace bytes, one playfield-position byte, and the complete 44-byte object
mask array, for 70 bytes total. It links no score state, score pointers, or font.
`draw()` clears visible TIA state at its final boundary; `overscan()` restores
application-visible Y coordinates after the application asserts VBLANK.

Regression evidence locks stable 262-line frames, 48-byte hard-page playfield
placement, official mnemonics only, the inherited cycle-24/31/38/45 playfield
phases, visible all-five output, exact lifecycle diagnostics, and source plus
staged-installed builds. The matched unofficial 181-line profile is complete with a measured zero-byte saving.

The predecessor monolith remains installed until the player-color family and
final retirement gates are complete.

## Stop-ship row-boundary raster repair

The inherited two-line renderer cleared PF1 and PF2 at cycles 18 and 21 of every
row-transition scanline. That made each nominal 16-line playfield row render as
15 intended lines plus one blank or malformed line. The six current gameplay
components now replace those writes with non-TIA work so the old row survives
its complete sixteenth line.

Real Stella screenshots then exposed a second all-five defect: on the following
row-entry line PF1/PF2 were still established too late for a clean edge. The
all-five profiles now stage the next row's left PF1 byte in dead workspace and
write the left PF1/PF2 pair at cycles 21/28 while retaining the right pair at
38/45. The official and unofficial 181-line twins remain byte- and raster-
matched; the staged path leaves three, rather than four, `$04` NOP sites in the
unofficial twin.

The 181-line all-five and player-color profiles also preserve the final row
through a WSYNC boundary before clearing visible TIA state. The player-color
path needs a compact 30-cycle phase pad on the blank cleanup line to retain its
exact 181-line return boundary; both official and unofficial smoke links now
measure 1429 bytes and still differ by zero bytes.

The maintained source-level oracle checks every gameplay row, sixteen lines per
row, and all 160 playfield pixels per line. The 192-line player-color profile
now uses the same two-line raster path for all twelve rows; its former first-row
entry notch and two special twelfth-row paths are gone. The trace oracle also
reconstructs its P0, P1, and Ball output and verifies that all coarse/fine
positioning occurs during VBLANK. Complete P0/P1/M0/M1/Ball reconstruction for
the other profiles remains open. No monolith may be retired until those cases
and the measured component handoff contract pass.

## Evidence required before retiring a monolith

For each profile, the replacement must provide all of the following:

1. A gameplay-only lifecycle implementation, whether inline template assembly
   or a separate assembly object, with no embedded score state, font, pointer
   setup, drawing code, or update path.
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

## Official player-color 181-line extraction

`renderers/player_color_181/player_color_181.c26` is the first extracted member
of the P0/P1/Ball per-row-color family. It consumes exactly 181 visible lines
and expects `main()` to compose the independent eleven-line score above or
below it. It retains the predecessor's exact five-strobe horizontal-position
schedule, with two private ghost-missile coordinates forced to zero, while M0
and M1 remain unavailable.

The application supplies an eleven-row/44-byte page-contained playfield plus
page-contained eight-byte P0 and P1 color tables. Graphics and colors use the
same highest-index-to-zero row order. The measured component contract is 13
bytes of public gameplay state plus 52 private bytes, 65 total. No score/font,
VSYNC, VBLANK, or RIOT timer state is linked. The maintained static fixture
holds stable 262-line scheduler frames and proves all eight P0 and P1 rows use
the exact requested colors while Ball remains active and both missiles remain
disabled.

Static and asynchronous-motion composition fixtures now cover both explicit
orders: score above gameplay and score below gameplay. The emulator evidence
locks 181+11=192 visible lines, stable 262-line frames, disjoint score/gameplay
activity, exact P0/P1 color rows, disabled missiles, and full X=0..159 traversal
for P0, P1, and Ball over 320 frames. Composed maps retain separate 65-byte
gameplay and 17-byte score allocations; a gameplay-only map contains no score
state or font.


## Matched unofficial player-color 181-line experiment

`renderers/player_color_181_unofficial/player_color_181_unofficial.c26` is the
separately named stable/common-NMOS twin of the official score-composable
player-color component. It keeps the same lifecycle API, exact 13/52/65-byte
RAM map, per-row P0/P1 colors, Ball behavior, 181-line visible schedule, both
score orders, and static/motion fixtures. It must be assembled with
`-Wa,--illegals`.

Only two `AXS #252` row-mask advance sites and one zero-page unofficial NOP
site survived equivalence testing. The other two tempting `AXS` substitutions
were rejected because they changed live flag behavior and prevented complete
frames. Compensating official NOPs retain every accepted site's cycle boundary.
After the terminal-row cleanup repair, the maintained smoke cartridges measure
1605 linked ROM bytes for both official and unofficial components: **0 bytes
saved**. Five pairwise raster/timing
comparisons plus the existing 320-frame composition oracle enforce that result.

## Official player-color 192-line scoreless profile

`renderers/player_color_192/player_color_192.c26` is the distinct full-height
P0/P1/Ball per-row-color component. It consumes exactly 192 visible lines and
cannot be combined with the independent eleven-line score inside the standard
visible field. The application supplies a twelve-row/48-byte playfield plus the
same page-contained graphics and eight-byte color tables as the 181-line
profile.

The full-height component has one uniform two-line raster loop for all twelve
rows. P0, P1, and Ball are positioned entirely during VBLANK; staged row-zero
state enters the visible field at the same half-row phase used by every later
row. The obsolete terminal pipeline and its 160-byte position table were
removed. Its measured RAM contract is 13 public plus 57 private bytes, 70 total,
and its only position helper is a page-contained 16-byte divide-by-15 table.
Missiles remain unavailable; score/font and scheduler-owned frame/timer state
remain absent. The maintained trace regression locks exact 262-line frames,
all twelve 16-line rows, all 160 playfield pixels per line, P0/P1/Ball output,
VBLANK-only positioning, official opcodes, hard-page ROM objects, map sizes,
and all four lifecycle contracts. Screenshot PNGs are not correctness oracles.

## Poison debug score composition probe

`poison_debug_score/poison_debug_score.c26` is the maintained adversarial
11-line score-profile substitute used by the 22i4b correctness gate. It owns
one caller-selected exit-background byte and deliberately exits with hostile
P0/P1 graphics, color, reflection, vertical-delay, copy/size, fine-motion,
coarse-position, and HMOVE state. It preserves playfield, missile, and Ball
geometry, matching the ownership boundary of the production P0/P1 score. Its
values are deterministic so a failure reproduces.

This probe does not relax the component contract. It owns exactly eleven WSYNC
boundaries and no frame, timer, or collision-clear hardware. A big gameplay
component placed after it must re-establish every P0/P1 register and position
required by its own raster. A score component placed after gameplay must do the
same. Adjacent visible components use `vcs_ntsc_component_handoff()` to convert
the preceding component's cycle-zero return into the canonical cycle-3 entry.
The maintained player-color fixtures prove both orders over all X coordinates,
including horizontal clipping and terminal gameplay lines.

