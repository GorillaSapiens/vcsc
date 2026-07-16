# batari Basic kernel import

This directory vendors the current batari Basic Atari 2600 kernel source tree into
`libraries/vcs` as upstream reference material for extension and integration work.

Upstream source:
- official GitHub home: `batari-Basic/batari-Basic`
- imported from upstream `master` / version `1.9`
- see `LICENSE.txt` in this directory for upstream licensing details

Layout:
- `common/` ... shared VCS headers and common assembly includes used by multiple kernels
- `standard/` ... standard kernel and closely related support routines/subkernels
- `multisprite/` ... multisprite kernel and related helpers
- `dpcplus/` ... DPC+ kernel-side text/source assets
- `pxe/` ... PXE kernel-side text/source assets

Important licensing note:
- batari Basic's top-level language/compiler source is GPLv2.
- batari Basic's included 6507 assembly code is documented upstream as CC0.
- This vendor subtree is intended to preserve upstream provenance and licensing notices,
  not to silently relicense anything.

Important scope note:
- This import intentionally focuses on text/source kernel assets.
- Upstream also ships opaque `.arm` blobs and other packaged binary artifacts used by
  some advanced kernels. Those are not mirrored here as source code.
- In particular, `DPCplus.arm`, `PXE-pre.arm`, `PXE-post.arm`, `PXE_CC_pre.arm`,
  `PXE_CC_post.arm`, and `custom/bin/custom2.bin` remain upstream artifacts outside
  this text/source import.
