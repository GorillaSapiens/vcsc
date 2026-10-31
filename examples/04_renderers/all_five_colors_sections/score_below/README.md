```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# Combined colours: score below

```sh
make play
```

Controls, configuration and the supported fixed layout are the same as
[`score_above`](../score_above/). RAM **122/128**, including eleven stack bytes;
ordinary 8K F8 ROM and one drawing bank, with no mirrored graphics.

Gameplay returns after its final WSYNC. The application then performs a
three-cycle handoff, draws the independent eleven-line score, and starts overscan.
Conceptually:

```vcsc
game_draw();
vcs_ntsc_component_handoff();
score_draw();
vcs_ntsc_begin_overscan();
```

To fit the two-row layout in one drawing bank, the score is physically stored
before gameplay in ROM. The example uses a three-cycle `JMP` to its entry in
place of the standard three-cycle `BIT` handoff. Entry remains cycle3; no extra
call, callback, scanline or drawing bank is introduced. Routing jumps before
VBLANK ends and after overscan starts are absorbed by the existing timers.
An incorrectly delayed jump handoff is rejected by an exact-RGB mutation test.
The older coupled-terminal fixture remains checked but is not used here.

This remains a bounded NTSC preview, not a general combined renderer. Heights
are even/nonnegative, total176, first section nonempty and eighth at least158.
Boundaries are restricted to2/4/6/8/10/12/14/16/18. Default geometry is
`2,2,2,2,2,6,2,158`, including adjacent16/18 boundaries. Older layouts still work.
