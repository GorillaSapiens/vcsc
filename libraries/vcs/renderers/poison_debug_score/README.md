```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Poison debug score renderer

`poison_debug_score.c26` is an adversarial eleven-visible-line score-profile
component for finding hidden TIA-state coupling. It renders a bright red
diagnostic band and leaves deterministic hostile P0/P1 color, graphics,
reflection, vertical-delay, copy/size, coarse-position, fine-motion, and HMOVE
state.

Instantiate it after `vcs.c26`:

```c
template "renderers/poison_debug_score/poison_debug_score.c26" as poison
```

The component uses one public RAM byte:

```c
poison_exit_background := VCS_NTSC_DARK_BLUE;
```

It restores that background before returning, so red is confined to its own
band. `poison_draw()` consumes exactly eleven visible scanlines and returns at
cycle zero. Use `vcs_ntsc_component_handoff()` before invoking another visible
component.

The poison renderer owns and trashes P0/P1 state because an actual score
mini-renderer owns those resources. It deliberately preserves playfield,
missiles, and Ball geometry. Before its HMOVE it zeros HMM0, HMM1, and HMBL, so
its hostile player motion cannot move those preserved objects. It never owns
VSYNC, VBLANK, a RIOT timer, CXCLR, a score value, or a font.

The patterns are fixed rather than random. A failure must reproduce on the next
run, not vanish because the fuzzer rolled a friendlier number.
