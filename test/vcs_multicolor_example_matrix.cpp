#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <set>
#include <string>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerLine = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct Write { uint16_t address; uint8_t value; };
uint8_t memory_image[65536];
uint64_t virtual_cycles = 0;
uint64_t cpu_cycles = 0;
std::vector<Write> writes;
std::vector<uint64_t> vsync_cycles;
bool vsync_asserted = false;
bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;
bool timer_overrun = false;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_multicolor_example_matrix: %s\n", message);
   std::exit(1);
}
uint16_t parse_address(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!end || *end != '\0' || value > 0xff) fail("bad zero-page address");
   return static_cast<uint16_t>(value);
}
uint8_t timer_value() {
   if (!timer_active) return memory_image[kIntim];
   const uint64_t ticks = (virtual_cycles - timer_start) / timer_divisor;
   if (ticks <= timer_loaded) return static_cast<uint8_t>(timer_loaded - ticks);
   return static_cast<uint8_t>(255 - ((ticks - timer_loaded - 1) & 255));
}
uint8_t read_bus(uint16_t address) {
   if (address == kIntim) {
      if (timer_active && (virtual_cycles - timer_start) / timer_divisor > timer_loaded)
         timer_overrun = true;
      return timer_value();
   }
   return memory_image[address];
}
void write_bus(uint16_t address, uint8_t value) {
   if (address < kRomBase) memory_image[address] = value;
   writes.push_back({address, value});
}
void clock_cycle(mos6502 *) {}
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
   for (const Write &event : writes) {
      if (event.address == kWsync) {
         const uint64_t phase = virtual_cycles % kCyclesPerLine;
         virtual_cycles += phase ? kCyclesPerLine - phase : kCyclesPerLine;
      }
      else if (event.address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (next && !vsync_asserted) vsync_cycles.push_back(virtual_cycles);
         vsync_asserted = next;
      }
      else if (event.address == kTim1t || event.address == kTim8t ||
               event.address == kTim64t || event.address == kT1024t) {
         load_timer(event.address, event.value);
      }
   }
   writes.clear();
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 7) {
      std::fprintf(stderr, "usage: %s ROM static|x|xy object_x p0_y p1_y ball_y\n", argv[0]);
      return 2;
   }
   const std::string mode = argv[2];
   if (mode != "static" && mode != "x" && mode != "xy") fail("bad mode");
   const uint16_t object_x = parse_address(argv[3]);
   const std::array<uint16_t,3> y{{parse_address(argv[4]),parse_address(argv[5]),parse_address(argv[6])}};

   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("cannot open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) fail("ROM is not 4096 bytes");

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   std::array<std::set<uint8_t>,3> seen_x;
   std::array<std::set<uint8_t>,3> seen_y;
   size_t sampled = 0;
   size_t last_vsync_count = 0;
   constexpr uint64_t kInstructionLimit = 150000000;
   for (uint64_t instructions = 0; instructions < kInstructionLimit && vsync_cycles.size() < 85; ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
      if (vsync_cycles.size() != last_vsync_count) {
         last_vsync_count = vsync_cycles.size();
         if (last_vsync_count >= 4) {
            const std::array<uint8_t,3> xs{{memory_image[object_x],memory_image[object_x+1],memory_image[object_x+4]}};
            for (size_t i=0;i<3;++i) {
               if (xs[i] > 159) fail("object X escaped 0..159");
               if (memory_image[y[i]] > 80) fail("object Y escaped demo range");
               seen_x[i].insert(xs[i]);
               seen_y[i].insert(memory_image[y[i]]);
            }
            ++sampled;
         }
      }
   }
   if (vsync_cycles.size() < 85 || sampled < 80) fail("not enough frames");
   if (timer_overrun) fail("frame timer overran");
   for (size_t i=4;i<vsync_cycles.size();++i) {
      if (vsync_cycles[i]-vsync_cycles[i-1] != 262*kCyclesPerLine)
         fail("frame is not exactly 262 raw lines");
   }
   for (size_t i=0;i<3;++i) {
      if (mode == "static") {
         if (seen_x[i].size()!=1 || seen_y[i].size()!=1) fail("static example moved");
      }
      else if (mode == "x") {
         if (seen_x[i].size()<2 || seen_y[i].size()!=1) fail("X-only motion contract failed");
      }
      else {
         if (seen_x[i].size()<2 || seen_y[i].size()<2) fail("X/Y motion contract failed");
      }
   }
   std::printf("vcs_multicolor_example_matrix %s ok: %zu stable frames\n", mode.c_str(), sampled);
   return 0;
}
