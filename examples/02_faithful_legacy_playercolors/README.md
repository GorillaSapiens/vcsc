```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Faithful legacy player-color renderer examples

This group demonstrates
`renderers/faithful_legacy_playercolors/faithful_legacy_playercolors.c26`.
It is a compatibility baseline derived from the retained legacy implementation,
not a modern lifecycle component.

The renderer owns the complete frame, integrated six-digit score, P0, P1, Ball,
playfield, and per-row player colors. It deliberately preserves unofficial
opcodes, instruction ordering, selected RAM aliases, wrapped zero-page
playfield reads, and branch-page timing. Applications must build with
`-Wa,--illegals` and the renderer-specific linker configuration.

| No. | Example | Purpose |
|---:|---|---|
| 01 | [`static`](01_static/) | Static public cartridge exercising the faithful compatibility profile |

For the full storage and timing contract, see
[`libraries/vcs/renderers/faithful_legacy_playercolors/README.md`](../../libraries/vcs/renderers/faithful_legacy_playercolors/README.md).
