```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Unofficial-opcode score below gameplay

The interactive example draws the 181-line `player_color_181_unofficial`
gameplay component first, calls `vcs_ntsc_component_handoff()`, then draws the
11-line six-glyph score. The combined visible field is exactly 192 lines. Its
Makefile enables the assembler's unofficial-opcode table with
`-Wa,--illegals`.

| No. | Example | Purpose |
|---:|---|---|
| 01 | [`interactive`](01_interactive/) | Full-range P0/P1/Ball positioning and per-digit score editing |
