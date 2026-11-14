# Stella RawStream to PNG

`rawstream2png` is a standalone C++17 converter, not a Stella plugin or patch.
It reads upstream RawStream version1 (`docs/rawstream.md` in Stella), using
recorded frame identities and palettes. No Stella sources or Python are needed.

## Build and use

Requires a native C++17 compiler, GNU make, pkg-config and libpng development
files (Debian/Ubuntu: `build-essential pkg-config libpng-dev`).

```sh
make -C test/rawstream2png
stella -rawstream capture.raw game.bin
test/rawstream2png/rawstream2png --input capture.raw --list
test/rawstream2png/rawstream2png --input capture.raw \
    --frames '1,5-10,12' --output-dir frames --prefix test_
test/rawstream2png/rawstream2png --input capture.raw --all --output-dir all-frames
```

Selections are inclusive decimal uint32 frame numbers, including0. Commas combine
single numbers and ranges; overlaps are merged. Empty terms, signs, whitespace,
descending ranges and overflow fail with diagnostics. Names use at least eight
decimal digits (`test_00000012.png`), not stream positions or display counts.
Existing files and repeated selected identities (for example after rewind) fail
rather than overwrite. `--list` reports ROM/version/TV/audio-clock metadata, frame
number, 64-bit CPU cycles, scanline count, first displayed scanline, dimensions,
audio sample count and associated RIOT RAM when present, plus jumps.

PNGs retain native160-pixel width and the frame's actual recorded height. They
use the current256-entry RGB palette verbatim: no scaling, interpolation, colour
normalization, crop, viewport padding or TV effects are added. Palette/header
changes, NTSC/PAL/SECAM and extended v1 payloads are supported. Unknown chunks
are skipped incrementally. Unsupported versions, absent headers/palettes,
malformed/truncated records and missing selected identities fail explicitly.
Input is processed one chunk/frame at a time; recordings are never loaded whole.
libpng writes deterministic indexed RGB PNGs without timestamps. PNGs are closed
before atomic, non-overwriting publication; partial writes never appear as PNGs.

Ordinary files must have a normal `END ` chunk. A writer error or a force-stopped
Stella does not produce one. Explicit live mode supports that distinction:

```sh
test/rawstream2png/rawstream2png --input capture.raw --frames '200-239' \
    --output-dir frames --follow --finish-selected --timeout 60 --max-bytes 536870912
```

This waits for complete chunks and returns only after **all** requested frame
identities have been exported. It does not require an `END ` after that point;
it never accepts an incomplete selected frame. Without `--finish-selected`, a
live reader still waits for `END `. Timeout is an overall deadline, not a retry
budget per frame. `--max-bytes` bounds consumed input; standalone offline use is
unlimited by default. Known records/dimensions have separate allocation limits.

## Shared regression capture

`test/stella_test_lib.pl` provides the list-valued
`vcsc_stella_capture_launcher($repo,$stella)`. Existing tests keep their original
deterministic Stella arguments, palette isolation, Xvfb reservations, frame
numbers, process management, snapshot deadlines and visual assertions:

```perl
my @command = (vcsc_stella_capture_launcher($repo,$stella),
   vcsc_stella_palette_args($repo,$user),
   '--capture-frames','200-239','--capture-dir',$snap,
   # ...original Stella arguments..., ROM);
```

The private adapter `test/stella_rawstream_capture.pl` consumes these two VCSC
options; they are **not** Stella options. It launches Stella with `-rawstream`
and runs the converter concurrently against a unique regular file. No unsupported
emulator frame-limit option is assumed. On completing the selection it terminates
and reaps Stella's process group, removes the successfully converted recording,
and publishes the complete selected PNG set. A shared60-second deadline and
512MiB recording cap bound failure; TERM/KILL cleanup handles interruption.
Builds are serialized across parallel callers with a lock in this directory.

Failures distinguish Stella exit, converter errors, timeout and growth limits;
recordings and converter logs remain under `snap/rawstream-*/`. The existing
snapshot waiter surfaces the failure marker immediately. The generic test runner
now retains its temporary directory on failure and removes it on success. To
reproduce, rerun the failed test using its printed command and retained directory,
or invoke the converter manually on the retained recording. A force-stopped
recording requires explicit live/finish-selected mode to salvage complete frames;
missing frames still fail. Tests compare actual decoded pixels, not just files.

Historical screenshot oracles use doubled-X320 coordinates. The explicit
`decode_stella_rgb`/`--stella-raster` assertion adapter duplicates each native RGB
pixel in memory only, preserving every existing exact assertion and pinned digest.
It rejects a non-native-width capture. The converter and its PNGs never scale.
Tests with native-coordinate oracles directly use160, and the ordinary PNG
decoder remains dimension-preserving. Reviewed PNG references are unchanged.

## Migration inventory and verification

The former selected-screenshot callers now all use the adapter:

| Drivers under `test/` | Preserved selection / coverage |
|---|---|
| `vcs_bankswitching_diagnostic.pl`, `vcs_3f_3e.pl`, `vcs_dpc.pl`, `vcs_e0.pl`, `vcs_fa2.pl`, `vcs_fe.pl`, `vcs_wd.pl` | Frame200; mapper results/text, startup banks and controller cases |
| `vcs_all_five_player_color_181_stella.pl`, `vcs_all_five_player_color_192_stella.pl`, `vcs_multisprite_stella.pl` | Frame200; pinned RGB, player/object edge extents |
| `vcs_six_glyph_wide_stella.pl`, `vcs_three_plus_three_score_stella.pl`, selected-frame heart compositions in `vcs_heart_score_stella.pl` | Frame200; unchanged score references/digests |
| `vcs_frame_50hz_stella.pl`, `vcs_video_standard_examples_stella.pl` | Frame200; native160x274 PAL/SECAM viewport |
| `vcs_layers_intro.pl`, `vcs_layers_sections.pl` | Frame200; intro/section exact RGB |
| `vcs_layers_all_five.pl`, `vcs_layers_examples.pl` | Frame200 or original requested consecutive range; independent all-pixel/edge/motion/score oracles, including their shards |
| `vcs_all_five_sections_probe.pl` | Frames200–215; all16 numbered frames |
| `vcs_all_five_sections_score_raster.pl`, `vcs_all_five_colors_sections_probe.pl` | Frames200–239; all40 numbered frames and existing raster/animation assertions |
| `vcs_all_five_colors_sections_score_live.pl` | Frames200–201; both numbered live-score frames |
| `vcs_all_five_colors_sections_example_stella.pl` | Frame200; example exact raster |

`vcs_stella_rawstream_contract.pl` replaces the former capability contract. It
requires actual RawStream support and captures deliberately alternating solid
frames200,201–203,205 twice, checking each native image's exact expected colour,
frame identity and deterministic PNG bytes. TIA writes stay inside VBLANK.
`rawstream2png_contract.pl` uses independent synthetic streams to check strict
selection, unknown/extended records, palettes and TV changes, metadata, collisions,
malformed/truncated/missing data, discontinuities, incremental delivery and timeout.
Normal e2e discovery includes both contracts; package CI runs the synthetic one.
`stella_rawstream_capture_contract.pl` additionally uses a fake producer to prove
process reaping, early emulator-exit diagnostics, retained malformed recordings,
non-overwriting publication and immediate propagation through the shared waiter.

Some separate interactive/reset/startup tests intentionally use upstream snapshot
key/sequence facilities; those were not selected-frame callers and remain intact.
The old addon patch is historical only and is not required by any migrated test.
No Stella source or documentation is modified by this migration. Unrelated
emulator mapper requirements are unchanged; report upstream deficiencies instead
of maintaining or patching Stella here.
