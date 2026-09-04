```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# E0 / Parker Brothers

E0 is physically eight 1K ROM banks.  The hardware can independently select
any physical bank into each of the three switchable 1K windows, but VCSC's
automatic-call ABI deliberately exposes only three relocation-safe states:

```text
state 0  [0,1,6,7]
state 1  [2,3,6,7]
state 2  [4,5,6,7]   hardware reset state
```

Physical banks 0/2/4 therefore have canonical origin `$1000`, banks 1/3/5 have
canonical origin `$1400`, bank 6 is always resident at `$1800`, and fixed bank
7 remains at `$1C00`.  Absolute code/data addresses never move between CPU
windows.

Banks 0/1 use bank-call descriptor 0, 2/3 use descriptor 1, and 4/5 use
descriptor 2.  Resident banks 6/7 use `$FF`, meaning that a call into the bank
must preserve whichever lower pair is currently selected.  Cross-state calls
select both lower windows together with `$1FE0-$1FE7` and `$1FE8-$1FEF`; return
restores the caller's pair.

Because resident bank 6 or 7 can make a nested cross-state call, physical bank
identity alone cannot recover the current lower pair.  `_vcsc_e0_state` is one
RIOT-RAM byte holding only the canonical state ID 0/1/2.  It initializes to 2,
matching E0 hardware reset.  This is not a shadow of the hardware's arbitrary
9-bit state: noncanonical selector arrangements are outside the automatic-call
ABI.

The replicated bank-call corridor reserves 112 bytes in each 1K physical bank.
`entry.s26` is intentionally empty because E0 hardware already starts in
`[4,5,6,7]`.  Handwritten accesses to E0 selector hotspots own mapper state and
must restore a canonical state and keep `_vcsc_e0_state` synchronized before
returning to automatic bank calls.
