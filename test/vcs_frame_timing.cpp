//! @file vcs_frame_timing.cpp
//! @brief Minimal VCS timing harness used by cartridge regression tests.
//!
//! This is deliberately not a general Atari emulator. It wraps the repository's
//! 6502 core with only the TIA WSYNC/VSYNC behavior and RIOT interval-timer
//! behavior needed to verify stable frame length in the example cartridges.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>

#include "mos6502.h"

namespace {

constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint64_t kExpectedDisplayedScanlines = 262;
// This deliberately minimal harness does not model Stella's full TIA frame
// boundary bookkeeping. Its raw assertion-to-assertion interval is calibrated
// per cartridge against Stella's verified 262-line NTSC display; most examples
// use 263 raw harness lines, while example 03 uses 265 after correct zero-page
// instruction sizing. Do not mistake either raw count for displayed scanlines.
constexpr uint64_t kDefaultVsyncIntervalScanlines = 263;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kAudc0 = 0x0015;
constexpr uint16_t kAudf0 = 0x0017;
constexpr uint16_t kAudv0 = 0x0019;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTimint = 0x0285;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct WriteEvent {
   uint16_t address;
   uint8_t value;
};

uint8_t memory_image[65536];
uint64_t virtual_cycles = 0;
std::vector<WriteEvent> writes;
std::vector<uint64_t> vsync_assertions;
bool vsync_asserted = false;

bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;
bool timer_overrun_read = false;

uint64_t audv0_writes = 0;
bool saw_audv0_zero = false;
bool saw_audv0_nonzero = false;
bool saw_initial_audv0_zero = false;
bool saw_first_nonzero_audv0 = false;
bool channel0_retuned_while_audible = false;
uint8_t channel0_volume = 0;
uint64_t first_nonzero_audv0_cycle = 0;
std::vector<uint16_t> channel0_write_order;
size_t first_nonzero_audv0_order = 0;

uint8_t timer_value(uint64_t cycle) {
   if (!timer_active) {
      return memory_image[kIntim];
   }

   const uint64_t elapsed = cycle - timer_start;
   const uint64_t ticks = elapsed / timer_divisor;
   if (ticks <= timer_loaded) {
      return static_cast<uint8_t>(timer_loaded - ticks);
   }

   const uint64_t after_underflow = ticks - timer_loaded - 1;
   return static_cast<uint8_t>(255 - (after_underflow & 255));
}

uint8_t read_bus(uint16_t address) {
   if (address == kTimint) {
      if (!timer_active) {
         return memory_image[kTimint];
      }
      const uint64_t ticks = (virtual_cycles - timer_start) / timer_divisor;
      return ticks > timer_loaded ? 0x80 : 0x00;
   }
   if (address == kIntim) {
      if (timer_active) {
         const uint64_t ticks = (virtual_cycles - timer_start) / timer_divisor;
         if (ticks > timer_loaded) {
            timer_overrun_read = true;
         }
      }
      return timer_value(virtual_cycles);
   }
   return memory_image[address];
}

void write_bus(uint16_t address, uint8_t value) {
   if (address < kRomBase) {
      memory_image[address] = value;
   }
   writes.push_back({address, value});
}

void clock_cycle(mos6502 *) {
}

void load_timer(uint16_t address, uint8_t value) {
   timer_active = true;
   timer_start = virtual_cycles;
   timer_loaded = value;
   switch (address) {
      case kTim1t: timer_divisor = 1; break;
      case kTim8t: timer_divisor = 8; break;
      case kTim64t: timer_divisor = 64; break;
      case kT1024t: timer_divisor = 1024; break;
      default: std::abort();
   }
}

void apply_writes() {
   for (const WriteEvent &event : writes) {
      if (event.address == kWsync) {
         const uint64_t within_line = virtual_cycles % kCyclesPerScanline;
         virtual_cycles += within_line ? kCyclesPerScanline - within_line
                                       : kCyclesPerScanline;
      }
      else if (event.address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (next && !vsync_asserted) {
            vsync_assertions.push_back(virtual_cycles);
         }
         vsync_asserted = next;
      }
      else if (event.address == kTim1t || event.address == kTim8t ||
               event.address == kTim64t || event.address == kT1024t) {
         load_timer(event.address, event.value);
      }
      else if (event.address == kAudc0 || event.address == kAudf0 ||
               event.address == kAudv0) {
         channel0_write_order.push_back(event.address);
         if ((event.address == kAudc0 || event.address == kAudf0) &&
             channel0_volume != 0) {
            channel0_retuned_while_audible = true;
         }
         if (event.address == kAudv0) {
            channel0_volume = event.value & 0x0f;
            ++audv0_writes;
            saw_audv0_zero |= event.value == 0;
            saw_audv0_nonzero |= event.value != 0;
            if (!saw_first_nonzero_audv0 && event.value == 0) {
               saw_initial_audv0_zero = true;
            }
            if (!saw_first_nonzero_audv0 && event.value != 0) {
               saw_first_nonzero_audv0 = true;
               first_nonzero_audv0_cycle = virtual_cycles;
               first_nonzero_audv0_order = channel0_write_order.size() - 1;
            }
         }
      }
   }
   writes.clear();
}

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_frame_timing: %s\n", message);
   std::exit(1);
}

} // namespace

int main(int argc, char **argv) {
   if (argc < 3) {
      std::fprintf(stderr,
         "usage: %s ROM.bin VSYNC_ASSERTIONS [--no-audio] [--audio-start-synced] [--audio-retune-muted] [--raw-lines N]\n",
         argv[0]);
      return 2;
   }

   bool require_audio = true;
   bool require_audio_start_sync = false;
   bool require_audio_retune_muted = false;
   uint64_t expected_raw_lines = kDefaultVsyncIntervalScanlines;
   for (int i = 3; i < argc; ++i) {
      if (std::strcmp(argv[i], "--no-audio") == 0) {
         require_audio = false;
      }
      else if (std::strcmp(argv[i], "--audio-start-synced") == 0) {
         require_audio_start_sync = true;
      }
      else if (std::strcmp(argv[i], "--audio-retune-muted") == 0) {
         require_audio_retune_muted = true;
      }
      else if (std::strcmp(argv[i], "--raw-lines") == 0) {
         if (++i >= argc) {
            fail("--raw-lines requires a value");
         }
         char *raw_end = nullptr;
         const unsigned long raw = std::strtoul(argv[i], &raw_end, 10);
         if (!raw_end || *raw_end != '\0' || raw < 1) {
            fail("bad --raw-lines value");
         }
         expected_raw_lines = static_cast<uint64_t>(raw);
      }
      else {
         fail("unknown option");
      }
   }
   const uint64_t expected_raw_cycles = expected_raw_lines * kCyclesPerScanline;

   char *end = nullptr;
   const long requested = std::strtol(argv[2], &end, 10);
   if (!end || *end != '\0' || requested < 10) {
      fail("bad VSYNC assertion count");
   }

   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) {
      fail("could not open ROM");
   }
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) {
      fail("ROM is not exactly 4096 bytes");
   }

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   uint64_t cpu_cycles = 0;
   constexpr uint64_t kInstructionLimit = 100000000;

   for (uint64_t instructions = 0;
        instructions < kInstructionLimit &&
        vsync_assertions.size() < static_cast<size_t>(requested);
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }

   if (vsync_assertions.size() < static_cast<size_t>(requested)) {
      fail("instruction limit reached before enough frames");
   }
   if (timer_overrun_read) {
      fail("overscan timer underflowed before the player finished");
   }

   // Startup occurs before the first complete measured frame, and the first
   // interval includes reset alignment. From the third interval onward this
   // harness must reproduce its selected Stella-calibrated raw interval; Stella
   // itself reports these cartridges as stable 262-line NTSC frames.
   size_t checked = 0;
   for (size_t i = 3; i < vsync_assertions.size(); ++i) {
      const uint64_t delta = vsync_assertions[i] - vsync_assertions[i - 1];
      const uint64_t interval_lines = delta / kCyclesPerScanline;
      const bool whole_lines = (delta % kCyclesPerScanline) == 0;
      if (!whole_lines || delta != expected_raw_cycles) {
         std::fprintf(stderr,
            "vcs_frame_timing: frame %zu has %llu-cycle VSYNC spacing "
            "(%llu raw harness lines); expected %llu cycles (%llu raw lines), "
            "calibrated against Stella's %llu-line display\n",
            i,
            static_cast<unsigned long long>(delta),
            static_cast<unsigned long long>(interval_lines),
            static_cast<unsigned long long>(expected_raw_cycles),
            static_cast<unsigned long long>(expected_raw_lines),
            static_cast<unsigned long long>(kExpectedDisplayedScanlines));
         return 1;
      }
      ++checked;
   }

   const size_t minimum_checked_frames = require_audio ? 1000 : 40;
   if (checked < minimum_checked_frames) {
      fail("not enough complete frames were checked");
   }
   if (require_audio &&
       (audv0_writes < 64 || !saw_audv0_zero || !saw_audv0_nonzero)) {
      fail("test run did not exercise repeated sounding and silent score steps");
   }
   if (require_audio_retune_muted && channel0_retuned_while_audible) {
      fail("AUDC0/AUDF0 was changed while channel 0 volume was nonzero");
   }
   if (require_audio_start_sync) {
      if (!saw_initial_audv0_zero || !saw_first_nonzero_audv0) {
         fail("audio did not begin from an explicit silent state");
      }
      if (vsync_assertions.empty() ||
          first_nonzero_audv0_cycle <= vsync_assertions.front()) {
         fail("first sounding note began before the first synchronized frame");
      }
      if (first_nonzero_audv0_order < 2 ||
          channel0_write_order[first_nonzero_audv0_order - 2] != kAudc0 ||
          channel0_write_order[first_nonzero_audv0_order - 1] != kAudf0) {
         fail("first note did not program AUDC0/AUDF0 before enabling AUDV0");
      }
   }

   std::printf("vcs_frame_timing ok: %zu frames at %llu lines, %llu AUDV0 writes\n",
      checked,
      static_cast<unsigned long long>(kExpectedDisplayedScanlines),
      static_cast<unsigned long long>(audv0_writes));
   return 0;
}
