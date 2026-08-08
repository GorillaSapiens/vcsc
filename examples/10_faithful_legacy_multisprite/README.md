```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Faithful legacy multisprite examples

This group exercises the narrow unbanked/non-Superchip faithful baseline for
the retained legacy multisprite renderer.  The baseline multiplexes five
logical sprites through P1 while P0 remains independent, and it retains the
original integrated score, playfield, RAM layout, frame timing, stack tricks,
and unofficial opcode policy.

The first example is intentionally a fixed diagnostic.  It establishes a
known-good behavioral reference before roadmap item 28 introduces a normal
stack-safe VCSC game-logic boundary into the renderer's historical 26-byte
application window.

Because this profile retains a stable/common-NMOS unofficial opcode, its
Makefile visibly uses `-Wa,--illegals`.

See
`../../libraries/vcs/renderers/faithful_legacy_multisprite/README.md` for the
exact 122-byte state / six-byte hardware-stack contract and the normalization
provenance.
