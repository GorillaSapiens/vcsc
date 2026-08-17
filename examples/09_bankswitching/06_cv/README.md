<!-- This file is covered under CC0-1.0. See examples/LICENSE.txt. -->

# CommaVid CV diagnostic

Builds a fixed 2K CommaVid CV cartridge with 1K of split-address cartridge RAM.
The diagnostic uses the common `cartram` qualifier to allocate all 1024 bytes,
checks DATA/BSS startup initialization and persistent writes at the beginning,
middle, and end of RAM, and displays `pass`/`FAIL` with `CV` underneath.

The RAM read port is `$F000-$F3FF`; the write port is `$F400-$F7FF`. The source
performs a real `STA $F400,Y` access, so the generated ROM also contains the
CV byte pattern recognized by Stella's mapper autodetector.

Run `make play` to launch the image in Stella.
