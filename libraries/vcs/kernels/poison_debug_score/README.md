```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Poison debug score kernel

`poison_debug_score.c26` is an adversarial eleven-visible-line component for
finding hidden TIA-state coupling.  It has the same lifecycle shape and visible
height as the current centered score mini-kernel, but it deliberately renders a
red diagnostic band and exits with deterministic hostile playfield, player,
missile, Ball, reflection, vertical-delay, size/copy, position, and HMOVE state.

Instantiate it after `vcs.c26`:

```c
template "kernels/poison_debug_score/poison_debug_score.c26" as poison
```

It owns no RAM, score value, font, frame register, RIOT timer, or collision-latch
clear.  `poison_draw()` consumes exactly eleven visible scanlines and returns at
cycle zero of the following line.  The exit state is intentionally *not* a
normal component handoff guarantee; the whole point is to force the following
component to establish every TIA register and position it actually requires.

The patterns are fixed rather than random.  A failure must be reproducible on
the next run, not disappear because the fuzzer rolled a friendlier number.
