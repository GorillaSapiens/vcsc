```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# `all_five_181` examples

This group demonstrates the official-opcode 181-line all-five renderer composed with the independent 11-line score. Both layouts draw P0, P1, M0, M1, and Ball. P0 and P1 use independent solid colors.

| Layout | Draw order | Diagnostic |
|---|---|---|
| [`01_score_above`](01_score_above/) | score, handoff, gameplay | Five-object motion and six-digit score editing |
| [`02_score_below`](02_score_below/) | gameplay, handoff, score | Five-object motion and six-digit score editing |
