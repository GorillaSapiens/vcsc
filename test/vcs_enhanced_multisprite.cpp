//! @file vcs_enhanced_multisprite.cpp
//! @brief Prove symmetric P0/P1 emission and fair three-way arbitration.

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <set>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kColup0 = 0x0006;
constexpr uint16_t kColup1 = 0x0007;
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kSwcha = 0x0280;
constexpr uint16_t kSwchb = 0x0282;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct WriteEvent { uint16_t address; uint8_t value; };

uint8_t memory_image[65536];
uint64_t virtual_cycles = 0;
uint64_t cpu_cycles = 0;
std::vector<WriteEvent> writes;
bool vsync_asserted = false;
bool vblank_asserted = true;
int frame = -1;
bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;
std::vector<std::vector<uint8_t>> colors;
std::vector<unsigned> grp0_nonzero;
std::vector<unsigned> grp1_nonzero;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_enhanced_multisprite: %s\n", message);
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

void ensure_frame_storage() {
   if (frame < 0) return;
   const size_t need = static_cast<size_t>(frame + 1);
   if (colors.size() < need) colors.resize(need);
   if (grp0_nonzero.size() < need) grp0_nonzero.resize(need);
   if (grp1_nonzero.size() < need) grp1_nonzero.resize(need);
}

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
            ensure_frame_storage();
         }
         vsync_asserted = next;
      }
      else if (event.address == kVblank) {
         vblank_asserted = (event.value & 2) != 0;
      }
      else if (event.address >= kTim1t && event.address <= kT1024t) {
         timer_active = true;
         timer_start = virtual_cycles;
         timer_loaded = event.value;
         timer_divisor = event.address == kTim1t ? 1 :
                         event.address == kTim8t ? 8 :
                         event.address == kTim64t ? 64 : 1024;
      }
      else if (frame >= 0 && !vblank_asserted) {
         if (event.address == kColup0 || event.address == kColup1)
            colors[static_cast<size_t>(frame)].push_back(event.value);
         if (event.address == kGrp0 && event.value != 0)
            ++grp0_nonzero[static_cast<size_t>(frame)];
         if (event.address == kGrp1 && event.value != 0)
            ++grp1_nonzero[static_cast<size_t>(frame)];
      }
   }
   writes.clear();
}

int logical_color(uint8_t color) {
   if (color == 0x0e) return 0;
   if (color == 0x4e) return 1;
   if (color == 0xce) return 2;
   return -1;
}

std::set<int> top_pair(int f) {
   if (f < 0 || static_cast<size_t>(f) >= colors.size()) fail("missing frame color data");
   const auto &c = colors[static_cast<size_t>(f)];
   if (c.size() != 5) fail("expected exactly five scheduled color events per frame");
   if (c[2] != 0xae || c[3] != 0x5e || c[4] != 0xbe)
      fail("two-way overlap or isolated sprite disappeared");
   const int a = logical_color(c[0]);
   const int b = logical_color(c[1]);
   if (a < 0 || b < 0 || a == b) fail("bad three-way overlap color pair");
   return {a, b};
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 2) {
      std::fprintf(stderr, "usage: %s ROM.bin\n", argv[0]);
      return 2;
   }

   std::memset(memory_image, 0, sizeof(memory_image));
   // Keep joystick and console switches released. The generic CPU harness has
   // no RIOT input model, so zero would otherwise look like Reset held down.
   memory_image[kSwcha] = 0xff;
   memory_image[kSwchb] = 0xff;

   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize))
      fail("ROM is not exactly 4096 bytes");

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   constexpr uint64_t kInstructionLimit = 100000000;
   for (uint64_t instructions = 0;
        instructions < kInstructionLimit && frame < 9;
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < 9) fail("instruction limit reached before arbitration sample");

   const auto p2 = top_pair(2);
   const auto p3 = top_pair(3);
   const auto p4 = top_pair(4);
   const std::set<std::set<int>> got = {p2, p3, p4};
   const std::set<std::set<int>> want = {{0,1}, {1,2}, {0,2}};
   if (got != want) fail("three-way pile-up did not rotate through all 2-of-3 pairs");
   if (top_pair(5) != p2 || top_pair(6) != p3 || top_pair(7) != p4)
      fail("three-way arbitration is not a stable three-frame rotation");

   for (int f = 2; f <= 7; ++f) {
      if (grp0_nonzero[static_cast<size_t>(f)] == 0)
         fail("P0 emitted no nonzero graphics in a sampled frame");
      if (grp1_nonzero[static_cast<size_t>(f)] == 0)
         fail("P1 emitted no nonzero graphics in a sampled frame");
   }

   std::puts("vcs_enhanced_multisprite arbitration ok: both lanes active, 3-way fair 2-of-3 rotation, 2-way solid");
   return 0;
}
