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
- `color_ntsc.c26`, `color_pal.c26`, `color_secam.c26` ... readable standard-specific aliases backed by the compile-time RGB palette matchers
- `frame_ntsc.c26` ... shared NTSC phase constants, scanline waiting, VSYNC, and scheduler-owned VBLANK/overscan deadlines
- `frame_pal.c26`, `frame_secam.c26` ... distinct PAL50/SECAM50 public front ends over the shared measured 312-line `frame_50hz_component.c26` scheduler core
- `playfield.c26` ... compile-time `VCS_PLAYFIELD_ROW()` conversion from left-to-right 32-bit visual rows to the four asymmetric TIA playfield bytes
- `sound_ntsc.c26` ... NTSC TIA audio-control, note-frequency, volume, and frame-timing aliases
- `sound_pal.c26`, `sound_secam.c26` ... 50 Hz TIA control/note aliases plus PAL/SECAM frame-duration constants through `sound_50hz.c26`
- `VIDEO_STANDARDS.md` ... PAL/SECAM/NTSC component-portability classification and measured 228-line composition guidance
- `six_glyph_wide_component.c26` ... separate mutable-color six-glyph profile with origins at X=36,52,68,84,100,116; its compact default uses one biased byte offset plus five full pointers and no row byte, while `compact_font:=0` restores six redirectable full pointers for callers that need arbitrary glyph-page redirection
- `six_glyph_big_wide_component.c26` ... matching wide geometry for the 16-row Big decimal/hex fonts; it draws six 8x16 glyphs in a 19-scanline visible component
- `six_glyph_left_component.c26` ... eleven-line mutable-color variant justified at X=0..47; compact default stores digit 6 as a byte offset plus five full pointers (set `compact_font:=0` only for full-pointer font redirection)
- `six_glyph_right_component.c26` ... eleven-line mutable-color variant justified at X=112..159; compact default uses two byte offsets plus four full pointers (set `compact_font:=0` only for full-pointer font redirection)
- `six_glyph_component.c26` ... canonical centered 48-pixel/six-glyph lifecycle display; compact default stores digits 1/2 as byte offsets plus four full pointers with fixed bright-white color, `mutable_color:=1` adds an application-visible color byte, and `compact_font:=0` restores six redirectable full pointers for arbitrary glyph pages
- `three_plus_three_score_component.c26` ... fixed eleven-line dual score with independent three-digit packed-BCD values and colors, centered as X=20,36,52 in the left half and X=100,116,132 in the right half
- `two_paddles.c26` ... two analog CX30-style paddles plus both fire buttons on either controller port, with explicit VBLANK dump/charge ownership and multi-frame raw timing
- `keypad_controller.c26` ... one 12-key Atari-style keypad on either controller port, with explicit row selection, caller-owned settle timing, stable 12-bit state, and press/release edge masks
- `two_plus_two_score_support.c26` ... shared page-contained compact decimal glyph and calibrated horizontal-position tables for two-plus-two scores
- `two_plus_two_score_component.c26` ... repeatable eleven-line P0/P1 score with independent packed-BCD left/right values, colors, and X positions; each three-bit digit is doubled to six visible pixels with a two-pixel inter-digit gap
- `renderers/AUTHORING.md` ... maintained HOWTO for renderer/score component contracts, phase/TIA ownership, stack and memory budgets, cycle scheduling, Stella oracles, regressions, examples, and installation
- `renderers/COMPONENT_CONVERSION.md` ... measured predecessor baseline, machine-readable visible-component handoff/TIA ownership table, and the explicit 181-line score-composable, 192-line scoreless, and matched unofficial profile contracts
- `renderers/faithful_legacy_multisprite/` ... faithful unbanked/non-Superchip multisprite source-integration baseline: P0 plus five logical P1 sprites, integrated score/playfield, exact 122-byte legacy state, six-byte hardware stack, 264-line timing, and retained unofficial-opcode behavior
- `renderers/multisprite/` ... modern parameterized P0-plus-five-multiplexed-P1 lifecycle component; `lines:=192` is full-height and `lines:=181` composes with an independent eleven-line score, with full X=0..159, bounded independent Y motion, faithful frame-persistent overlap flicker arbitration, a page-aligned graphics block, and branch-page contracts that keep the retained raster cycle-stable
- `renderers/all_five/` ... parameterized official-opcode P0/P1/M0/M1/BL lifecycle component; `lines:=192` is full-height, `lines:=181` composes with one eleven-line score, and `lines:=170` composes between scores above and below
- `renderers/all_five_player_color_181/` ... separate official-opcode score-composable P0/P1/M0/M1/BL component with immutable eight-entry P0/P1 color tables; 181 gameplay lines plus one independent 11-line score, 88-byte component RAM contract
- `renderers/all_five_player_color_192/` ... separate official-opcode full-height P0/P1/M0/M1/BL component with immutable eight-entry P0/P1 color tables; 83-byte component RAM contract
- `renderers/all_five_unofficial/` ... parameterized stable/common-NMOS experimental twin of `all_five`, supporting `lines:=192`, `181`, and `170` with the same API, RAM contracts, and corrected raster schedules
- `renderers/player_color/` ... parameterized official-opcode P0/P1/BL per-row-color component; `lines:=192` is full-height, `lines:=181` composes with one eleven-line score, and `lines:=170` composes between scores above and below
- `renderers/player_color_181_unofficial/` ... matched stable/common-NMOS experimental twin of the 181-line player-color component; currently raster-identical and size-identical after direct-countdown conversion
- `renderers/poison_debug_score/` ... one-byte adversarial eleven-line score-profile component that trashes deterministic P0/P1 state while preserving playfield, missile, and Ball geometry
- `renderers/standard_4k_ntsc/` ... legacy monolithic all-five-object solid-color component whose generated assembly object carries its own placement, page, and hidden-stack contracts; certified with generic 4K/F8/F6/F4/F8SC C26 profiles through a VBLANK-only banked overscan hook
- `renderers/standard_4k_ntsc_playercolors/` ... legacy monolithic P0+P1+BL player-color profile retained for compatibility and regression
- `fonts/` ... eight shared 8x8 score-font families, the Big 8x16 decimal/hex/ASCII family, plus the six-slice `logo_font.c26` VCSC mark
- `../../examples/README.md` ... renderer-grouped public example index
- `../../examples/01_basic/` ... standalone cartridges and reusable-component examples
- `../../examples/02_faithful_legacy_playercolors/` ... faithful legacy interactive compatibility diagnostic
- `../../examples/03_player_color_192/` ... full-height scoreless interactive player-color diagnostic
- `../../examples/04_player_color_181/` ... official-opcode twelve-cartridge centered/left/right/two-plus-two/poison/wide matrix for 181-line player-color gameplay
- `../../examples/05_all_five_192/` ... official-opcode full-height interactive diagnostic using `all_five (lines:=192)`
- `../../examples/06_all_five_181/` ... official-opcode ten-cartridge centered/left/right/two-plus-two/poison matrix using `all_five (lines:=181)`
- `../../examples/07_player_color_181_unofficial/` ... matched unofficial-opcode ten-cartridge player-color matrix, built explicitly with `-Wa,--illegals`
- `../../examples/08_all_five_181_unofficial/` ... matched unofficial-opcode ten-cartridge all-five matrix, built explicitly with `-Wa,--illegals`
- `../../examples/09_bankswitching/` ... parameterized F8/F6/F4 transition diagnostic with visible PASS/FAIL frames
- `../../examples/10_faithful_legacy_multisprite/` ... fixed faithful P0-plus-five-P1 multisprite reference cartridge used to anchor roadmap item 28
- `../../examples/14_multisprite/` ... modern parameterized multisprite examples: full-height 192-line interaction plus 181-line interactive score-above and score-below compositions, all with horizontal/vertical P0/P1..P5 movement
- `../../examples/15_all_five_player_color_192/` ... full-height interactive combined all-five/per-row-player-color diagnostic
- `../../examples/16_all_five_player_color_181/` ... fixed centered score-above and score-below compositions for the 181-line combined all-five/per-row-player-color profile
- `../../examples/11_all_five_170/` ... `all_five (lines:=170)` interactive composition with an eleven-line score above and another below
- `../../examples/12_all_five_170_unofficial/` ... matching `all_five_unofficial (lines:=170)` dual-score composition, built explicitly with `-Wa,--illegals`
- `../../examples/13_player_color_170/` ... `player_color (lines:=170)` interactive composition with an eleven-line score above and another below
- `../../examples/17_video_standards/` ... minimal PAL50/SECAM50 frames and measured interactive 192-line all-five compositions using standard-specific palettes

## Bank-switching diagnostic suite

`bankswitching_diagnostic_suite.c26` is compiled with `MAPPER_BANKS` and,
for the Superchip twins, `SUPERCHIP_TEST`. One cartridge internally executes the
complete ordered source-bank to destination-bank direct-JMP matrix for its
mapper. Every source bank also verifies a same-bank JSR/RTS path; BANK0 adds a
nested BANK0-to-BANK1 call and return. RIOT-RAM signatures, matrix counts, and
hardware-stack balance are checked before the cartridge settles on a two-line
result display. Green success shows lowercase **pass** with the 16-row Big font;
dark-red failure shows uppercase **FAIL**. A centered second line identifies
`F8`, `F6`, `F4`, `F8SC`, `F6SC`, or `F4SC`; the deliberately poisoned image
shows `??????`. The result line uses `six_glyph_big_wide_component.c26` with
exact glyphs from `fonts/big_ascii.c26`, and the cart-type line uses
`six_glyph_component.c26` with exact glyphs from `fonts/default_ascii.c26`.
The 19-line and 11-line components form one centered 30-line block, and the
complete frame remains exactly 262 scanlines.

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

## Video-standard color matching

VCSC keeps NTSC, PAL, and SECAM color semantics explicit.

`__builtin_ntsc_rgb(r,g,b)` and `__builtin_pal_rgb(r,g,b)` fold compile-time RGB
triplets to the nearest of the 128 meaningful even TIA bytes in the project's
Stella-compatible reference palettes. Matching uses squared RGB distance and
exact ties choose the lower TIA byte. `color_ntsc.c26` and `color_pal.c26` provide
selected readable aliases built from those matchers. PAL color-loss is a
display-line effect represented by Stella's odd palette entries; it is not a
second set of source colors and is deliberately not baked into the matcher.

SECAM is not treated as PAL-with-different-names. Stella exposes eight distinct
SECAM colors, repeated across the TIA high nibble. `color_secam.c26` defines the
canonical low even bytes `$00,$02,...,$0e`, and `__builtin_secam_rgb(r,g,b)` maps
an arbitrary compile-time RGB source color to those same eight choices. A source
asset that depends on more than those eight colors therefore requires explicit
SECAM recoloring rather than assuming PAL/NTSC TIA bytes are portable.

All three RGB builtins emit no cartridge-resident palette or runtime search.
Reference RGB values are emulator/display approximations rather than guarantees
for real televisions or capture hardware.

## NTSC frame scheduler
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
for the unused part of the phase and detect RIOT timer underflow without mistaking
a wrapped `INTIM` value for remaining time. `vcs_ntsc_end_vblank()` issues its
boundary `WSYNC` and clears VBLANK. `vcs_ntsc_end_overscan()` leaves VBLANK
asserted for VSYNC and issues three blanked `WSYNC` boundaries: the normal deadline
boundary plus two frame-closeout boundaries required by Stella/TIA accounting for
a stable 262-scanline, 60.0 Hz NTSC frame. A missed deadline cannot be repaired
generically, so the production path continues at the next scanline boundary and
produces one long frame rather than waiting on wrapped timer state. Component callbacks must
not touch VBLANK, INTIM, TIMINT, or a timer-start register, and must not
perform the final phase transition. They may use WSYNC for bounded internal
blanking work; those stalled cycles consume the already-running shared deadline.

Define `alias VCS_NTSC_DIAGNOSTICS 1` before including `frame_ntsc.c26` to add a
sticky `vcs_ntsc_overrun_flags` byte. Bits `VCS_NTSC_VBLANK_OVERRUN` and
`VCS_NTSC_OVERSCAN_OVERRUN` identify missed deadlines. Production builds omit
that RAM byte and all flag-setting code.


## PAL and SECAM 50 Hz frame schedulers

`frame_pal.c26` and `frame_secam.c26` are distinct public front ends over a shared
internal `frame_50hz_component.c26`. Both expose the measured 312-line scheduler
contract used by this project: 3 VSYNC + 45 VBLANK + 228 visible + 36 overscan
scanlines, with 76 CPU cycles per scanline. Their public names remain separate
(`vcs_pal_*` / `VCS_PAL_*` and `vcs_secam_*` / `VCS_SECAM_*`) so later palette,
audio, and renderer contracts cannot accidentally collapse the two standards.

The calibrated RIOT deadlines are `TIM64T=52` for VBLANK and `TIM64T=41` for
overscan. As with the NTSC scheduler, the CPU timing harness counts two TIA
frame-closeout boundaries beyond Stella's displayed frame total: a stable 312-line
PAL/SECAM frame is therefore 314 raw harness intervals. The visible-component
entry/handoff and diagnostic-overrun contracts mirror the NTSC API with the
standard-specific prefix. Define `VCS_PAL_DIAGNOSTICS` or
`VCS_SECAM_DIAGNOSTICS` before including the corresponding front end to retain
sticky deadline-overrun state.

Stella certification is intentionally an optional independent test because Stella
is not required for a normal VCSC build. `make stella-50hz-test STELLA=/path/to/stella`
forces PAL and SECAM display formats and verifies their stable 50 Hz viewport.

`VIDEO_STANDARDS.md` classifies the maintained renderers/components. Scheduler-neutral
C26 visible components are timing-portable when their published line and entry/return
contracts fit the 228-line visible budget; the retained monolithic legacy/standard
NTSC renderers remain NTSC-only. The public 192-line all-five examples demonstrate
the measured wrapper: 17 pre-component helper lines and an 18-line visible tail.

## PAL and SECAM sound/cadence constants

`sound_pal.c26` and `sound_secam.c26` select the shared `sound_50hz.c26` constants.
TIA control, volume, and the small AUDC=12 lead-note divider set retain the same
register values used by `sound_ntsc.c26`; the physical pitch follows each console's
clock. Frame-duration aliases are adjusted for 50 Hz: gap=2 frames, eighth=12 frames
(rounded to 0.24 s), quarter=25 frames (0.5 s), and half=50 frames (1.0 s). Applications
that need exact musical timing beyond whole-frame resolution should schedule it at a
finer cadence instead of assuming NTSC frame counts.

## Two paddles on one controller port

`two_paddles.c26` is a parameterized input component for the two analog paddles
and two fire buttons connected through one VCS controller port. Port 0 is the
default; use `instantiate "two_paddles.c26" as paddles (port:=1)` for the right
port. The public state is `position0`, `position1`, `button0`, `button1`, and
`valid`. Button values are normalized to 1 while pressed. Position values are
raw charge-time measurements; applications should clamp or calibrate them for
the useful travel of their own controllers.

The TIA paddle inputs are RC timers rather than ordinary digital inputs. The
component therefore owns a measurement lifecycle instead of pretending an
`INPTx` read is an instantaneous position. `init()` begins with the paddle
capacitors dumped. A scheduler write that clears VBLANK.7 releases them;
`vblank()` takes eight two-scanline samples, visible code may call `sample0()`
and `sample1()` once per two-line slot followed by `advance_pair()`, and
`overscan()` takes two more blanked two-line samples and reads both buttons.
`account_gap(pairs)` advances over raster spans owned by another component.
Measurements may carry across frames and saturate at raw 255 instead of being
silently clipped at one frame.

`dump()` is deliberately separate from the scheduler callbacks. With
`frame_ntsc.c26`, call it immediately after `vcs_ntsc_end_overscan()`, while
VBLANK.1 is already asserted. It writes VBLANK.7 only for a completed
measurement and keeps its two paths cycle-balanced so the following VSYNC phase
does not move. The next `vcs_ntsc_begin_vblank()` writes 0x02, releasing a
completed dump and starting a fresh charge interval. The component's `vblank()`
and `overscan()` callbacks do not write VBLANK or touch the RIOT timer, so they
remain inside the scheduler ownership contract.

## Four paddles across both controller ports

`four_paddles.c26` extends the same RC-measurement model to all four Atari
CX30-style paddles at once. Its public surface deliberately contains the entire
two-paddle state/lifecycle vocabulary (`position0/1`, `button0/1`, `valid`,
`init()`, `sample0/1()`, `advance_pair()`, `account_gap()`, `vblank()`,
`overscan()`, and `dump()`) and adds `position2/3`, `button2/3`, and
`sample2/3()`. Positions remain raw two-scanline elapsed values and may span
frames; applications should apply their own endpoint calibration.

All four RC capacitors are released together, but a beam-critical renderer
should not test all four threshold-completion paths on one scanline. The public
four-player example samples one channel per scanline: 0/1 on one two-line pair
and 2/3 on the next. The shared elapsed counter advances after every pair, so
all four positions retain the same units as `two_paddles.c26`. Seven four-line
VBLANK sample cycles consume 28 lines and leave enough of the scheduler's
37-line deadline for component bookkeeping; `account_gap()` preserves elapsed
time across the unsampled remainder, score, and display setup. The emulator
oracle exercises distinct, simultaneous, and staggered four-channel thresholds
plus every fire button while requiring invariant frame length.

The public four-player cartridge at
`examples/01_basic/10_four_player_paddleball/` assigns the left-port blue team
to P0/M0 and the right-port red team to P1/M1, with the TIA Ball shared between
them. P0/P1 are time-multiplexed: the score owns them at the top of the frame,
then the three blank lines below the score reposition them as outer gameplay
paddles. Paddle rebounds use the P0-Ball/M0-Ball/P1-Ball/M1-Ball TIA collision
latches, any teammate may serve, and scoring remains blue-versus-red.

The public Paddleball example in `examples/01_basic/09_paddleball/` demonstrates a complete
composition. Its 11-line `three_plus_three_score_component.c26` owns P0/P1;
M0/M1 are the blue/red paddles and Ball is white. The 181 gameplay lines include
four-scanline white top and bottom walls and a reflected dashed center line on a
black background. Paddle rebounds use the TIA M0-Ball/M1-Ball collision latches
rather than software overlap geometry. The emulator regression drives independent
short and multi-frame RC thresholds, hardware paddle collisions, paddle fire,
serving, scoring, console Reset, and stable NTSC frame length.

## Twelve-key keypad controller

`keypad_controller.c26` is parameterized with `port:=0` or `port:=1` and scans
one Atari-style 4x3 switch matrix without modifying the other controller port's
SWCHA/SWACNT nibble. Pins 1 through 4 are driven as active-low row outputs; the
three columns return through INPT0/INPT1/INPT4 on the left or
INPT2/INPT3/INPT5 on the right. After the selected row settles, a pressed key
reads LOW on its column. The component exposes `keys` as a stable 12-bit
row-major snapshot for `1,2,3,4,5,6,7,8,9,*,0,#`, one-snapshot `pressed` and
`released` edge masks, and `key` as the first held key or `KEY_NONE`. Multiple
simultaneously held keys remain represented in `keys`.

The component deliberately does not own the row-settle delay. Call
`select_row(row)`, leave the selected row stable for at least 400 microseconds,
then call `read_row(row)`. This is a boolean matrix scan, not a paddle-position
measurement. Timing remains with the frame scheduler, allowing left/right
instances to select, settle, and sample the same row in parallel.
`begin_scan()` starts a fresh four-row snapshot and clears the previous edge
pulses; `end_scan()` commits the complete snapshot atomically. The public NTSC
example performs one row scan in overscan per frame, waits seven scanlines
before sampling, and commits a new complete state every four frames.

The implementation also deliberately matches Stella's Keyboard-controller ROM
auto-detection. INPT reads use recognized BIT/branch idioms, while SWCHA is
preserved with a detector-safe indexed read so the keypad ROM is not
misclassified as Joy2BPlus merely because it preserves the opposite port.

The public example at `examples/01_basic/11_keypad/` instantiates one keypad on
each port. A custom 13-glyph subset of the Big 8x16 font is drawn with P0 in the
left half and P1 in the right half: the twelve key labels plus an empty rectangle
when no key is held, white on the project's blue background.

## Left/right three-plus-three score component

`three_plus_three_score_component.c26` draws one fixed three-glyph score in each
half of the screen. The left glyph origins are X=20,36,52 and the right glyph
origins are X=100,116,132, so each 40-pixel field is centered in its 80-pixel
half. Each side has an independent packed-BCD value and TIA color:

```vcsc
include "fonts/default_decimal.c26"
instantiate "three_plus_three_score_component.c26" as score

void main(void)
{
    score_left_score := 123;
    score_right_score := 456;
    score_left_color := 0x2e;
    score_right_color := 0x9e;

    /* frame scheduler calls score_vblank(), score_draw(), score_overscan() */
}
```

The public score values are `bcd16_t`. The component displays their low three
decimal digits; the thousands nibble is intentionally not drawn, so `1000`
displays as `000`. Applications that want an ordinary 000..999 counter should
wrap the value explicitly at 999.

Each instance owns **28 RIOT-RAM bytes**: two two-byte packed-BCD values, two
color bytes, six 16-bit glyph pointers, two private raster scratch bytes, and
an eight-byte cache of the left hundreds glyph. The cache is refreshed during
`init()`/`vblank()` so the visible kernel can hit the two late P1 copy windows
without overrunning a scanline.
The component consumes exactly **11 visible scanlines**, enters `draw()` at
cycle 3, returns at cycle 0 after its terminal `WSYNC`, and performs one
`HMOVE`. It establishes all P0/P1 size, position, reflection, delay, graphics,
color, and horizontal-motion state it needs; before `HMOVE` it clears
M0/M1/Ball motion so preserved non-player geometry is not displaced. It does
not own playfield, missile/Ball enable/width, audio, collision, or scheduler
state.

The complete public example is
[`examples/01_basic/08_dual_score`](../../examples/01_basic/08_dual_score/).
The boundary regression simultaneously exercises `098 -> 099 -> 100` on the
left and `998 -> 999 -> 000` on the right while locking the exact P0/P1 raster
write schedule, independent colors, stable 262-line Stella frames, and the
installed copy of the component.

## Left/right two-plus-two score component

Include the immutable support module once, then instantiate the component as
many times as RAM permits:

```vcsc
include "two_plus_two_score_support.c26"
instantiate "two_plus_two_score_component.c26" as score

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
instantiate "renderers/poison_debug_score/poison_debug_score.c26" as poison
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
