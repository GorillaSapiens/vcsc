```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Parameterized unofficial-opcode all-five renderer

`all_five_unofficial.c26` is the reviewed stable/common-NMOS experimental twin
of `../all_five/all_five.c26`. The required `lines` instantiation parameter
selects the same maintained visible profiles as the official renderer:

```vcsc
instantiate "renderers/all_five_unofficial/all_five_unofficial.c26" as game (lines:=192)
instantiate "renderers/all_five_unofficial/all_five_unofficial.c26" as game (lines:=181)
instantiate "renderers/all_five_unofficial/all_five_unofficial.c26" as game (lines:=170)
```

Assemble cartridges that instantiate it with `-Wa,--illegals`. No run-time
scanline counter or run-time profile switch is added; `lines` selects the timed
code at instantiation time.

## Profiles

| `lines` | Playfield | Typical composition | Component RAM |
| ---: | ---: | --- | ---: |
| 192 | 48 bytes / 12 rows | full-height, scoreless | 71 bytes |
| 181 | 44 bytes / 11 rows | one independent 11-line score above or below | 67 bytes |
| 170 | 40 bytes / 10 rows | independent 11-line scores above **and** below | 67 bytes |

The API, RAM layout, playfield contract, visible scanline count, TIA write
schedule, and application behavior match the corresponding official profile.
The only opcode-policy difference in each instantiated profile is one reviewed
stable/common-NMOS zero-page unofficial NOP (`$04`) replacing a same-size,
same-cycle dead-flag padding instruction during VBLANK positioning. No
silicon-sensitive or unstable opcode is used.

The 170-line profile composes as:

```text
11 score lines + 170 gameplay lines + 11 score lines = 192 visible lines
```

Adjacent visible components use `vcs_ntsc_component_handoff()` exactly as with
the official renderer.

## Maintained examples

- `examples/08_all_five_181_unofficial/` instantiates `lines:=181` with one score.
- `examples/12_all_five_170_unofficial/` instantiates `lines:=170` between an
  11-line score above and an 11-line score below.

The 192-line profile is regression-tested directly against the official
`lines:=192` profile at the visible-event and frame-timing levels.
