//! @file vcs_standard_kernel_legal_schedule.cpp
//! @brief Lock the legal steady ball/missile packed-mask schedule.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;
constexpr uint8_t kLsrZpX = 0x56;

struct WriteEvent { uint16_t address; uint8_t value; };
struct MaskEvent { uint64_t line; uint64_t cycle; uint8_t operand; };

uint8_t memory_image[65536];
uint64_t virtual_cycles = 0;
uint64_t cpu_cycles = 0;
std::vector<WriteEvent> writes;
std::vector<MaskEvent> mask_events;
bool vsync_asserted = false;
int frame = -1;
uint64_t frame_start = 0;
bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_standard_kernel_legal_schedule: %s\n", message);
   std::exit(1);
}

uint8_t timer_value() {
   if (!timer_active) return memory_image[kIntim];
   const uint64_t ticks = (virtual_cycles - timer_start) / timer_divisor;
   if (ticks <= timer_loaded) return static_cast<uint8_t>(timer_loaded - ticks);
   return static_cast<uint8_t>(255 - ((ticks - timer_loaded - 1) & 255));
}

uint8_t read_bus(uint16_t address) {
   return address == kIntim ? timer_value() : memory_image[address];
}

void write_bus(uint16_t address, uint8_t value) {
   if (address < kRomBase) memory_image[address] = value;
   writes.push_back({address, value});
}

void clock_cycle(mos6502 *) {}

void apply_writes() {
   for (const WriteEvent &event : writes) {
      if (event.address == kWsync) {
         const uint64_t within = virtual_cycles % kCyclesPerScanline;
         virtual_cycles += within ? kCyclesPerScanline - within : kCyclesPerScanline;
      }
      else if (event.address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (next && !vsync_asserted) {
            ++frame;
            frame_start = virtual_cycles;
         }
         vsync_asserted = next;
      }
      else if (event.address >= kTim1t && event.address <= kT1024t) {
         timer_active = true;
         timer_start = virtual_cycles;
         timer_loaded = event.value;
         timer_divisor = event.address == kTim1t ? 1 :
                         event.address == kTim8t ? 8 :
                         event.address == kTim64t ? 64 : 1024;
      }
   }
   writes.clear();
}

uint8_t parse_zp(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!text[0] || !end || *end || value > 0xFF) fail("bad zero-page argument");
   return static_cast<uint8_t>(value);
}

void expect_line(const std::map<uint64_t, std::vector<MaskEvent>> &by_line,
                 uint64_t line,
                 const std::vector<std::pair<uint64_t, uint8_t>> &expected) {
   const auto found = by_line.find(line);
   if (found == by_line.end()) fail("missing legal-mask line");
   if (found->second.size() != expected.size()) fail("wrong legal-mask count on line");
   for (size_t i = 0; i < expected.size(); ++i) {
      if (found->second[i].cycle != expected[i].first ||
          found->second[i].operand != expected[i].second) {
         std::fprintf(stderr,
            "vcs_standard_kernel_legal_schedule: line %llu event %zu is zp $%02x "
            "cycle %llu; expected zp $%02x cycle %llu\n",
            static_cast<unsigned long long>(line), i,
            found->second[i].operand,
            static_cast<unsigned long long>(found->second[i].cycle),
            expected[i].second,
            static_cast<unsigned long long>(expected[i].first));
         std::exit(1);
      }
   }
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 3) {
      std::fprintf(stderr,
         "usage: %s ROM object_masks_zp\n", argv[0]);
      return 2;
   }
   const uint8_t masks = parse_zp(argv[2]);
   const uint8_t ball_mask = masks;
   const uint8_t missile1_mask = static_cast<uint8_t>(masks + 1);
   const uint8_t missile0_mask = static_cast<uint8_t>(masks + 2);

   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) {
      fail("ROM is not exactly 4096 bytes");
   }

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   constexpr uint64_t kInstructionLimit = 100000000;
   for (uint64_t instructions = 0;
        instructions < kInstructionLimit && frame < 3;
        ++instructions) {
      const uint16_t pc = cpu.GetPC();
      if (frame == 2 && memory_image[pc] == kLsrZpX) {
         const uint64_t relative = virtual_cycles - frame_start;
         mask_events.push_back({relative / kCyclesPerScanline,
                               relative % kCyclesPerScanline,
                               memory_image[static_cast<uint16_t>(pc + 1)]});
      }
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < 3) fail("instruction limit reached before three frames");

   std::map<uint64_t, std::vector<MaskEvent>> by_line;
   for (const MaskEvent &event : mask_events) by_line[event.line].push_back(event);

   for (uint64_t line = 54; line <= 99; ++line) {
      if ((line & 1) == 0) {
         expect_line(by_line, line, {{2, missile1_mask}, {68, missile0_mask}});
      }
      else {
         const bool alternate = (line % 16 == 5);
         expect_line(by_line, line, {{alternate ? 39u : 45u,
                                      static_cast<uint8_t>(alternate ? ball_mask - 4 : ball_mask)}});
      }
   }

   // The static fixture's final-row DCP semantics, precomputed legally during
   // VBLANK: BL, P1 glyph, M1, P0 glyph, and M0 respectively.
   const std::pair<uint8_t, uint8_t> final_values[] = {
      {27, 0x0c}, {31, 0x00}, {35, 0x1c}, {39, 0x00}, {43, 0xfd}
   };
   for (const auto &entry : final_values) {
      const uint8_t actual = memory_image[static_cast<uint8_t>(masks + entry.first)];
      if (actual != entry.second) {
         std::fprintf(stderr,
            "vcs_standard_kernel_legal_schedule: final mask +%u is $%02x; expected $%02x\n",
            entry.first, actual, entry.second);
         return 1;
      }
   }

   std::printf(
      "vcs_standard_kernel_legal_schedule ok: 46 scanlines, three steady masks and five final values locked\n");
   return 0;
}
