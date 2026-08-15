```text
 __   __ ___  ___   ___
 \ \ / // __|/ __| / __|
  \ V /| (__ \__ \| (__
   \_/  \___||___/ \___|
```

# Windows package

The top-level `make windows` target cross-builds a 64-bit Windows distribution
from a Unix-like build host using MinGW-w64. The default cross prefix is
`x86_64-w64-mingw32` and may be changed with `WINDOWS_TRIPLET=...`.

The target intentionally builds the target-neutral VCSC runtime archive with
native bootstrap copies of `vcsc-as` and `vcsc-ar`, then recursively invokes the
normal `tools` target with the MinGW C/C++ compilers and static link flags. This
keeps the build host from trying to execute Windows PE tools while constructing
`libvcsc.l26`.

A successful build creates a timestamped archive named like:

```text
vcsc.windows.YYYYMMDD_HHMMSS.zip
```

When the GitHub Actions package workflow is triggered by a tag, the release
asset uses the tag instead of the timestamp, for example `vcsc.windows.v0.1.0.zip`.
Direct `make windows` builds remain timestamped.

The zip contains one `vcsc` directory with:

```text
vcsc/
  vcsc.cmd
  bin/       Windows command-line tools
  lib/       VCSC runtime archive
  include/   runtime include files
  share/     assembler configuration and Atari 2600 support files
  examples/  editable example cartridges
```

The executables are linked so they do not require MinGW `libgcc`, `libstdc++`,
or `libwinpthread` DLLs beside the package. Ordinary Windows system DLLs remain
normal operating-system dependencies.

## Using the unpacked package

From `cmd.exe` or PowerShell, change to the unpacked `vcsc` directory. The
`vcsc.cmd` wrapper runs the high-level driver without requiring installation or
a PATH change.

For example, in `cmd.exe`:

```bat
vcsc.cmd -I share\vcs examples\01_basic\01_blank_screen\blank_screen.c26 -o blank_screen.bin
```

In PowerShell:

```powershell
.\vcsc.cmd -I .\share\vcs .\examples\01_basic\01_blank_screen\blank_screen.c26 -o blank_screen.bin
```

The driver locates `vcsc-cc1.exe`, `vcsc-as.exe`, `vcsc-ld.exe`, the runtime
archive, and the installed support tree relative to `bin\vcsc.exe`, so the
whole directory may be moved after unpacking.

The packaged example Makefiles are rewritten to use `bin/vcsc.exe` and
`share/vcs` from the package tree. They still use the Unix-oriented commands in
the repository Makefiles (`rm`, `test`, `wc`, and GNU make syntax), so use them
under an environment such as MSYS2. Native Windows users do not need make to
invoke `vcsc.cmd` directly as shown above.

## Building the package

The build host needs the ordinary VCSC build tools (a native C compiler, `make`,
`bison`, and `flex`), a MinGW-w64 cross C compiler and C++ compiler, matching
binutils (`strip` and `objdump`), and `zip`. On a 64-bit Void Linux host, the
additional packages are normally installed with:

```sh
sudo xbps-install -S cross-x86_64-w64-mingw32 bison flex zip
```

With the default triplet, the cross tools must be available as:

```text
x86_64-w64-mingw32-gcc
x86_64-w64-mingw32-g++
x86_64-w64-mingw32-strip
x86_64-w64-mingw32-objdump
zip
```

Then run:

```sh
make windows
```

Alternative triplets and individual tools can be selected with the
`WINDOWS_TRIPLET`, `WINDOWS_CC`, `WINDOWS_CXX`, `WINDOWS_STRIP`, and
`WINDOWS_OBJDUMP` make variables.
