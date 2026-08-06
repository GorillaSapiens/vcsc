```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

<!-- This file is covered under CC0-1.0. See libraries/LICENSE.txt. -->

# Legacy Atari 2600 BASIC renderer source snapshot

This directory retains an upstream Atari 2600 BASIC renderer source snapshot as
reference material for VCSC conversion and integration work.

The import corresponds to upstream version 1.9 and contains text/source renderer
assets only. Everything retained here is covered under the same CC0-1.0 policy
as the rest of `libraries/`; see `libraries/LICENSE.txt`.

Layout:

- `common/` — shared VCS headers and assembly includes
- `standard/` — standard renderer and support routines/subrenderers
- `multisprite/` — multisprite renderer and related helpers
- `dpcplus/` — DPC+ renderer-side text/source assets
- `pxe/` — PXE renderer-side text/source assets

The language/compiler source is not part of VCSC. Opaque ARM/custom binary
artifacts are intentionally absent; see `OMITTED-UPSTREAM-ARTIFACTS.txt`.
