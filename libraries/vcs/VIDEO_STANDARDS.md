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

- `renderers/all_five/all_five.c26` (170, 181, 192, or 228 lines)
- `renderers/all_five_player_color_181/all_five_player_color_181.c26`
- `renderers/all_five_player_color_192/all_five_player_color_192.c26`
- `renderers/all_five_unofficial/all_five_unofficial.c26` (170, 181, 192, or 228 lines)
- `renderers/multisprite/multisprite.c26` (181, 192, or 228 lines)
- `renderers/player_color/player_color.c26` (170, 181, 192, or 228 lines)
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

The public 50 Hz frame front ends expose 228 visible lines. Native full-height
examples therefore instantiate a renderer with `lines:=228`; they do not center
a 192-line raster inside synthetic visible borders. The maintained 228-line
profiles are currently:

- `all_five`
- `all_five_unofficial`
- `player_color`
- `multisprite`

All four return after exactly 228 visible lines and then use the PAL/SECAM
`component_to_overscan_handoff()` phase bridge before the calibrated 36-line
overscan interval. The bridge consumes cycles only; it does not add a visible
scanline.

Some timing-portable components are intentionally fixed-height composition
profiles rather than full-height renderer families: the 181-line score variants
and the 11-line score components remain useful inside explicit compositions.
`all_five_player_color_192` is still a separately cycle-scheduled fixed 192-line
profile; it must be genuinely generalized before it can have a native 228-line
example. Do not fake that conversion with visible padding.

Use emulator-backed timing tests for every new full-height profile. A component
that fits numerically can still have an incompatible entry/return phase.
