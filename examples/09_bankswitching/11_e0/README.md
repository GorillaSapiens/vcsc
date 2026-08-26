```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# E0 diagnostic

This 8K cartridge certifies the Parker Brothers E0 mapper. E0 divides the
cartridge window into four 1K segments. The first three are independently
selectable and the fourth is permanently physical bank 7:

```text
$1000-$13FF   $1FE0-$1FE7 select physical bank 0-7
$1400-$17FF   $1FE8-$1FEF select physical bank 0-7
$1800-$1BFF   $1FF0-$1FF7 select physical bank 0-7
$1C00-$1FFF   fixed physical bank 7
```

Power-on maps physical banks 4, 5, 6, 7. The self-test first verifies those
power-on mappings, then switches each selectable window through representative
physical banks and calls code resident in all eight physical 1K chunks. It
finally rechecks bank 7 to prove the fixed top segment did not move.

After the mapper self-test completes, the cartridge displays the same two-line
diagnostic presentation as the other bankswitch examples: a large `pass` or
`FAIL` result with a small `E0` label underneath. The background is green for
PASS and dark red for FAIL. Permanent startup/self-test control remains in E0's
fixed top 1K; after certification, display code occupies physical bank 0, glyph
data occupies physical bank 1, and component lifecycle helpers occupy physical
bank 2. The display fixes those three physical banks into E0's three selectable
windows and no longer changes them. VCSC stamps
`E0\0\0` at `$FFF8-$FFFB` in physical bank 7; RESET and IRQ/BRK vectors remain
at `$FFFC-$FFFF`.

Stella should be forced to E0 so the test does not depend on autodetection:

```sh
make play
```
