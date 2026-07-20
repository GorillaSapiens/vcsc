```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Legacy Atari 2600 BASIC kernel source snapshot

This directory retains an upstream Atari 2600 BASIC kernel source snapshot as
reference material for VCSC conversion and integration work.

The import corresponds to upstream version 1.9 and contains text/source kernel
assets only. See `LICENSE.txt` for the exact upstream licensing overview and
license texts.

Layout:

- `common/` — shared VCS headers and assembly includes
- `standard/` — standard kernel and support routines/subkernels
- `multisprite/` — multisprite kernel and related helpers
- `dpcplus/` — DPC+ kernel-side text/source assets
- `pxe/` — PXE kernel-side text/source assets

The language/compiler source described by the retained license overview is not
part of VCSC. The retained 6507 assembly material is covered by the CC0 portion
of that overview. Opaque ARM/custom binary artifacts are intentionally absent;
see `OMITTED-UPSTREAM-ARTIFACTS.txt`.
