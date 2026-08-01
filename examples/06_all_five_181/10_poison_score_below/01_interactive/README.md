```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# all_five_181 hostile poison diagnostic band below

This cartridge composes the 11-line hostile poison diagnostic band after the 181-line
`all_five_181` gameplay renderer, with `vcs_ntsc_component_handoff()` at the
boundary. The visible field is exactly 192 lines.

It starts with an 11-line red diagnostic band that leaves hostile P0/P1 state and the established certification positions for
P0, P1, M0, M1, and Ball.

## Controls

- Game Select cycles the selected gameplay object. The left joystick moves the selected object in X/Y; Game Reset restarts through `$FFFC`.
- The poison component has no score controls; it exists to prove the adjacent gameplay renderer rebuilds its own state.

Build with `make`. The result is `all_five_181_poison_score_below_interactive.bin`.
