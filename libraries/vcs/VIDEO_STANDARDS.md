```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# VCS video-standard portability

VCSC keeps television-standard frame ownership separate from visible raster
components.  New code should select one frame front end (`frame_ntsc.c26`,
`frame_pal.c26`, or `frame_secam.c26`) and then compose scheduler-neutral
visible components inside that standard's visible budget.

PAL and SECAM share the 50 Hz scheduler mechanics but remain distinct public
standards.  PAL has the 128-entry TIA palette (with PAL color-loss behavior in
the display system); SECAM has eight distinct display colors.  Raw TIA color
register writes remain available as a low-level escape hatch, so VCSC does not
pretend it can diagnose the intent of every numeric color byte.  Code that wants
a guaranteed legal SECAM display color should use `color_secam.c26` or
`__builtin_secam_rgb()`.

## Maintained visible-component classification

The following C26 components are **timing portable** across NTSC/PAL/SECAM.
They own no VSYNC, VBLANK, or RIOT frame timer and publish their visible-line
contract independently of the frame scheduler:

- `renderers/all_five/all_five.c26` (181 or 192 lines)
- `renderers/all_five_player_color_181/all_five_player_color_181.c26`
- `renderers/all_five_player_color_192/all_five_player_color_192.c26`
- `renderers/all_five_unofficial/all_five_unofficial.c26` (181 or 192 lines)
- `renderers/multisprite/multisprite.c26` (181 or 192 lines)
- `renderers/player_color/player_color.c26` (181 or 192 lines)
- `renderers/player_color_181_unofficial/player_color_181_unofficial.c26`
- `renderers/poison_debug_score/poison_debug_score.c26`
- `six_glyph_component.c26`
- `six_glyph_left_component.c26`
- `six_glyph_right_component.c26`
- `six_glyph_wide_component.c26`
- `six_glyph_big_wide_component.c26`
- `two_plus_two_score_component.c26`
- `three_plus_three_score_component.c26`

Geometry portability does not imply palette portability. Components that consume
caller-provided color bytes must be supplied PAL or SECAM colors by the caller;
for SECAM, prefer the eight `VCS_SECAM_*` aliases.  Components without their own
color state simply inherit the caller's TIA colors.

The following retained compatibility/legacy renderers are **NTSC-specific** and
are not presented as PAL/SECAM profiles:

- `renderers/standard_4k_ntsc/`
- `renderers/standard_4k_ntsc_playercolors/`
- `renderers/faithful_legacy_multisprite/`
- `renderers/faithful_legacy_playercolors/`

Those implementations own or encode complete NTSC frame geometry rather than
being scheduler-neutral visible components.  Porting them would be a distinct
renderer rewrite, not a PAL conditional added to their existing bodies.

## 228-line PAL50 / SECAM50 composition

The public 50 Hz frame front ends expose 228 visible lines.  A 192-line visible
component can therefore be centered with scheduler-aware blank gaps.  The
maintained all-five 192-line examples use 17 pre-component helper lines and an
18-line visible tail.  The renderer's terminal WSYNC boundary is part of its
published raster contract, so this measured composition reaches overscan at the
228-line boundary; do not replace the measured wrapper with arithmetic on source
line counts alone.

Use emulator-backed timing tests for every new composition.  A component that
fits numerically can still have an incompatible entry/return phase.
