```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# player_color_181_unofficial independently positioned left/right two-plus-two score above

This cartridge composes the 11-line independently positioned left/right two-plus-two score before the 181-line
`player_color_181_unofficial` gameplay renderer, with `vcs_ntsc_component_handoff()` at the
boundary. The visible field is exactly 192 lines.

It starts with left field `12` at x=16 and right field `34` at x=104 and the established certification positions for
P0, P1, and Ball.

## Controls

- Game Select cycles the selected gameplay object. The left joystick moves the selected object in X/Y; Game Reset restarts through `$FFFC`.
- The bright field is selected. Right fire toggles left/right; right-joystick left/right moves the selected field (the right field reaches X=144, ending at the screen edge) and up/down changes its packed-BCD value.

Build with `make`. The result is `player_color_181_unofficial_two_plus_two_score_above_interactive.bin`.
