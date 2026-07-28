```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Score above gameplay

These examples draw the 11-line six-glyph score first, call
`vcs_ntsc_component_handoff()`, then draw the 181-line `player_color_181`
gameplay component. The combined visible field is exactly 192 lines.

| No. | Example | Motion |
|---:|---|---|
| 01 | [`static`](01_static/) | None |
| 02 | [`dynamic_x`](02_dynamic_x/) | Asynchronous horizontal P0, P1, and Ball motion |
| 03 | [`dynamic_xy`](03_dynamic_xy/) | Asynchronous horizontal and vertical P0, P1, and Ball motion |
