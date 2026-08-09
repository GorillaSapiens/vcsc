```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Maintained gameplay-renderer component conversion baseline

This file freezes the starting point, selected replacement profiles, and
retirement gates for converting the maintained monolithic gameplay renderers
into reusable lifecycle components. The working monolithic profiles remain
installed until every required replacement has emulator and map evidence strong
enough to retire them.

## Profiles in scope

| Profile | Gameplay objects | Public display RAM | Private RAM | Total module RAM | Embedded score ROM |
| --- | --- | ---: | ---: | ---: | ---: |
| `standard_4k_ntsc` | P0, P1, M0, M1, BL | 23 bytes | 57 bytes | 80 bytes | 88 bytes |
| `standard_4k_ntsc_playercolors` | P0, P1, BL plus per-row P0/P1 colors | 17 bytes | 60 bytes | 77 bytes | 88 bytes |

The two profiles in this table are retained **legacy monolithic profiles**. They
remain installed because they provide useful compatibility, normalization, linker,
timing, and upstream-regression coverage. New programs should compose the explicit
lifecycle components below. Retirement of these working profiles is not a completion
gate for the component roadmap.

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

## Measured visible-component handoff

Every maintained visible component publishes the same machine-readable timing
fields in its `TEMPLATE_contract` enum:

| Field | Meaning |
| --- | --- |
| `TEMPLATE_DRAW_ENTRY_CYCLE` | Physical CPU cycle at which `draw()` begins on its first owned scanline. |
| `TEMPLATE_DRAW_RETURN_CYCLE` | Physical CPU cycle at which `draw()` returns on the line after its last owned scanline. |
| `TEMPLATE_DRAW_COMPLETE_SCANLINES` | Number of complete visible scanlines owned by `draw()`. |
| `TEMPLATE_DRAW_PARTIAL_ENTRY_CYCLES` / `TEMPLATE_DRAW_PARTIAL_EXIT_CYCLES` | Any partial scanline ownership outside those complete lines. Both are zero for every maintained component. |
| `TEMPLATE_DRAW_TERMINAL_WSYNC` | Whether `draw()` itself executes the WSYNC that closes its final line. |
| `TEMPLATE_DRAW_HMOVE_COUNT` | Number of HMOVE strobes executed inside `draw()`, excluding `vblank()`. |
| `TEMPLATE_DRAW_SUCCESSOR_ON_RETURN_LINE` | Whether another visible component may start on the return line after the three-cycle bridge. |

The values are measured against the 6502/TIA execution traces used by the
composition, poison-state, frame-timing, and pixel-oracle regressions. They are
not inferred from a count of source statements. The common contract is:

- `vcs_ntsc_end_vblank()` starts the first component at physical CPU cycle 3;
- every maintained `draw()` owns only complete scanlines and performs its own
  terminal WSYNC;
- every `draw()` returns at physical cycle 0 of the following line;
- `vcs_ntsc_component_handoff()` is the single three-cycle `BIT.z CXM0P`
  bridge, so a composable successor begins at cycle 3 of that same return line;
- the 192-line profiles set `SUCCESSOR_ON_RETURN_LINE` to zero because they
  already consume the complete standard visible field. Their cycle-zero return
  exists so the scheduler can assert VBLANK immediately, not so another visible
  component can be appended.

| Component family | Complete lines | Entry / return | Partial entry / exit | Terminal WSYNC | HMOVE in `draw()` | Successor on return line |
| --- | ---: | --- | --- | --- | ---: | --- |
| centered, mutable-color, left, and right six-glyph displays | 11 | 3 / 0 | 0 / 0 | yes | 1 | yes |
| widely spaced six-glyph display | 11 | 3 / 0 | 0 / 0 | yes | 1 | yes |
| left/right two-plus-two score | 11 | 3 / 0 | 0 / 0 | yes | 1 | yes |
| `poison_debug_score` | 11 | 3 / 0 | 0 / 0 | yes | 1 | yes |
| official/unofficial `player_color_181` | 181 | 3 / 0 | 0 / 0 | yes | 1 | yes |
| official/unofficial `all_five_181` | 181 | 3 / 0 | 0 / 0 | yes | 1 | yes |
| `player_color_192` | 192 | 3 / 0 | 0 / 0 | yes | 0 | no |
| `all_five_192` | 192 | 3 / 0 | 0 / 0 | yes | 0 | no |

### TIA ownership and exit state

The scheduler supplies VBLANK clear and the documented entry phase. No visible
component writes VSYNC, VBLANK, a RIOT timer, or audio registers. A/X/Y and
arithmetic flags are always clobbered; lifecycle calls leave hardware-stack
depth unchanged.

**Production six-glyph displays.** These establish and clobber `NUSIZ0/1`,
`COLUP0/1`, `REFP0/1`, `HMP0/1`, `RESP0/1`, `VDELP0/1`, and the P0/P1 graphics
latches; they strobe `HMCLR`, `HMOVE`, and `WSYNC`. They require no incoming
P0/P1 TIA state. On return, `GRP0=0`, `GRP1=0`, both delayed player latches have
been flushed by the final GRP0/GRP1/GRP0 sequence, and
`REFP0=REFP1=VDELP0=VDELP1=0`. Player position, size, color, and motion state
remains clobbered. `PF0/1/2`,
`CTRLPF`, `COLUPF`, `COLUBK`, M0/M1, Ball, collision latches, and audio state are
guaranteed untouched.

**Widely spaced six-glyph display.** This is a separate profile with glyph
origins at X=36,52,68,84,100,116. It uses three medium-spaced copies of each
player and the production delayed-player pipeline. Glyph one is staged before
each row boundary; glyphs two through six write at row cycles 0,8,36,39,42,
and cycle 45 commits the delayed latch. It owns 18 RIOT-RAM bytes per instance:
three score bytes, twelve pointer bytes, one row counter, one delayed glyph
byte, and one caller-visible mutable color byte. Its TIA ownership and exit guarantees match the production six-glyph
family, including flushed graphics latches and disabled VDEL on return.

**Left/right two-plus-two score.** This establishes and clobbers
`NUSIZ0/1`, `COLUP0/1`, `REFP0/1`, `HMP0/1`, `RESP0/1`, `VDELP0/1`, and the
P0/P1 graphics latches from instance-owned values, colors, and positions on
every draw. It accepts left origins 0..64 and right origins 32..144. Before its
single HMOVE it establishes `HMM0=HMM1=HMBL=0`, so preserved M0/M1/Ball geometry
cannot be moved by hostile incoming motion state. On return `GRP0=GRP1=0`, both
delayed player latches have been flushed by the final GRP0/GRP1/GRP0 sequence,
and `REFP0=REFP1=VDELP0=VDELP1=0`; player geometry, colors, and HMP values remain
clobbered. `PF0/1/2`, `CTRLPF`, `COLUPF`, `COLUBK`, missile/Ball enables and
widths, collision latches, audio, and scheduler state are untouched.

**Poison debug score.** This deliberately clobbers every score-owned P0/P1
surface: `NUSIZ0/1`, `COLUP0/1`, `REFP0/1`, `HMP0/1`, `RESP0/1`,
`VDELP0/1`, and the graphics latches. It also paints `COLUBK` while active,
then restores `TEMPLATE_exit_background`. Before its HMOVE it establishes
`HMM0=HMM1=HMBL=0`, so preserved M0/M1/Ball geometry is not moved. On return
`GRP0=GRP1=0`, delayed player latches are flushed, and `VDELP0=VDELP1=0`; the
hostile player size, reflection, position, color, and motion values intentionally
remain. Playfield, missile/Ball enables and widths, collision latches, and
scheduler state are untouched.

**181-line player-color gameplay.** `vblank()` must first prepare object masks,
Ball position, playfield state, and the constant-time P0/P1 handoff records.
`draw()` then establishes/clobbers `NUSIZ0/1`, `COLUP0/1`, `REFP0/1`,
`HMP0/1`, `RESP0/1`, `VDELP0/1`, `VDELBL`, `GRP0/1`, `ENABL`, and `PF0/1/2`; it strobes
`HMCLR`, `HMOVE`, `CXCLR`, and `WSYNC`. M0/M1 are not rendered and are cleared
on exit. The final complete cleanup line guarantees `PF0=PF1=PF2=0`,
`GRP0=GRP1=0`, `ENAM0=ENAM1=ENABL=0`, and
`VDELP0=VDELP1=VDELBL=0` and `REFP0=REFP1=0`; HM motion registers are
cleared by `HMCLR`. Player position, size, and final colors remain clobbered.
`CTRLPF`, `COLUPF`, `COLUBK`, audio, and scheduler state are untouched.

**181-line all-five gameplay.** The entry requirements and exit guarantees are
the same as the player-color family, but `vblank()` additionally prepares M0,
M1, and Ball positioning and `draw()` owns `ENAM0`, `ENAM1`, and `ENABL` while
visible. The final cleanup line guarantees all five object outputs and all three
playfield registers are zero. P0/P1 geometry, NUSIZ, solid colors, and motion
state are clobbered; application object coordinates remain ordinary RAM state
and are restored by `overscan()` where documented.

**192-line player-color gameplay.** `vblank()` owns all object positioning,
HMOVE, NUSIZ/VDEL setup, the first left-playfield half, and the staged first
P1/Ball state. `draw()` requires that prepared TIA/RAM state and writes
`PF1/2`, `GRP0/1`, `COLUP0/1`, `ENABL`, and `WSYNC`. It performs no HMOVE and
returns immediately after the terminal WSYNC with those display registers
clobbered rather than blanked. The scheduler must assert VBLANK immediately;
`overscan()` then guarantees `PF0/1/2`, `GRP0/1`, `ENAM0/1`, `ENABL`, and all
VDEL bits are zero and strobes `HMCLR`.

**192-line all-five gameplay.** Its prepared-entry and deferred-cleanup contract
matches the 192-line player-color profile. The visible draw additionally owns
`ENAM0` and `ENAM1`; P0/P1 colors and geometry were established by `vblank()`.
It returns with the final visible TIA state still active, so only the scheduler's
immediate VBLANK transition is legal. `overscan()` performs the same complete
playfield/object/VDEL cleanup and HMCLR strobe.

## Selected visible-profile matrix

The conversion no longer leaves the shorter composition profile open-ended.
Each maintained gameplay family has these explicit products:

| Profile | Gameplay lines | Score ownership | Opcode policy |
| --- | ---: | --- | --- |
| two-score composable | 170 | none; `main()` may compose independent 11-line scores above and below | official 6502/6507 only |
| score-composable | 181 | none; `main()` must compose one independent 11-line score component | official 6502/6507 only |
| full-height scoreless | 192 | none; no score fits beside it inside the standard visible field | official 6502/6507 only |
| score-composable unofficial twin | 181 | none; same application contract as the official 181-line component | reviewed stable/common NMOS unofficial forms allowed |

The ordinary score-bearing application contract is exact:

```text
181 gameplay scanlines + 11 score scanlines = 192 visible scanlines
```

The gameplay component therefore publishes `VISIBLE_SCANLINES := 181`; the
each maintained score component publishes eleven. `main()` must call both draw
operations and may place the score above or below gameplay. It must not add
another hidden blank-line allowance or silently crop either component. The
component implementation owns the complete internal accounting needed to enter
and leave on its documented scanline boundaries.

The official all-five implementation is one parameterized source.  Its required
`lines` instantiation parameter selects the 170-, 181-, or 192-line timing
profile at compile time.  Maps, fixtures, timing contracts, and diagnostics
must still identify which profile was linked; parameterization does not weaken
the profile-specific raster contracts.  The 170-line profile permits two
independent eleven-line scores because `11 + 170 + 11 = 192` visible lines.

The unofficial-opcode experiment is likewise a separate source/profile, not a
hidden alias. Its public API, public and private RAM layout, visible TIA-write
schedule, object positions, collision behavior, entry/exit cycles, and 181-line
contract must match the official score-composable component. Only then may the
linked executable-byte totals be compared. The report must state the official
and unofficial linked ROM byte counts and their signed difference; a zero or
negative saving is a valid result. Only reviewed stable/common NMOS 6502/6507
forms are eligible. Silicon-sensitive or unstable forms remain forbidden.

The current matched 181-line smoke fixtures measure:

```text
official linked ROM bytes:   1794
unofficial linked ROM bytes: 1794
signed byte difference:          0
```

The inherited monolith's gameplay field is twelve 16-line rows, or 192 lines.
Producing the new 181-line profile therefore requires an explicit retimed or
reduced gameplay schedule. The extraction regression must lock that internal
choice; neither this contract nor an application may disguise the missing
11 lines as scheduler padding.

## Parameterized official all-five gameplay

`renderers/all_five/all_five.c26` is the single official-opcode
P0/P1/M0/M1/BL lifecycle component. A required compile-time `lines`
instantiation parameter selects the maintained visible contract:

```vcsc
instantiate "renderers/all_five/all_five.c26" as game (lines:=192)
instantiate "renderers/all_five/all_five.c26" as game (lines:=181)
instantiate "renderers/all_five/all_five.c26" as game (lines:=170)
```

The parameter is available to `#if`/`#elif` inside directly instantiated source,
so the timed profile is selected at compile time. There is no run-time scanline
counter and no run-time renderer dispatch.

### 192-line all-five gameplay

The 192-line profile is the full-height scoreless form. It uses a page-contained
48-byte/twelve-row playfield and the proven `player_color_192`-derived visible
pipeline. All five objects are positioned during VBLANK. The exact RAM contract
is 23 public bytes plus 48 private schedule/scratch bytes, or 71 bytes total.

### 181-line all-five gameplay

The 181-line profile is score-composable. It uses a page-contained 44-byte,
eleven-row playfield and the score-safe P0/P1 visible-entry handoff. One
independent eleven-line score may appear above or below it:

```text
181 gameplay + 11 score = 192 visible lines
```

Its exact RAM contract is 23 public bytes plus 44 private schedule/scratch
bytes, or 67 bytes total. Adjacent visible components use
`vcs_ntsc_component_handoff()`.

### 170-line all-five gameplay

The 170-line profile uses the same score-composable timing family with a
page-contained 40-byte/ten-row playfield. Ten 16-line playfield rows plus the
five-line score-entry region and five terminal blank lines make the component
return after exactly 170 scanlines. It is intended for:

```text
11 score above + 170 gameplay + 11 score below = 192 visible lines
```

The 170 profile retains the 181 profile's 44-byte private schedule/scratch span,
so its total component RAM is also 67 bytes. The extra private bytes are timing
workspace, not playfield storage.

All three official profiles retain independent solid P0/P1 colors, use only
official NMOS 6502/6507 opcodes, keep the missile/Ball updates inside their
proven beam deadlines, and own no score/font or frame-scheduler state.
Maintained regression evidence locks exact 262-line frames, every playfield
pixel, all five object rasters, RAM/page/stack contracts, and staged-installed
builds for the supported line counts.

## Parameterized unofficial all-five counterpart

`renderers/all_five_unofficial/all_five_unofficial.c26` is the separately named
stable/common-NMOS experimental twin of the parameterized official all-five
renderer. It requires the same `lines` instantiation parameter and supports
`lines:=192`, `lines:=181`, and `lines:=170` with the same API, RAM layout,
playfield contract, visible scanline count, and TIA schedule as the corresponding
official profile. It must be assembled with `-Wa,--illegals`.

Each selected profile contains exactly one reviewed stable/common NMOS form: a
zero-page unofficial NOP (`$04`) used as exact-size, exact-cycle dead-flag
padding during VBLANK positioning. There are no retained AXS substitutions and
no silicon-sensitive or unstable opcodes.

The maintained 181-line score matrix continues to compare static and moving
unofficial cartridges against the official `lines:=181` profile. Additional
profile regressions instantiate 192, 181, and 170 directly, require equal linked
ROM use and profile RAM contracts, and compare visible TIA traces and stable
262-line frames. The public `examples/12_all_five_170_unofficial/` cartridge
composes 11 score + 170 gameplay + 11 score to prove the dual-score profile.

## RAM-optimization architecture closeout

Final RAM measurement does **not** justify separate P0/P1-only 192- or 181-line
component families. The general official `player_color_192` profile retains P0,
P1, and Ball in 23 component RAM bytes; the animated gallery uses 56/128 RIOT RAM
bytes and leaves 72 bytes free. The official `player_color_181` profile retains the
same three gameplay objects in 24 component RAM bytes, and its ordinary centered
score composition leaves 63 RAM bytes free. Even the maintained wide-score
composition fits with ten bytes free.

The retained architecture is therefore the existing general P0/P1/Ball pair plus
the all-five families and their explicitly named unofficial twins. A future
two-sprite-only renderer should be added only for a concrete program whose measured
requirements justify another public timing/API profile, not as a generic RAM
optimization.

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
38/45. The official and unofficial 181-line twins remain byte- and raster-matched.
The rebuilt unofficial twin retains one reviewed `$04` NOP as exact-cycle
padding outside the visible raster.

The row-boundary repair now also stages the Ball enable value before every
extra transition `GRP1`, preventing the delayed Ball latch from duplicating one
pair and dropping the next at an internal 16-line boundary. Dedicated edge
oracles pin this for the 192- and 181-line all-five families.

The 181-line all-five and player-color profiles also preserve the final row
through a WSYNC boundary before clearing visible TIA state. The player-color
path needs a compact 30-cycle phase pad on the blank cleanup line to retain its
exact 181-line return boundary; both official and unofficial smoke links now
measure 1422 bytes and still differ by zero bytes after direct-countdown and
delayed-Ball correction.

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
bytes of public gameplay state plus 11 private bytes, 24 total. The former
43-byte object-mask schedule is gone; private state is the two retained NUSIZ
shadow slots, eight phase-overlay-eligible countdown/work bytes, and one
playfield-position byte. No score/font,
VSYNC, VBLANK, or RIOT timer state is linked. The maintained static fixture
holds stable 262-line scheduler frames and proves all eight P0 and P1 rows use
the exact requested colors while Ball remains active and both missiles remain
disabled.

Static and asynchronous-motion composition fixtures now cover both explicit
orders: score above gameplay and score below gameplay. The emulator evidence
locks 181+11=192 visible lines, stable 262-line frames, disjoint score/gameplay
activity, exact P0/P1 color rows, disabled missiles, and full X=0..159 traversal
for P0, P1, and Ball over 320 frames. The centered interactive score-above example now links at 65/128 total RIOT RAM
bytes; a gameplay-only map contains no score state or font.


## Matched unofficial player-color 181-line experiment

`renderers/player_color_181_unofficial/player_color_181_unofficial.c26` is the
separately named stable/common-NMOS twin of the official score-composable
player-color component. It keeps the same lifecycle API, exact 13/11/24-byte public/private/total RAM contract, per-row P0/P1 colors, Ball behavior, 181-line visible schedule, both
score orders, and static/motion fixtures. It must be assembled with
`-Wa,--illegals`.

The direct-countdown conversion removed the row-mask helper that contained the
reviewed unofficial substitutions. The current generated unofficial profile
contains no unofficial mnemonic and measures 1422 linked ROM bytes, exactly the
same as the official twin. Five pairwise raster/timing comparisons plus the
320-frame composition oracle enforce equivalence, including the corrected Ball
transfer across an internal row boundary.

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
removed. The later RAM optimization also removed the 48-byte object-mask
schedule in favor of direct P0/P1/Ball vertical countdowns. Its measured RAM contract is 13 public plus 10 private bytes, 23 total,
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

