# Transitional float runtime library

`libraries/float` contains the legacy builtin float runtime archive. Float types are not
part of the final Atari 2600 language and this directory is scheduled for removal in the
next feature-pruning slice.

`make` assembles `asm/*.s` and `asm/*.asm` into `float.a65`. The archive currently
contains binary16, binary32, and binary64 arithmetic/comparison helpers, including
little-endian entry points, legacy big-endian wrappers, and `_fcmp`. The driver may still
link this archive while transitional float tests remain.

The custom-float source generator, generated test archives, `$exactops`, weak
comparison operator members, and user-defined operator surface have been removed. No new code should
depend on this library.
