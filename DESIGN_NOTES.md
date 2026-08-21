```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# vcsc-as Design Notes

## Conditional-branch length and page timing

The eight 6502 relative conditional branches have two independent concerns:

1. whether the final instruction remains a two-byte relative branch or is
   relaxed into a synthesized long sequence; and
2. if a relative branch is emitted, whether its taken path crosses a page.

`vcsc-as` synthesizes a long conditional branch by inverting the condition and
branching around an absolute `JMP`:

```asm
    beq @skip
    jmp target
@skip:
```

For the original condition, the four concrete false/true timing outcomes are:

| Emitted form | False path | True path |
|---|---:|---:|
| short, taken path stays on-page | 2 | 3 |
| short, taken path crosses a page | 2 | 4 |
| long, internal skip stays on-page | 3 | 5 |
| long, internal skip crosses a page | 4 | 5 |

The current source contracts are sufficient:

- `.same` requires a short relative branch whose taken path stays on-page;
- `.cross` requires a short relative branch whose taken path crosses a page;
- `.flex`, and a bare conditional branch, permit normal relaxation and impose no
  page relationship.

We considered adding forced-long forms, including separate contracts for the
internal skip remaining on-page or crossing a page. We decided not to add them.
Long conditional sequences are primarily compiler-generated. A programmer
writing assembly who deliberately wants a long form can spell the inverted
branch and `JMP` explicitly, applying `.same` or `.cross` to the local skip when
its timing matters. That is clearer than expanding the annotation vocabulary and
gives the author direct control over labels, layout, bytes, and timing.
