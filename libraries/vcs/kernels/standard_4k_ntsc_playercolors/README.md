```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Unbanked 4K NTSC P0+P1+BL per-row-color kernel

This directory defines a separate standard-kernel profile that restores the
retained legacy `playercolors` and `player1colors` behavior. It does **not**
change the existing `standard_4k_ntsc` all-five-object profile.

The trade is explicit:

- P0 and P1 each have an eight-entry color table;
- BL remains available;
- M0 and M1 are deliberately unavailable;
- the default asymmetric 48-byte ROM playfield and six-glyph decimal score
  remain available;
- the profile is NTSC, unbanked 4K, non-reflected, and non-Superchip.

The retained kernel is a two-scanline kernel. One sprite bitmap row and one
color-table entry therefore cover one **logical sprite row**, normally two
physical television scanlines. “Per-row color” does not mean an arbitrary
independent color on every physical scanline.

## Files

- `standard_4k_ntsc_playercolors.c26` — source-level state and API contract;
- `standard_4k_ntsc_playercolors_kernel.s26` — checked-in normalized kernel;
- `standard_4k_ntsc_playercolors_macros.inc` — assembler macros;
- `vcs_standard_4k_ntsc_playercolors.cfg` — matching 4K linker layout;
- `normalize.pl` — deterministic derivation from the maintained legal standard
  profile, guarded by the retained legacy player-color branches.

Run:

```sh
libraries/vcs/kernels/standard_4k_ntsc_playercolors/normalize.pl --check
```

The normalizer fails if the selected all-five base profile or the retained
legacy `playercolors` source relationship changes unexpectedly.

## Application contract

Include `vcs.c26`, provide the required page-contained ROM objects, then include
the profile contract:

```vcsc
include "vcs.c26"

page const uint8_t vcs_standard_color_playfield[48] := {
   // twelve rows, four bytes per row
};

include "kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors.c26"

page const uint8_t player0_graphics[8] := {
   VCS_STANDARD_COLOR_SPRITE_GLYPH(/* eight top-to-bottom rows */)
};
page const uint8_t player1_graphics[8] := {
   VCS_STANDARD_COLOR_SPRITE_GLYPH(/* eight top-to-bottom rows */)
};

page const uint8_t vcs_standard_color_player0_colors[8] := {
   VCS_STANDARD_COLOR_SPRITE_ROWS(/* eight top-to-bottom TIA colors */)
};
page const uint8_t vcs_standard_color_player1_colors[8] := {
   VCS_STANDARD_COLOR_SPRITE_ROWS(/* eight top-to-bottom TIA colors */)
};
```

The two color-table names are exact linker contracts. Both graphics objects and
both color objects must remain within one 256-byte page. Active table indices
are `0..height`; the supplied helpers reverse visible top-to-bottom source order
into the kernel's descending row-index order.

The public state is:

```vcsc
VCS_STANDARD_COLOR_PLAYER0_X
VCS_STANDARD_COLOR_PLAYER1_X
VCS_STANDARD_COLOR_BALL_X
vcs_standard_color_player0_y
vcs_standard_color_player1_y
vcs_standard_color_ball_y
vcs_standard_color_player0_graphics
vcs_standard_color_player1_graphics
vcs_standard_color_player0_height
vcs_standard_color_player1_height
vcs_standard_color_ball_height
vcs_standard_color_score
vcs_standard_color_score_color
vcs_standard_color_playfield_position
```

The public X range is `0..159`. The horizontal-position routine retains the
legacy five-strobe RESP/HMxx schedule; its two absent-missile slots are private
and forced to zero before every frame. Application code must not use the raw
`object_x[2]` and `object_x[3]` elements.

Build with the matching configuration and kernel:

```sh
vcsc -I libraries/vcs \
  -T libraries/vcs/kernels/standard_4k_ntsc_playercolors/vcs_standard_4k_ntsc_playercolors.cfg \
  game.c26 \
  libraries/vcs/kernels/standard_4k_ntsc_playercolors/standard_4k_ntsc_playercolors_kernel.s26 \
  -o game.bin
```

The profile assembles with the official NMOS 6502 opcode table; `--illegals` is
not used.

## Frame ownership and hook

The application calls:

```vcsc
extern void vcs_standard_color_kernel_drawscreen(void);
```

A strong application definition of:

```vcsc
void vcs_standard_color_overscan_hook(void);
```

overrides the kernel's weak no-op fallback. The hook runs after persistent P0,
P1, and BL Y state and the hardware stack pointer have been restored, with
`VBLANK` asserted and the overscan timer active. Changes apply to the next
frame. The hook must not recursively call drawscreen or write the kernel-owned
frame-control registers.

The player-color profile uses a VBLANK timer value one tick larger than the
all-five profile because its reduced ball-only mask preparation otherwise
shortens the frame by one scanline. The emulator regression locks the same
20,140-cycle harness period as the maintained standard profile.

## RAM and ROM cost

Module-declared RIOT RAM:

| State group | Bytes | Notes |
| --- | ---: | --- |
| Public P0/P1/BL state, graphics pointers, score | 17 | Application-visible |
| Private ghost X slots | 2 | Required by five-strobe horizontal schedule |
| Score/pointer workspace | 12 | Kernel-private |
| Playfield row state | 1 | Kernel-private |
| Sparse ball/final-row mask block | 44 | Kernel-private |
| Delayed P0 color latch | 1 | Kernel-private |
| **Total module RAM** | **77** | 17 public + 60 private |

The stock runtime uses eight RIOT bytes. The weak-hook static example has a
three-function call depth plus four explicit hidden-stack bytes, reserving ten
hardware-stack bytes. Its initialization activation occupies three bytes, so
the checked static cartridge leaves 30 RIOT bytes unallocated.

Measured linked 4K cartridges:

| Example | ROM used | ROM free |
| --- | ---: | ---: |
| `08_playercolor_static_test` | 1,827 bytes | 2,263 bytes |
| `09_playercolor_motion_test` | 2,759 bytes | 1,331 bytes |

These figures include application code, runtime, kernel, tables, and vectors.
They are measurements of the checked examples, not promises that future code
will retain identical addresses.

## Timing and validation

The visible loop replaces the two missile-update slots with balanced legal
loads and `COLUP0`/`COLUP1` writes. The final row is precomputed during VBLANK.
Both ENAM registers are cleared before the visible field and never enabled.

`test/vcs_standard_playercolors.test` verifies the kernel against private
golden cartridges under `test/fixtures/vcs_examples/`; the examples below are
smoke-built but their literal palettes, positions, and motion constants are not
part of the regression contract.

It verifies:

- deterministic normalization;
- assembly without unofficial opcodes;
- page placement of playfield, graphics, colors, code, and score table;
- measured RAM and stack contracts;
- exact frame period;
- exact eight-row P0 and P1 color sequences;
- exact P0/P1/BL raster rows;
- absence of visible missile enables;
- 320 frames of full-range asynchronous P0/P1/BL horizontal positioning,
  including RESP cycles and HMxx values.

The human-facing cartridges are:

- `examples/08_playercolor_static_test` — stationary P0 and P1, each with eight
  visibly distinct logical-row colors;
- `examples/09_playercolor_motion_test` — the same row colors while P0, P1, and
  BL move asynchronously through X=`0..159`.
