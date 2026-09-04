```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

## FC (Amiga Power Play)

`VCS_FC_BANKS` selects 1 through 256 physical 4K ROM banks, for cartridge
sizes from 4K through 1 MiB.  Every bank maps the same `$F000-$FFFF` CPU/link
window.  FC maintains a pending selector: writes to `$1FF8` supply the low two
bank bits, writes to `$1FF9` supply the remaining bits, and a read or write of
`$1FFC` commits the pending bank.  Reset starts in physical bank 0.

VCSC's bank-call descriptor is the physical bank number.  The replicated
trampoline stages the destination descriptor, commits it at `$1FFC`, calls the
remote target, and stages/commits the baked source descriptor on return.  The
three-byte inline bank-call ABI therefore needs no PC-to-bank decoding and no
per-target JSR table, and nested cross-bank calls restore banks LIFO.
