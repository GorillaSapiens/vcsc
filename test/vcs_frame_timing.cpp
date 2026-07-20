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
// Stella's status-line count for this non-interlaced kernel is one less than
// the whole-scanline interval between successive VSYNC assertions. Keep both
// quantities explicit so the regression does not repeat the old off-by-one.
constexpr uint64_t kExpectedVsyncIntervalScanlines =
   kExpectedDisplayedScanlines + 1;
constexpr uint64_t kExpectedVsyncIntervalCycles =
   kExpectedVsyncIntervalScanlines * kCyclesPerScanline;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kAudv0 = 0x0019;
constexpr uint16_t kIntim = 0x0284;
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
      else if (event.address == kAudv0) {
         ++audv0_writes;
         saw_audv0_zero |= event.value == 0;
         saw_audv0_nonzero |= event.value != 0;
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
   if (argc != 3 && argc != 4) {
      std::fprintf(stderr,
         "usage: %s ROM.bin VSYNC_ASSERTIONS [--no-audio]\n", argv[0]);
      return 2;
   }
   const bool require_audio = argc == 3;
   if (!require_audio && std::strcmp(argv[3], "--no-audio") != 0) {
      fail("unknown option");
   }

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
   // interval includes reset alignment. From the third interval onward the raw
   // assertion-to-assertion interval must be 263 whole scanlines, which Stella
   // displays as a 262-scanline frame for this kernel.
   size_t checked = 0;
   for (size_t i = 3; i < vsync_assertions.size(); ++i) {
      const uint64_t delta = vsync_assertions[i] - vsync_assertions[i - 1];
      const uint64_t interval_lines = delta / kCyclesPerScanline;
      const bool whole_lines = (delta % kCyclesPerScanline) == 0;
      const uint64_t displayed_lines = interval_lines > 0 ? interval_lines - 1 : 0;
      if (!whole_lines || delta != kExpectedVsyncIntervalCycles) {
         std::fprintf(stderr,
            "vcs_frame_timing: frame %zu has %llu-cycle VSYNC spacing "
            "(%llu whole lines, %llu Stella-displayed lines); expected %llu cycles "
            "(%llu/%llu lines)\n",
            i,
            static_cast<unsigned long long>(delta),
            static_cast<unsigned long long>(interval_lines),
            static_cast<unsigned long long>(displayed_lines),
            static_cast<unsigned long long>(kExpectedVsyncIntervalCycles),
            static_cast<unsigned long long>(kExpectedVsyncIntervalScanlines),
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

   std::printf("vcs_frame_timing ok: %zu frames at %llu lines, %llu AUDV0 writes\n",
      checked,
      static_cast<unsigned long long>(kExpectedDisplayedScanlines),
      static_cast<unsigned long long>(audv0_writes));
   return 0;
}
