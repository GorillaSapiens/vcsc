```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# player_color_181_unofficial left-justified six-digit score below

This cartridge composes the 11-line left-justified six-digit score after the 181-line
`player_color_181_unofficial` gameplay renderer, with `vcs_ntsc_component_handoff()` at the
boundary. The visible field is exactly 192 lines.

It starts with score `123456` at the left edge and the established certification positions for
P0, P1, and Ball.

## Controls

- Game Select cycles the selected gameplay object. The left joystick moves the selected object in X/Y; Game Reset restarts through `$FFFC`.
- Right-joystick left/right selects a decimal digit and advances the score hue; up/down changes that digit.

Build with `make`. The result is `player_color_181_unofficial_left_justified_score_below_interactive.bin`.
