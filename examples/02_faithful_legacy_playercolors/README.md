```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Faithful legacy player-color renderer example

This group demonstrates
`renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.c26`.
It is a compatibility baseline derived from the retained legacy implementation,
not a modern lifecycle component.

The renderer owns the complete frame, integrated six-digit score, P0, P1, Ball,
playfield, and per-row player colors. M0 and M1 are not independently available
in this player-color profile: their retained storage aliases player-color state
or a private positioning slot. Applications must build with `-Wa,--illegals`
and the renderer-specific linker configuration.

| No. | Example | Purpose |
|---:|---|---|
| 01 | [`interactive`](01_interactive/) | Move P0, P1, and Ball through their complete public coordinate ranges and edit every score digit |

For the full storage and timing contract, see
[`libraries/vcs/renderers/faithful_legacy_playercolors/README.md`](../../libraries/vcs/renderers/faithful_legacy_playercolors/README.md).
