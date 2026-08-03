```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Bank-switching diagnostics

This group contains mapper-level diagnostic cartridges rather than gameplay
examples.  They deliberately exercise generated cross-bank JSR/RTS and direct
JMP bridges, reset from arbitrary initially selected banks, RIOT-RAM signatures,
and hardware-stack balance.

The source is parameterized so one editable cartridge produces six mapper
diagnostics—F8, F6, F4, F8SC, F6SC, and F4SC—plus a seventh deliberately
poisoned F8 image which renders the known FAIL result. Each mapper diagnostic
executes its complete ordered direct bank-transition matrix internally.
