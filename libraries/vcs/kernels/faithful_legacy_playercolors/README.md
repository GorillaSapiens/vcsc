```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Faithful retained legacy player-color baseline

This profile is a compatibility baseline, not a redesigned gameplay component.
It selects the retained NTSC standard-kernel branches for P0, P1, Ball, per-row
player colors, and the integrated six-digit score. It preserves the original
unofficial opcodes, instruction order, monolithic frame ownership, selected RAM
aliases, zero-page playfield accesses, and branch page-cross timing.

Instantiate it after `vcs.c26`:

```vcsc
template "kernels/faithful_legacy_playercolors/faithful_legacy_playercolors.c26" as legacy
```

The application supplies RAM-backed `legacy_playfield[48]`, page-contained
graphics and color tables, initializes the instance state, and repeatedly calls
`legacy_drawscreen()`. Build with `-Wa,--illegals` and
`faithful_legacy_playercolors.cfg`.

Three stock aliasing rules are part of the source contract:

```text
player0colorstore = missile0x
player0color      = missile0height/missile0y
player1color      = missile1height/missile1y
```

Consequently, disabled missile height/Y fields must be initialized before the
color-table pointers. Writing them afterward destroys those pointers. The
playfield must remain in RAM because the kernel deliberately uses wrapped
zero-page-indexed reads. Cycle-critical relative branches carry linker-visible
contracts directly on their opcodes: eleven use `.same`, while the terminal
visible-loop `BMI` uses `.cross` to retain the one extra cycle present upstream.
The linker chooses a satisfying low-byte phase; the profile no longer depends
on a magic `$83` code alignment.

`faithful_legacy_playercolors_reference.s26` is a separately linked
retained-source audit. It is not the independent oracle, but it now matches the
external pristine upstream BASIC 1.9 ROM positively: 1,230 visible TIA events,
20,064-cycle/264-raw-line frames, and 42 stable frames per ROM. The oracle and
its complete provenance live under
`test/oracles/pristine_basic_v1.9_playercolors/`.

This profile may be used as the faithful derivation baseline. Any later
transformation—template wrapping, score extraction, opcode legalization, object
extension, or line-budget change—must be introduced and proved separately.
