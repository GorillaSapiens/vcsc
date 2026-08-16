```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Linux package

The top-level `make linux` target builds a relocatable Linux distribution using
the native C and C++ toolchain. All seven VCSC host executables are linked
statically, then the normal installed runtime/support tree and editable examples
are staged beside them.

A successful build creates a timestamped archive named like:

```text
vcsc.linux.YYYYMMDD_HHMMSS.tar.gz
```

When the GitHub Actions package workflow is triggered by a tag, the release
asset uses the tag instead of the timestamp, for example `vcsc.linux.v0.1.0.tar.gz`.
Direct `make linux` builds remain timestamped.

The archive contains one `vcsc` directory with:

```text
vcsc/
  bin/       statically linked Linux command-line tools
  lib/       VCSC runtime archive
  include/   runtime include files
  share/     assembler configuration and Atari 2600 support files
  examples/  editable example cartridges
```

## Using the unpacked package

Unpack the archive and run the high-level driver directly from its `bin`
directory; no installation or PATH change is required:

```sh
tar -xzf vcsc.linux.YYYYMMDD_HHMMSS.tar.gz
cd vcsc
./bin/vcsc -V
./bin/vcsc -I share/vcs examples/01_basic/01_blank_screen/blank_screen.c26 -o blank_screen.bin
./bin/vcsc-disas blank_screen.bin
```

The driver locates `vcsc-cc1`, `vcsc-as`, `vcsc-ld`, the runtime archive, and
the installed support tree relative to `bin/vcsc`, so the whole directory may
be moved after unpacking.

The packaged example Makefiles are rewritten to use `bin/vcsc` and `share/vcs`
inside the package tree, so a Linux user with GNU make can build the examples
without a VCSC installation.

## Building the package

The build host needs the ordinary VCSC build tools: a C compiler, a C++
compiler, GNU make, `bison`, `flex`, `strip`, `readelf`, and `tar`. It also needs
the static versions of any host compiler runtimes required by the selected C/C++
toolchain.

On Void Linux, install the normal native development toolchain and parser tools
for the libc variant used by the host, then run:

```sh
make linux
```

The target recursively invokes the normal `tools` build with `LDFLAGS=-static`,
stages the package through `install-core`, strips the executables, and rejects
any resulting ELF executable that still contains a program interpreter or a
shared-library `NEEDED` entry. Before creating the archive it also runs the
staged driver and compiles the packaged blank-screen example as a relocatability
smoke test.

The defaults may be overridden with `LINUX_CC`, `LINUX_CXX`, `LINUX_STRIP`,
`LINUX_READELF`, `LINUX_TAR`, and `LINUX_LDFLAGS` make variables.
