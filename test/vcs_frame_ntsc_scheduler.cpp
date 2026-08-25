#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xf000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerLine = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTimint = 0x0285;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct WriteEvent { uint16_t address; uint8_t value; };
struct TimedWrite { uint64_t cycle; uint16_t address; uint8_t value; };
struct Timer {
   bool active = false;
   uint64_t start = 0;
   uint16_t divisor = 1;
   uint8_t loaded = 0;
   bool underflowed = false;
   bool interrupt_flag = false;
};

uint8_t memory_image[65536];
uint64_t virtual_cycles = 0;
std::vector<WriteEvent> pending_writes;
std::vector<uint64_t> vsync_assertions;
std::vector<uint64_t> vsync_deassertions;
std::vector<TimedWrite> vblank_writes;
std::vector<TimedWrite> timer_writes;
bool vsync_asserted = false;
Timer timer;

[[noreturn]] void fail(const std::string &message) {
   std::fprintf(stderr, "vcs_frame_ntsc_scheduler: %s\n", message.c_str());
   std::exit(1);
}

void sync_timer() {
   if (!timer.active || timer.underflowed) return;
   const uint64_t elapsed = virtual_cycles - timer.start;
   const uint64_t threshold = (uint64_t(timer.loaded) + 1) * timer.divisor;
   if (elapsed >= threshold) {
      timer.underflowed = true;
      timer.interrupt_flag = true;
   }
}

uint8_t current_timer_value() {
   if (!timer.active) return memory_image[kIntim];
   const uint64_t elapsed = virtual_cycles - timer.start;
   const uint64_t threshold = (uint64_t(timer.loaded) + 1) * timer.divisor;
   if (elapsed < threshold) {
      return static_cast<uint8_t>(timer.loaded - elapsed / timer.divisor);
   }
   return static_cast<uint8_t>(255 - ((elapsed - threshold) & 255));
}

uint8_t read_bus(uint16_t address) {
   if (address == kTimint) {
      sync_timer();
      return timer.interrupt_flag ? 0x80 : 0;
   }
   if (address == kIntim) {
      sync_timer();
      const uint8_t value = current_timer_value();
      timer.interrupt_flag = false;
      return value;
   }
   return memory_image[address];
}

void write_bus(uint16_t address, uint8_t value) {
   if (address < kRomBase) memory_image[address] = value;
   pending_writes.push_back({address, value});
}

void clock_cycle(mos6502 *) {}

void load_timer(uint16_t address, uint8_t value) {
   timer.active = true;
   timer.start = virtual_cycles;
   timer.loaded = value;
   timer.underflowed = false;
   timer.interrupt_flag = false;
   switch (address) {
      case kTim1t: timer.divisor = 1; break;
      case kTim8t: timer.divisor = 8; break;
      case kTim64t: timer.divisor = 64; break;
      case kT1024t: timer.divisor = 1024; break;
      default: std::abort();
   }
}

void apply_writes() {
   for (const WriteEvent &event : pending_writes) {
      if (event.address == kWsync) {
         const uint64_t within = virtual_cycles % kCyclesPerLine;
         virtual_cycles += within ? kCyclesPerLine - within : kCyclesPerLine;
      }
      else if (event.address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (!next && vsync_asserted) vsync_deassertions.push_back(virtual_cycles);
         if (next && !vsync_asserted) vsync_assertions.push_back(virtual_cycles);
         vsync_asserted = next;
      }
      else if (event.address == kVblank) {
         vblank_writes.push_back({virtual_cycles, event.address, event.value});
      }
      else if (event.address >= kTim1t && event.address <= kT1024t) {
         timer_writes.push_back({virtual_cycles, event.address, event.value});
         load_timer(event.address, event.value);
      }
   }
   pending_writes.clear();
}

const TimedWrite &find_vblank(uint64_t start, uint64_t end, uint8_t value,
                             size_t occurrence) {
   size_t seen = 0;
   for (const auto &event : vblank_writes) {
      if (event.cycle < start || event.cycle >= end || event.value != value) continue;
      if (seen++ == occurrence) return event;
   }
   fail("missing expected VBLANK write");
}

void check_mode(const std::string &mode, uint16_t flag_address) {
   uint64_t expected_lines = 264;
   uint8_t expected_flags = 0;
   uint64_t clear_offset = 40;
   uint64_t overscan_offset = 232;
   if (mode == "vblank-overrun") {
      expected_lines = 265;
      expected_flags = 1;
      clear_offset = 41;
      overscan_offset = 233;
   }
   else if (mode == "overscan-overrun") {
      expected_lines = 265;
      expected_flags = 2;
   }
   else if (mode != "normal" && mode != "boundary") {
      fail("unknown mode");
   }

   if (vsync_assertions.size() < 8 || vsync_deassertions.size() < 8) fail("too few frames");
   for (size_t i = 2; i + 1 < vsync_assertions.size(); ++i) {
      const uint64_t start = vsync_assertions[i];
      const uint64_t end = vsync_assertions[i + 1];
      if (end - start != expected_lines * kCyclesPerLine) {
         fail("wrong steady-state frame length in " + mode);
      }
      if (start % kCyclesPerLine != 8) fail("VSYNC assertion cycle changed");
      if (i >= vsync_deassertions.size() ||
          vsync_deassertions[i] - start != 3 * kCyclesPerLine) {
         fail("VSYNC pulse is not exactly three scanlines");
      }

      const auto &begin_vblank = find_vblank(start, end, 2, 0);
      const auto &end_vblank = find_vblank(start, end, 0, 0);
      const auto &begin_overscan = find_vblank(start, end, 2, 1);
      const uint64_t base_line = start / kCyclesPerLine;
      if (begin_vblank.cycle / kCyclesPerLine != base_line + 3 ||
          begin_vblank.cycle % kCyclesPerLine != 26) {
         fail("VBLANK begin schedule changed");
      }
      if (end_vblank.cycle / kCyclesPerLine != base_line + clear_offset ||
          end_vblank.cycle % kCyclesPerLine != 3) {
         fail("VBLANK end schedule changed");
      }
      if (begin_overscan.cycle / kCyclesPerLine != base_line + overscan_offset ||
          begin_overscan.cycle % kCyclesPerLine != 21) {
         fail("overscan begin schedule changed");
      }

      size_t loads = 0;
      for (const auto &event : timer_writes) {
         if (event.cycle < start || event.cycle >= end) continue;
         ++loads;
         if (event.address != kTim64t) fail("component touched a non-TIM64T timer start");
         if (loads == 1 && event.value != 42) fail("wrong VBLANK TIM64T preload");
         if (loads == 2 && event.value != 34) fail("wrong overscan TIM64T preload");
      }
      if (loads != 2) fail("wrong number of scheduler timer loads");
   }

   if (mode == "normal") {
      if (flag_address != 0xffff) fail("production ROM unexpectedly has diagnostics");
   }
   else {
      if (flag_address == 0xffff) fail("diagnostic ROM is missing flags");
      if (memory_image[flag_address] != expected_flags) fail("wrong sticky overrun flags");
   }
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 4) {
      std::fprintf(stderr, "usage: %s ROM MODE FLAG_ADDRESS_OR_NONE\n", argv[0]);
      return 2;
   }
   const std::string mode = argv[2];
   uint16_t flag_address = 0xffff;
   if (std::strcmp(argv[3], "none") != 0) {
      char *end = nullptr;
      const unsigned long value = std::strtoul(argv[3], &end, 0);
      if (!end || *end || value > 0xffff) fail("bad flag address");
      flag_address = static_cast<uint16_t>(value);
   }

   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) fail("ROM is not 4K");

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   uint64_t cpu_cycles = 0;
   constexpr uint64_t kInstructionLimit = 20000000;
   for (uint64_t instructions = 0;
        instructions < kInstructionLimit && vsync_assertions.size() < 10;
        ++instructions) {
      pending_writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   check_mode(mode, flag_address);
   std::printf("vcs_frame_ntsc_scheduler %s ok\n", mode.c_str());
   return 0;
}
