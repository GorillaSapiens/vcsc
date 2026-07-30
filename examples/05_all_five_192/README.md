```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# `all_five_192` example

This group demonstrates the official-opcode, scoreless 192-line all-five renderer. It draws P0, P1, M0, M1, and Ball over twelve 16-line playfield rows. P0 and P1 retain independent solid colors; the missile updates occupy the timing slots used for per-row player colors in the player-color renderer.

| No. | Example | Purpose |
|---:|---|---|
| 01 | [`interactive`](01_interactive/) | Select and move each of the five TIA objects through its full X/Y range |
