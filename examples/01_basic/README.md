```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Basic cartridges and components

These examples do not share one gameplay renderer. They introduce the toolchain
and the lifecycle-component model in small, independently understandable steps.

| No. | Example | Display architecture |
|---:|---|---|
| 01 | [`blank_screen`](01_blank_screen/) | Inline 262-line NTSC frame with a constant background |
| 02 | [`ode_to_joy`](02_ode_to_joy/) | Inline frame scheduler plus TIA audio updates during overscan |
| 03 | [`score`](03_score/) | `frame_ntsc.c26` composed with the 11-line `six_glyph_component.c26` |
| 04 | [`fingerprint`](04_fingerprint/) | The same frame and score components displaying a computed hexadecimal value |

The score and fingerprint examples demonstrate component composition rather than
a full gameplay renderer. They own the surrounding blank visible lines and call
the six-glyph component at its calibrated entry phase.
