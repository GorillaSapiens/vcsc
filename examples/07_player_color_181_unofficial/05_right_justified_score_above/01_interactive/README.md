```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# player_color_181_unofficial right-justified six-digit score above

This cartridge composes the 11-line right-justified six-digit score before the 181-line
`player_color_181_unofficial` gameplay renderer, with `vcs_ntsc_component_handoff()` at the
boundary. The visible field is exactly 192 lines.

It starts with score `123456` at the right edge and the established certification positions for
P0, P1, and Ball.

## Controls

- Game Select cycles the selected gameplay object. The left joystick moves the selected object in X/Y; Game Reset restarts through `$FFFC`.
- Use the right joystick to select and change decimal digits.

Build with `make`. The result is `player_color_181_unofficial_right_justified_score_above_interactive.bin`.
