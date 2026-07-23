```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Private VCS regression cartridges

These cartridges are test fixtures, not user-facing examples. Exact code-size,
map, timing, raster, palette, and motion assertions may depend on their contents.

The corresponding files under `examples/` are deliberately editable. Tests may
build the examples as smoke tests, but must not duplicate their literal colors,
positions, graphics, music, score, or motion values in a golden harness. When an
exact cartridge contract is needed, update or add a fixture here instead.
