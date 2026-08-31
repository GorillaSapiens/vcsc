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
- `vcs_2k_cv.c26`, `commavid.c26` ... CommaVid CV fixed 2K ROM plus shared 1K split-address cartridge RAM; `vcs_2k_cv.cfg` supplies simulator/compatibility mapping
- `vcs_4k.c26` ... conventional unbanked 4K topology and allocatable ROM
- `vcs_8k_f8.c26`, `vcs_16k_f6.c26`, `vcs_32k_f4.c26` ... inspectable selector-controlled C26 profiles with exact output order and generated corridors
- `inline_bankcall.s26` ... maintained 6507 source for the normal/F8-style fixed inline-target cross-bank JSR/RTS trampoline; DPC reuses this selector geometry
- `fa2/inline_bankcall.s26` ... FA2-specific maintained trampoline source; same stack/inline-target ABI with reversed selector indexing for `$1FF5-$1FFB`
- `vcs_8k_0840.c26` ... 0840/EconoBanking two-bank 8K profile with below-cartridge selectors `$0800/$0840`; `vcs_8k_0840.cfg` supplies simulator-only masked selector semantics
- `vcs_8k_ua.c26`, `vcs_8k_uasw.c26` ... UA Limited 8K alias-decoded profiles; UA maps `$0220`-family accesses to bank 0 and `$0240`-family accesses to bank 1, while UASW swaps that association; their cfg files supply simulator-only masked selector semantics
- `vcs_8k_0fa0.c26` ... Brazilian Fotomania 0FA0 two-bank 8K profile; `(A & $16E0)==$06A0/$06C0` selects physical bank 0/1, physical bank 1 powers up, and `vcs_8k_0fa0.cfg` supplies simulator metadata
- `vcs_8k_e0.c26` ... Parker Brothers E0 eight-by-1K segmented profile; three independent selectable 1K windows plus fixed physical bank 7, with `vcs_8k_e0.cfg` supplying simulator mapping
- `vcs_8k_fe.c26` ... FE/SCABS two-bank 8K profile; physical bank 0 starts at `$F000`, physical bank 1 maps at `$D000`, and mirrored `$01FE` arms the one-cycle-delayed data-bus bank latch; `vcs_8k_fe.cfg` supplies simulator metadata
- `vcs_10k_dpc.c26` ... DPC profile: two F8-style 4K program banks plus a 2K `$data_only` display bank and 255-byte `$data_only` Poly8 bank; `dpc.c26` exposes the register window and `vcs_10k_dpc.cfg` supplies simulator metadata
- `vcs_8k_3f.c26`, `vcs_16k_3f.c26` ... classic 3F selectable-lower-2K/fixed-final-2K profiles; they automatically bind ordinary TIA accesses through the `$40-$7F` mirror while `$00-$3F` remains available to the mapper
- `vcs_8k_3e.c26`, `vcs_16k_3e.c26` ... classic 3E ROM/RAM extension of the same 2K-window family, with 32 1K RAM banks and simulator cfgs for both public sizes
- `vcs_16k_jane.c26` ... JANE four-bank 16K profile preserving physical selectors `$1FF0/$1FF1/$1FF8/$1FF9` and hardware startup in physical bank 1; `vcs_16k_jane.cfg` supplies simulator-only physical-file mapping
- `vcs_12k_fa.c26`, `fa_ram_plus.c26` ... CBS FA/RAM Plus three-bank profile with physical startup bank 2 and shared 256-byte split-address cartridge RAM
- `vcs_24k_fa2.c26`, `vcs_28k_fa2.c26` ... FA2 six/seven-bank profiles with direct selectors `$1FF5-$1FFA/$1FFB`, physical startup bank 0, and the same shared 256-byte split-address cartridge RAM; matching cfg files support simulation. VCSC emits clean 24K/28K payloads; optional Harmony `$1FF4` persistence and 29K/32K wrapper forms are not part of the core profile.
- `vcs_4k_sc.c26`, `vcs_8k_f8sc.c26`, `vcs_16k_f6sc.c26`, `vcs_32k_f4sc.c26` ... direct/banked Superchip profiles with a reserved physical prefix and shared split-address RAM
- `vcs_direct_8k.c26` ... generic two-chunk directly mapped packaging profile used to certify selector-free output; no real hardware currently implements this exact mapping
- `vcs_omni_32k.c26` ... OmniCart/OMNI direct-addressing profile: seven directly addressed 4K RO islands plus one 4K RW island at `$1000`; `vcs_omni_32k.cfg` gives `vcsc-sim` the matching selector-free logical layout; no real hardware currently implements OMNI
- `vcs_*.cfg` ... retained legacy profile descriptions for simulator input and compatibility/differential certification; public builds use the C26 profiles
- `color_ntsc.c26`, `color_pal.c26`, `color_secam.c26` ... readable standard-specific aliases backed by the compile-time RGB palette matchers
- `frame_ntsc.c26` ... shared NTSC phase constants, scanline waiting, VSYNC, and scheduler-owned VBLANK/overscan deadlines
- `frame_pal.c26`, `frame_secam.c26` ... distinct PAL50/SECAM50 public front ends over the shared measured 312-line `frame_50hz_component.c26` scheduler core
- `playfield.c26` ... compile-time `VCS_PLAYFIELD_ROW()` conversion from left-to-right 32-bit visual rows to the four asymmetric TIA playfield bytes
- `sound_ntsc.c26` ... NTSC TIA audio-control, note-frequency, volume, and frame-timing aliases
- `sound_pal.c26`, `sound_secam.c26` ... 50 Hz TIA control/note aliases plus PAL/SECAM frame-duration constants through `sound_50hz.c26`
- `VIDEO_STANDARDS.md` ... PAL/SECAM/NTSC component-portability classification and measured 228-line composition guidance
- `six_glyph_wide_component.c26` ... separate mutable-color six-glyph profile with origins at X=36,52,68,84,100,116; `glyph_rows:=8` is the default, while shorter tightly packed fonts select the six-full-pointer path automatically
- `six_glyph_big_wide_component.c26` ... matching wide geometry for the Big decimal/hex fonts; `glyph_rows:=16` by default and nondefault tightly packed heights consume `glyph_rows+3` visible scanlines
- `six_glyph_left_component.c26` ... mutable-color variant justified at X=0..47; `glyph_rows:=8` by default, with tightly packed shorter fonts automatically using six full pointers
- `six_glyph_right_component.c26` ... mutable-color variant justified at X=112..159; `glyph_rows:=8` by default, with tightly packed shorter fonts automatically using six full pointers
- `six_glyph_component.c26` ... canonical centered 48-pixel/six-glyph lifecycle display; `glyph_rows:=8` preserves the compact default, shorter tightly packed fonts use six full pointers, `external_pointers:=1` lets callers own those pointers, `mutable_color:=1` adds an application-visible color byte, and compile-time `paddle_samples:=2` can spend setup-line slack on bounded paddle probes
- `three_plus_three_score_component.c26` ... dual score with independent three-digit packed-BCD values and colors, centered as X=20,36,52 and X=100,116,132; `glyph_rows:=8` by default, shorter score fonts are tightly packed, and optional compile-time two/four-paddle sampling uses deterministic score-line slots
- `two_paddles.c26` ... two analog CX30-style paddles plus both fire buttons on either controller port, with explicit VBLANK dump/charge ownership, multi-frame raw timing, and bounded score-renderer probe helpers
- `keypad_controller.c26` ... one 12-key Atari-style keypad on either controller port, with explicit row selection, caller-owned settle timing, stable 12-bit state, and press/release edge masks
- `driving_controller.c26` ... one Atari Indy 500 driving controller on either port, with Gray-code direction decoding, signed per-sample step/per-frame delta, skipped-state direction preservation, and live fire-button state
- `two_plus_two_score_support.c26` ... shared page-contained compact decimal glyph and calibrated horizontal-position tables for two-plus-two scores
- `two_plus_two_score_component.c26` ... repeatable P0/P1 score with independent packed-BCD left/right values, colors, and X positions; `glyph_rows:=8` by default selects how many rows of its native support glyphs are drawn
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
- `../../examples/09_bankswitching/` ... F8/F6/F4/SC complete transition diagnostics plus the CBS FA/RAM Plus complete ordered-call PASS/FAIL diagnostic
- `../../examples/10_faithful_legacy_multisprite/` ... fixed faithful P0-plus-five-P1 multisprite reference cartridge used to anchor roadmap item 28
- `../../examples/14_multisprite/` ... modern parameterized multisprite examples: full-height 192-line interaction plus 181-line interactive score-above and score-below compositions, all with horizontal/vertical P0/P1..P5 movement
- `../../examples/15_all_five_player_color_192/` ... full-height interactive combined all-five/per-row-player-color diagnostic
- `../../examples/16_all_five_player_color_181/` ... fixed centered score-above and score-below compositions for the 181-line combined all-five/per-row-player-color profile
- `../../examples/11_all_five_170/` ... `all_five (lines:=170)` interactive composition with an eleven-line score above and another below
- `../../examples/12_all_five_170_unofficial/` ... matching `all_five_unofficial (lines:=170)` dual-score composition, built explicitly with `-Wa,--illegals`
- `../../examples/13_player_color_170/` ... `player_color (lines:=170)` interactive composition with an eleven-line score above and another below
- `../../examples/17_video_standards/` ... separate `pal/` and `secam/` 50 Hz example trees with minimal frames and native interactive 228-line all-five compositions using `__builtin_pal_rgb()` / `__builtin_secam_rgb()` directly
- `../../examples/18_enhanced_multisprite/` ... maintained asymmetric-playfield enhanced multisprite diagnostic; the renderer is line-parameterized for 192 and native PAL/SECAM 228 active lines

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
boundary `WSYNC` and clears VBLANK. `vcs_ntsc_vsync()` aligns first and then
asserts/deasserts VSYNC at the same cycle phase exactly 228 CPU cycles apart.
`vcs_ntsc_end_overscan()` leaves VBLANK asserted for VSYNC and issues two blanked
frame-closeout boundaries; the leading alignment `WSYNC` in the next exact VSYNC
pulse supplies the third boundary around the transition required by Stella/TIA
accounting for a stable 262-scanline, 60.0 Hz NTSC frame. A missed deadline cannot be repaired
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
overscan. The shared 50 Hz core uses the same exact three-line, 228-CPU-cycle
VSYNC contract as NTSC. As with the NTSC scheduler, the CPU timing harness counts
two TIA frame-closeout boundaries beyond Stella's displayed frame total: a stable
312-line PAL/SECAM frame is therefore 314 raw harness intervals. The visible-component
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
NTSC renderers remain NTSC-only. The public PAL/SECAM all-five examples instantiate `all_five (lines:=228)` and
consume the complete 228-line visible field directly. A full-height cycle-counted
component returns at cycle zero after its terminal WSYNC; the standard-specific
`component_to_overscan_handoff()` supplies the 16-cycle phase normalization that
the generic 228-line wait path would have contributed before `begin_overscan()`.
It does not add a visible scanline.

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

For score renderers that explicitly opt into paddle sampling, the component
also exposes `score_sample0()`, `score_sample1()`, `score_advance_pair()`, and
`score_account_a()`. The score probes require X=0, preserve X/Y, and have a
17-cycle threshold-completion path (the worst case). `score_account_a()` takes a scheduled count of
two-scanline pairs in A and saturates the shared elapsed counter. Applications
bind these through tiny instance-prefixed inline hooks before score-component
instantiation, so the ordinary score path pays no runtime dispatch cost.

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
should not branch through four threshold-completion paths on one scanline. The
built-in four-line blank sampler therefore snapshots INPT0..INPT3 together at
one fixed phase, then commits one channel per line from that shared timestamp.
This avoids giving the right-port pair a systematic phase/range offset merely
because its commit runs later. The shared elapsed counter advances once per
four-line group, so all four positions retain the same units as
`two_paddles.c26`. Seven VBLANK sample groups consume 28 lines and leave enough
of the scheduler's 37-line deadline for component bookkeeping; `account_gap()`
preserves elapsed time across the unsampled remainder, score, and display setup.
The emulator oracle exercises distinct, simultaneous, and staggered four-channel
thresholds plus every fire button while requiring invariant frame length.

Four-paddle score integration adds the same bounded channel-0/1 probes plus
`score_latch23_fixed()`, a fixed 24-cycle channel-2/3 latch with no
data-dependent branch. A score renderer can therefore place it inside a
calibrated horizontal-position delay without moving RESP timing. For diagnostics
that require directly comparable channels, `score_latch0123_fixed()` captures
all four comparator bits plus one timestamp in 30 fixed cycles; the four
`score_commit_latchedN()` helpers may then consume that snapshot in later slack
without changing the measured phase. The public four-player Paddleball example
uses the 2/3 contract; the field diagnostic uses the simultaneous four-channel
form.

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

## Indy 500 driving controller

`driving_controller.c26` supports one Atari Indy 500 driving controller on
either controller port with `port:=0` (left, the default) or `port:=1` (right).
Pins 1 and 2 are read from SWCHA as a two-bit Gray code: left D4/D5 and
right D0/D1. Pin 6 is the active-low fire button through INPT4 or INPT5. The selected SWACNT nibble is
made input-only while the opposite controller port's direction bits are left
unchanged. With the phase written as pin1:pin2, clockwise motion is
`11 -> 10 -> 00 -> 01 -> 11`; counterclockwise motion is the reverse.

Call `init()` once, `begin_frame()` once at the start of each application frame,
and `sample()` as often as blanking time permits. `step` is the most recent
signed movement (`-2`..`+2`) and `delta` accumulates all movement since the most
recent `begin_frame()`, with positive values clockwise. `button` is 1 exactly
while fire is held, `phase` exposes the current raw Gray state, and `direction`
remembers the last unambiguous direction. Adjacent states are +/-1 even across
the Gray-code wrap. An opposite-state read means one intermediate phase was
missed; once direction is known the component preserves it and reports +/-2.
Before direction has been established, an opposite jump is deliberately ignored
rather than inventing a direction. Larger unsampled motion is intrinsically
ambiguous, so callers that expect fast rotation should sample repeatedly during
VBLANK and overscan.

The public example at `examples/01_basic/12_drive/` instantiates one controller
on each port and samples both three times in VBLANK plus three times in overscan.
Each side displays an independent Big-font hexadecimal digit centered in its
half of the screen. Clockwise increments, counterclockwise decrements, and the
value wraps between `0` and `F`. A released button draws white; a held button
draws red. Emulator-backed tests also exercise each port independently, skipped
Gray states, button press/release, opposite-port isolation, counter wrap, and
stable NTSC frame timing.

Current Stella does not auto-detect the Driving controller type from ROM access
patterns, so select **Driving** manually for each port used by the cartridge.

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
`init()`/`vblank()` so the visible renderer can hit the two late P1 copy windows
without overrunning a scanline.
The component consumes exactly **11 visible scanlines**, enters `draw()` at
cycle 3, returns at cycle 0 after its terminal `WSYNC`, and performs one
`HMOVE`. It establishes all P0/P1 size, position, reflection, delay, graphics,
color, and horizontal-motion state it needs; before `HMOVE` it clears
M0/M1/Ball motion so preserved non-player geometry is not displaced. It does
not own playfield, missile/Ball enable/width, audio, collision, or scheduler
state.

`paddle_samples:=0` is the default and preserves the ordinary renderer path.
With `paddle_samples:=2`, the application defines `score_paddle_sample0()`,
`score_paddle_sample1()`, and `score_paddle_advance_pair()` before instantiation;
the renderer reserves X=0 and invokes them in deterministic setup-line slack.
With `paddle_samples:=4`, it additionally requires
`score_paddle_latch23_fixed()`. That fixed-cycle hook replaces part of the
existing P1-positioning delay, so analog threshold state cannot move RESP1; the
application commits the channel-2/3 latch later through its paddle instance.
The two Paddleball examples demonstrate both modes.

The centered `six_glyph_component.c26` likewise accepts `paddle_samples:=2` and
calls two compile-time hooks in its setup-line slack. The hooks own their own
register contract; direct 17-cycle paddle probes reserve X=0, while the field
diagnostic instead commits channels 0/1 from a simultaneous four-channel latch.
Its row-alignment line takes the fixed snapshot, the following row preparation
commits 2/3 from the same timestamp, and a final two-line commit drains the last
row. Thus all four displayed diagnostic values share identical sampling phase
rather than merely identical nominal elapsed units.

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

Unqualified functions and private `const` objects do not need `bankN` qualifiers.
The linker automatically places each whole CODE/RODATA layout in any compatible
read-only region with room, while keeping `main` and `_` startup/runtime helpers
in the profile's startup/home bank. Explicit `bankN` placement remains a hard
override. Selector-controlled profiles optimize call locality and synthesize
trampolines only when needed; selector-free direct profiles use ordinary 16-bit
cross-region calls and data references. Writable RAM is intentionally different:
unqualified DATA/BSS/ZEROPAGE stay in the configured default RAM, and cartridge
RAM such as `cartram` must still be named explicitly when the programmer wants
it.

The conventional F8/F6/F4 profiles use descending VCSC logical banks with BANK0
at `$F000-$FFFF` as the home/startup bank and final 4K file chunk. JANE, 0840, UA, UASW, 0FA0, E0, FE, WD, and DPC
preserve their hardware-specific physical startup/file ordering instead. Selected
file-order and selector layouts are:

```text
profile  first file chunk          final file chunk          selector range  signature
-------  ------------------------  ------------------------  --------------  ---------
F8       BANK1 $D000 via $1FF8     BANK0 $F000 via $1FF9    $1FF8-$1FF9     F8\0\0
0840     BANK0 $F000 via $0800     BANK1 $D000 via $0840    below $1000     0840
UA       BANK0 $F000 via $0220     BANK1 $D000 via $0240    alias-decoded    UA\0\0
UASW     BANK0 $F000 via $0240     BANK1 $D000 via $0220    alias-decoded    UASW
0FA0     BANK1 $D000 via $0FA0     BANK0 $F000 via $0FC0    mask $16E0      0FA0
E0       physical 0 (1K)           physical 7 fixed $1C00    $1FE0-$1FF7     E0\0\0
FE       physical 0 $F000         physical 1 $D000          delayed $01FE     FE\0\0
WD       physical 0 (1K)           physical 7 (1K)           reads $30-$3F    WD\0\0
DPC      F8 file bank 0           F8 file bank 1           $1FF8-$1FF9     DPC\0
F6       BANK3 $9000 via $1FF6     BANK0 $F000 via $1FF9    $1FF6-$1FF9     F6\0\0
F4       BANK7 $1000 via $1FF4     BANK0 $F000 via $1FFB    $1FF4-$1FFB     F4\0\0
```

For the conventional selector-hotspot 4K physical-bank profiles in that table
(excluding E0, FE, WD, and DPC), each bank allocates ordinary ROM only through `$xEFF`.
`$xF00-$xFDF` is the byte-identical trampoline table, `$xFE0-$xFF1` is the
byte-identical vector bridge, and the remaining tail contains reserved selector
bytes, mapper metadata, and vectors. E0 instead uses 1K physical chunks; banks
0-6 expose their full 1K, while fixed bank 7 reserves `$FFE0-$FFFF` for E0
selectors, mapper metadata, and vectors as described below. FE uses complete 4K
physical chunks but has no generated trampoline or vector-bridge corridor; its
`$01FE` control access is on the stack bus rather than in cartridge ROM. WD uses
eight 1K physical chunks plus split cartridge RAM and delayed TIA-read
arrangement selection. DPC uses two 4K program chunks whose first `$80` bytes
are hidden by the register window, followed by 2K and 255-byte file-domain
`$data_only` chunks. The final CPU-mapped bank stores the profile's four-byte mapper signature at `$xFF8-$xFFB`; shorter
names are ASCII-NUL padded. Those locations may overlap cartridge-window
selector hotspots because switching is caused by the bus access address rather
than the ROM byte value. 0840, UA/UASW, and 0FA0 selectors are below the
cartridge window and therefore do not reserve tail bytes at all. Where the final
file bank also owns the vector page, `$xFFA/$xFFB` are signature bytes instead
of an NMI vector; the Atari 2600's 6507 has no NMI input, while RESET and IRQ/BRK
remain ordinary vectors. FE is the exception: its final file bank is the
`$D000` view and carries `FE\0\0` at `$DFF8-$DFFB`, while RESET and IRQ/BRK
remain in startup physical bank 0 at `$FFFC-$FFFF`.

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
for the conventional profiles shown here; physical bank 7 for E0). Direct
cross-bank `JSR` and `JMP` are rewritten through the replicated common table
where that profile supplies one. Ordinary cross-bank ROM data references remain
errors.

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
- The 4KSC, F8/F6/F4, 0840, UA/UASW, 0FA0, E0, FE, WD, DPC, 3F/3E, JANE, FA/RAM Plus, banked SC, and OMNI `.c26` profiles are installed beside `vcs.cfg` and emit exact 4K, 8K, 12K, 16K, and 32K images. Profile-specific cfg files remain installed where needed for compatibility and simulator selection; `vcs_omni_32k.cfg` is simulator-only direct logical placement metadata, not a switched-mapper linker profile.
- Those public mapper profiles stamp only the final physical file chunk at logical `$xFF8-$xFFB` with `4KSC`, `F8\0\0`, `F8SC`, `F6\0\0`, `F6SC`, `F4\0\0`, `F4SC`, `FA\0\0`, `CV\0\0`, `OMNI`, `JANE`, `0840`, `UA\0\0`, `UASW`, `0FA0`, `E0\0\0`, `FE\0\0`, `WD\0\0`, `DPC\0`, `3F\0\0`, or `3E\0\0`. The NUL padding prevents a short mapper name from resembling a plausible NMI-vector address, and the trailing `SC` in `4KSC` also satisfies Stella's 4KSC autodetection convention.
- `vcsc` discovers `vcs.cfg` and `vcs_4k.c26` in the source tree or installed `share/vcs` directory and uses both by default. Pass `-T vcs.cfg` plus another C26 profile to select a different cartridge layout.
- The 128 physical RIOT RAM bytes are not double-counted. `vcs.c26` declares the full `$80-$FF` block and reduced `vcs.cfg` asks `vcsc-ld` to reserve the top bytes dynamically from the whole-program source call graph before placing ordinary storage. The page-1 addresses `$0180-$01FF` are mirrors of `$80-$FF`, not separate RAM.
- Current stack sizing accounts automatically for source-level JSR return addresses; ordinary generated calls push no compiler state. Assembly components use `.callstackextra` object metadata for calls, pushes, or stack-pointer use hidden from the source call graph. C26 renderer templates emit the same assembler directive through inline assembly, including an explicit zero when an audited hidden JSR fits entirely inside the source-call reserve. `player_color_192` now flattens its two single-use mask-preparation wrappers and declares `.callstackextra 0`; the standard and multi-object renderers still declare their measured four supplementary bytes for deeper/repeated helper chains. The standard renderer also exports its assembly-initiated overscan-hook edge. Component code and score-table layouts carry startup-region, page-alignment, private-route, `.pagecontain`, and `.indexrange` facts in the object instead of renderer-specific cfg products. Arbitrary inline-assembly stack use must still be declared explicitly.
- Example 04 uses one balanced `PHP`/`PLA` pair per probe to read P and verifies that the linked map leaves the byte immediately below the call-stack reserve unused.
- `legacy-basic-renderers/` remains untouched reference/source material imported from upstream legacy BASIC. The all-five solid-color profile and the separate no-missile per-row-player-color profile are reproducibly normalized beside their contracts and exercised by complete cartridges. See `LEGACY_RENDERER_CONVERSION.md` for the staged conversion inventory.
- The VCS hardware mirrors TIA and RIOT addresses heavily. The bindings use the conventional canonical addresses.

### Common `cartram` source name

Every public VCSC profile that provides mapper-owned cartridge RAM exposes it to
source code with the same named-memory qualifier, `cartram`. The physical device
still depends on the selected profile: Superchip supplies 128 split-address bytes,
CBS FA/RAM Plus supplies 256 split-address bytes, CommaVid CV supplies 1024
split-address bytes, and OMNI supplies the direct
`$1000-$1FFF` 4K writable island. This common source name is intentional so code
using cartridge RAM can move between mapper profiles without renaming every
declaration. The profile remains authoritative for the size and read/write aliases.

Ordinary unqualified variables still use the default RIOT RAM. Cartridge RAM is
selected explicitly, for example:

```c
cartram uint8_t state[32];
```

### CommaVid CV profile and allocatable RAM

The public `vcs_2k_cv.c26` profile emits one fixed 2K ROM image mapped at
`$F800-$FFFF`. `commavid.c26` exposes the common `cartram` qualifier as a
1024-byte split-address device: reads use `$F000-$F3FF` and writes use
`$F400-$F7FF`. There are no selector hotspots or bank-switch states.

```c
mem cartram { $read_start:0xF000 $write_start:0xF400 $size:0x0400 $rw };
```

The profile stamps `CV\0\0` at logical `$FFF8-$FFFB` (file offsets
`$07F8-$07FB`) and leaves RESET/IRQ at `$FFFC-$FFFF`. DATA/BSS startup uses
the same per-object split-alias copy/zero machinery as Superchip and FA.

### 0840 / EconoBanking profile

The public `vcs_8k_0840.c26` profile emits two 4K physical banks in file order.
Physical bank 0 is the startup/home bank and the canonical selector `$0800`
selects it; `$0840` selects physical bank 1. Hardware decoding aliases these
selectors below the cartridge window, so they are bus triggers rather than ROM
locations. VCSC therefore does not reserve corresponding `$F800/$F840` bytes.

Generated vector bridges and cross-bank stubs use undocumented NMOS absolute NOP
opcode `$0C` for below-window selector reads. That access preserves registers and
flags and avoids a write to the mirrored console device. `vcs_8k_0840.cfg` is
simulator-only metadata; `vcsc-sim` models the decoded selector families on both
reads and writes while allowing the underlying low-memory operation to occur.
The final physical bank carries the `0840` signature at `$FFF8-$FFFB`.

### UA / UASW profiles

The public `vcs_8k_ua.c26` and `vcs_8k_uasw.c26` profiles emit two 4K physical
banks in file order 0/1, with physical bank 0 selected at power-on. UA decodes
`(A & $1260)==$0220` as bank 0 and `==$0240` as bank 1; UASW uses the same
alias families with the association reversed. Thus shifted aliases such as
`$02A0/$02C0` are selector accesses too.

Because these selectors live below the cartridge window, generated vector
bridges and cross-bank stubs use undocumented NMOS absolute NOP `$0C` reads,
preserving registers and flags without writing the mirrored console device. The
selector side effect does not swallow the underlying low-address transaction:
reads sample the console byte and writes still reach the console-side model.
`vcs_8k_ua.cfg` and `vcs_8k_uasw.cfg` provide the matching masked decoder and
selector-to-file-bank association to `vcsc-sim`. The final bank carries
`UA\0\0` or `UASW` at `$FFF8-$FFFB`.

### 0FA0 / Fotomania profile

The public `vcs_8k_0fa0.c26` profile emits two 4K physical banks. Physical/file
bank 1 is the hardware startup bank, so VCSC logical `bank0` is emitted as file
index 1 and selected through canonical alias `$0FC0`; logical `bank1` is file
index 0 and selected through `$0FA0`.

0FA0 is mask-decoded rather than a pair of exact hotspots. After 6507 physical
address mirroring, `(A & $16E0)==$06A0` selects physical bank 0 and
`(A & $16E0)==$06C0` selects physical bank 1. A11, A8, and A4-A0 are therefore
don't-care alias bits. `vcsc-sim` keeps that mask explicit, and reads or writes
to any matching alias still perform the underlying console-side access before
the mapper switch. Generated transitions use the same state-preserving NMOS
absolute-NOP read as the other below-window profiles.

The final physical bank carries the `0FA0` signature at `$FFF8-$FFFB`.

### Classic 3F and 3E profiles

The public `vcs_8k_3f.c26` / `vcs_16k_3f.c26` profiles expose a selectable lower
2K window at `$1000-$17FF` and a fixed final physical 2K at `$1800-$1FFF`. A
write in the low TIA page selects the lower 3F ROM bank from the written value.
Because classic 3F owns those low-page writes, the profile selects
`tia_mirror_40.c26`: ordinary TIA reads/writes use the equivalent `$40-$7F`
mirror automatically instead of accidentally changing ROM banks.

Classic 3E uses the same ROM shape but reserves exact `$3F` for lower-ROM bank
selection and exact `$3E` for one of 32 1K RAM banks. In RAM mode `$1000-$13FF`
is the read alias and `$1400-$17FF` the write alias. 3E also selects
`tia_mirror_40.c26` for ordinary TIA accesses. This keeps VSYNC/WSYNC and the
rest of TIA I/O off the cartridge-owned low write page and works whether an
emulator forwards non-hotspot `$00-$3D` writes or not. The final physical bank
carries `3F\0\0` or `3E\0\0` metadata and owns RESET/vectors.

### E0 profile

The public `vcs_8k_e0.c26` profile emits eight physical 1K chunks in file order
0 through 7. E0 exposes three independently selected windows: `$1000-$13FF`
uses selectors `$1FE0-$1FE7`, `$1400-$17FF` uses `$1FE8-$1FEF`, and
`$1800-$1BFF` uses `$1FF0-$1FF7`. `$1C00-$1FFF` is always physical bank 7.
Power-on selects physical banks 4, 5, 6, and 7 respectively.

Unlike whole-window F8/F6/F4 switching, one physical E0 bank can be selected into
more than one CPU window. The C26 profile therefore does not pretend that each
bank has one `$select_access`. Instead each physical chunk receives one unique
6507-mirrored link alias for a canonical compilation window; explicit source
that changes E0 mappings performs the corresponding selector access before
calling or reading code/data in that window. The linker validates the eight 1K
shape, the aliases, and fixed startup bank 7. `vcs_8k_e0.cfg` supplies the
runtime segmented mapping to `vcsc-sim`.

The final physical bank carries `E0\0\0` at `$FFF8-$FFFB`; RESET and IRQ/BRK
remain in fixed bank 7 at `$FFFC-$FFFF`.

### DPC profile

The public `vcs_10k_dpc.c26` profile emits the conventional 10,495-byte DPC
image as four logical chunks. `bank0` and `bank1` are ordinary F8-style 4K
program ROM selected by `$1FF9/$1FF8`; because `$1000-$107F` is DPC register
space, only physical offset `$0080-$0FFF` is CPU-visible program ROM. `bank2` is
a 2048-byte `$data_only` display-ROM chunk and `bank3` is the conventional
255-byte `$data_only` Poly8 tail. Their matching `mem` declarations use
`$data_bank` and have no CPU address, so ordinary code, pointers, or relocations
cannot read them directly.

`dpc.c26` declares the DPC register bindings. The diagnostic reads all 2K of
display ROM through a hardware data fetcher, verifies an order-sensitive
checksum and counter wrap, resets the RNG, and checks the complete 255-state
LFSR cycle. The `DPC\0` signature remains in the last CPU-mapped program bank;
the later data-only chunks are left byte-exact.

### FE / SCABS profile

The public `vcs_8k_fe.c26` profile emits two physical 4K chunks in released-cart
order: physical/file bank 0 is the `$F000-$FFFF` startup view and physical/file
bank 1 is the `$D000-$DFFF` alternate view. There is no address-select hotspot.
An access to mirrored `$01FE` arms a latch, and the following bus cycle's data
selects the physical bank: values with an E/F high nybble select bank 0 and C/D
select bank 1. `vcs_8k_fe.cfg` gives `vcsc-sim` the matching delayed-bus model.

With the 6507 stack pointer at `$FF`, a top-level `JSR $Dxxx` naturally writes
the low return byte to `$01FE`; the following target-high fetch selects bank 1.
`RTS` later reads `$01FE`, and the following caller-high stack byte restores bank
0. VCSC therefore keeps automatic FE ROM in startup bank 0, permits explicit
`bank1` placement, emits a direct cross-bank JSR only from `main`, and rejects
nested cross-bank calls, cross-bank JMP/branches, and cross-bank ROM-data
references. FE does not use the generic bank-switch trampoline corridor.

Stack-heavy startup code is unsafe because unrelated pushes can address `$01FE`.
The public FE diagnostic therefore keeps startup data BSS-only, uses the simple
startup path, explicitly establishes `SP=$FF` before its bank-crossing JSR, and
sets display state afterward. The final physical bank carries `FE\0\0` at
`$DFF8-$DFFB`; the startup bank retains RESET and IRQ/BRK vectors at
`$FFFC-$FFFF`.

### WD / Wickstead Design profile

The public `vcs_8k_wd.c26` profile emits the corrected 8192-byte WD image as
eight physical 1K chunks in file order 0 through 7. WD maps four 1K segments at
`$1000-$13FF`, `$1400-$17FF`, `$1800-$1BFF`, and `$1C00-$1FFF`; reads of
TIA `$30-$3F` select one of eight complete segment arrangements. The new
arrangement becomes visible only after the selector read has aged beyond the
hardware delay, so VCSC models selection as a delayed read side effect rather
than an ordinary hotspot bank change. Power-on arrangement 0 maps physical
chunks `0,0,1,3`, making physical/file chunk 3 the startup/vector chunk.

WD also exposes 64 bytes of split-address cartridge RAM: reads use
`$1000-$103F` and writes use `$1040-$107F`. Because the mapper owns TIA reads
at `$30-$3F`, the profile binds ordinary TIA I/O through the equivalent
`$40-$7F` mirror; deliberate three-cycle dead-flag delays use raw TIA `$00`,
which is not a WD selector. VCSC does not synthesize generic WD cross-arrangement
trampolines: explicitly banked code/data must only execute after program code has
selected an arrangement that maps that physical chunk into its canonical CPU
segment. `vcs_8k_wd.cfg` gives `vcsc-sim` the matching arrangement/RAM model.
The final physical chunk carries `WD\0\0` in its reserved tail.

### JANE profile

The public `vcs_16k_jane.c26` profile emits four complete 4K physical banks in
hardware file order. Accesses to `$1FF0`, `$1FF1`, `$1FF8`, and `$1FF9` select
physical/file banks 0, 1, 2, and 3 respectively. JANE powers up in physical bank
1; VCSC therefore keeps its conventional logical `bank0` as the startup/home
bank while assigning that logical bank `$file_index:1`. The other logical bank
names preserve their own independent file indices rather than using the usual
reversed F8/F6/F4 ordering.

Because `$FFF0/$FFF1` are JANE selector hotspots, its replicated reset/vector
bridge lives at `$FEE0-$FEF1` instead of the normal `$FFE0-$FFF1` corridor. The
common call trampoline remains at `$FF00-$FFDF`. The final file bank carries the
`JANE` signature at `$FFF8-$FFFB`; bytes stored at `$FFF8/$FFF9` are harmless
because the address access, not the stored byte, performs selection.

`vcs_16k_jane.cfg` is simulator-only metadata that records the explicit physical
`fileindex` for each logical bank. Public linking is driven by the C26 topology.

### FA / RAM Plus profile and allocatable RAM

The public `vcs_12k_fa.c26` profile emits three complete 4K physical banks.
File chunks 0/1/2 are selected by `$1FF8/$1FF9/$1FFA`; hardware power-on bank
2 is VCSC `bank0`, the startup/home bank and final file chunk. FA cartridge RAM
hides the first `$200` bytes of every selected bank: writes use `$F000-$F0FF`,
reads use `$F100-$F1FF`, and ordinary ROM begins at `$F200`. With the common
trampoline/vector corridor reserved at `$xF00-$xFFF`, each bank has 3328 bytes
of ordinary allocatable ROM.

`fa_ram_plus.c26` declares the shared device as:

```c
mem cartram { $read_start:0xF100 $write_start:0xF000 $size:0x0100 $rw };
```

Applications use ordinary named-memory syntax such as `cartram uint8_t state[32];`.
DATA/BSS startup writes through the write alias, loads use the read alias, and
bank changes preserve the 256 physical RAM bytes.

### Superchip profiles and allocatable RAM

The public `vcs_4k_sc.c26`, `vcs_8k_f8sc.c26`, `vcs_16k_f6sc.c26`, and
`vcs_32k_f4sc.c26` profiles reserve
the first 256 bytes of each physical 4K chunk for the shared 128-byte Superchip
RAM ports. 4KSC is a single direct chunk with ordinary ROM at `$F100-$FFFF`;
F8SC/F6SC/F4SC retain their ordinary selector order and begin each selected ROM
window at `$x100`. Complete 4K chunks are still emitted. Hardware power-on
contents are unspecified. VCSC
startup therefore clears every allocated Superchip BSS object and copies every
allocated DATA initializer through `$F000-$F07F` on every reset. Mapper switches
preserve the shared physical bytes; reset intentionally reinitializes them.
Unallocated bytes have no compiler/runtime lifecycle guarantee.

The SC profiles include `superchip.c26`, whose hardware-specific window definition
exposes the common `cartram` named region:

```c
mem cartram { $read_start:0xF080 $write_start:0xF000 $size:0x0080 $rw };
```

Applications may allocate persistent globals, arrays, automatic locals,
function-scope static locals, value parameters, and function return objects
directly:

```c
cartram uint8_t foo;
cartram uint8_t buffer[32];

void update(cartram uint16_t value) {
   cartram uint8_t scratch := foo;
   static cartram uint8_t calls;
   value += 1; // caller writes $F000 alias; this load/store uses both aliases
   scratch++;
   calls++;
   foo := scratch;
}

cartram uint16_t current_value(void) {
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
expansions receive private local symbols. Function-scope `static cartram`
objects instead occupy persistent `BSS.cartram` or `DATA.cartram` storage.
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
non-void function may likewise use `cartram` to place its exact-sized hidden
return object in the shared window. `return expression;` and assignments to `$$`
write through `$F000`, while callee and caller reads use `$F080`. One or more separate
read-only bank modifiers may independently select function-body copies, for
example `bank0 bank1 cartram uint16_t sample(void)`. Modifier order is
irrelevant; bodies use `CODE.bank0` and `CODE.bank1` while every copy shares the
single `sample$__return` object in Superchip RAM. A bank-local call is preferred;
a caller in another bank may use a normal trampoline to the primary copy.

A Superchip result function may declare one automatic local in the same
`cartram` region and return that local on every return path. When its type and
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
so persistence probes must own storage through `cartram` like ordinary
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
