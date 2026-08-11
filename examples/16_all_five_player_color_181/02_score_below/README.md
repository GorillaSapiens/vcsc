```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Score below combined 181-line gameplay

The independent eleven-line centered six-digit score is drawn **below** the
181-line `all_five_player_color_181` gameplay component. The two components use
`vcs_ntsc_component_handoff()` at their visible boundary and together consume
exactly 192 visible scanlines.

| No. | Example | Purpose |
|---:|---|---|
| 01 | [`static`](01_static/) | Five-object scene with patterned P0/P1 row colors and fixed score `123456` |
