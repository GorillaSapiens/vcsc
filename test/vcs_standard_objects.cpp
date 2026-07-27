//! @file vcs_standard_objects.cpp
//! @brief Prove the normalized standard renderer actively emits every TIA object.

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
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kEnam0 = 0x001D;
constexpr uint16_t kEnam1 = 0x001E;
constexpr uint16_t kEnabl = 0x001F;
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
int frame = -1;
bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;
unsigned grp0_nonzero = 0;
unsigned grp1_nonzero = 0;
unsigned missile0_enabled = 0;
unsigned missile1_enabled = 0;
unsigned ball_enabled = 0;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_standard_objects: %s\n", message);
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
         if (next && !vsync_asserted) ++frame;
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
      else if (frame == 2) {
         if (event.address == kGrp0 && event.value != 0) ++grp0_nonzero;
         if (event.address == kGrp1 && event.value != 0) ++grp1_nonzero;
         if (event.address == kEnam0 && (event.value & 2)) ++missile0_enabled;
         if (event.address == kEnam1 && (event.value & 2)) ++missile1_enabled;
         if (event.address == kEnabl && (event.value & 2)) ++ball_enabled;
      }
   }
   writes.clear();
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 2) {
      std::fprintf(stderr, "usage: %s ROM.bin\n", argv[0]);
      return 2;
   }
   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) fail("ROM is not exactly 4096 bytes");

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   constexpr uint64_t kInstructionLimit = 100000000;
   for (uint64_t instructions = 0; instructions < kInstructionLimit && frame < 3; ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < 3) fail("instruction limit reached before three frames");
   if (grp0_nonzero < 4) fail("P0 graphics were not emitted");
   if (grp1_nonzero < 4) fail("P1 graphics were not emitted");
   if (missile0_enabled < 2) fail("M0 was never visibly enabled");
   if (missile1_enabled < 2) fail("M1 was never visibly enabled");
   if (ball_enabled < 2) fail("ball was never visibly enabled");

   std::printf("vcs_standard_objects ok: P0=%u P1=%u M0=%u M1=%u BL=%u\n",
               grp0_nonzero, grp1_nonzero, missile0_enabled,
               missile1_enabled, ball_enabled);
   return 0;
}
