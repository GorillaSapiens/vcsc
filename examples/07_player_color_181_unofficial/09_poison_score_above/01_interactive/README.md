```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# player_color_181_unofficial hostile poison diagnostic band above

This cartridge composes the 11-line hostile poison diagnostic band before the 181-line
`player_color_181_unofficial` gameplay renderer, with `vcs_ntsc_component_handoff()` at the
boundary. The visible field is exactly 192 lines.

It starts with an 11-line red diagnostic band that leaves hostile P0/P1 state and the established certification positions for
P0, P1, and Ball.

## Controls

- Game Select cycles the selected gameplay object. The left joystick moves the selected object in X/Y; Game Reset restarts through `$FFFC`.
- The poison component has no score controls; it exists to prove the adjacent gameplay renderer rebuilds its own state.

Build with `make`. The result is `player_color_181_unofficial_poison_score_above_interactive.bin`.
