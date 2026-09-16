```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Pinned Stella palette

`stella.pal` is the VCSC test suite's canonical Stella user palette.  Stella's
user-palette format is one 792-byte file containing all three video standards
in this order:

* 384 bytes: 128 NTSC RGB triples
* 384 bytes: 128 PAL RGB triples
* 24 bytes: 8 SECAM RGB triples

The bytes are generated from the canonical `ntsc_palette`, `pal_palette`, and
`secam_palette` tables in `compiler/builtin_rgb.c`.  Do not edit this binary by
hand.  `test/stella_palette_contract.pl` reconstructs it from those tables and
locks both each standard's slice digest and the combined-file digest.

Every maintained Stella certification uses `test/stella_test_lib.pl`.  The
helper copies this file into that test run's private Stella basedir, selects
`-palette user`, and explicitly neutralizes palette adjustments, PAL color-loss,
TV filtering/phosphor blending, and TIA interpolation.  Reviewed Stella raster
references therefore use exact RGB for NTSC, PAL, and SECAM and do not depend
on the host Stella version's built-in palette or the user's saved settings.
