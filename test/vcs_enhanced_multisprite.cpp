//! @file vcs_enhanced_multisprite.cpp
//! @brief Prove symmetric P0/P1 emission and fair N-way arbitration.

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
   constexpr std::array<uint8_t, 6> kColors = {0x0e, 0x4e, 0xce, 0xae, 0x5e, 0xbe};
   for (size_t i = 0; i < kColors.size(); ++i) {
      if (color == kColors[i]) return static_cast<int>(i);
   }
   return -1;
}

std::set<int> pile_pair(int f, int pile_size) {
   if (f < 0 || static_cast<size_t>(f) >= colors.size()) fail("missing frame color data");
   std::set<int> pair;
   unsigned pile_writes = 0;
   for (uint8_t color : colors[static_cast<size_t>(f)]) {
      const int logical = logical_color(color);
      if (logical >= 0 && logical < pile_size) {
         pair.insert(logical);
         ++pile_writes;
      }
   }
   if (pile_writes != 2 || pair.size() != 2)
      fail("pile-up did not emit exactly two distinct logical sprites");
   return pair;
}

bool frame_has_logical_color(int f, int logical) {
   if (f < 0 || static_cast<size_t>(f) >= colors.size()) fail("missing frame color data");
   for (uint8_t color : colors[static_cast<size_t>(f)]) {
      if (logical_color(color) == logical) return true;
   }
   return false;
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 3) {
      std::fprintf(stderr, "usage: %s ROM.bin PILE_SIZE\n", argv[0]);
      return 2;
   }
   char *end = nullptr;
   const long pile_long = std::strtol(argv[2], &end, 10);
   if (!end || *end != '\0' || pile_long < 3 || pile_long > 6)
      fail("PILE_SIZE must be 3 through 6");
   const int pile_size = static_cast<int>(pile_long);

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
   const int last_sample_frame = 2 + pile_size * 2 - 1;
   for (uint64_t instructions = 0;
        instructions < kInstructionLimit && frame < last_sample_frame + 1;
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < last_sample_frame + 1) fail("instruction limit reached before arbitration sample");

   std::array<unsigned, 6> appearances{};
   std::vector<std::set<int>> first_rotation;
   for (int k = 0; k < pile_size; ++k) {
      const auto pair = pile_pair(2 + k, pile_size);
      first_rotation.push_back(pair);
      for (int logical : pair) ++appearances[static_cast<size_t>(logical)];
   }
   for (int logical = 0; logical < pile_size; ++logical) {
      if (appearances[static_cast<size_t>(logical)] != 2)
         fail("pile-up arbitration is not fair over one N-frame rotation");
   }
   for (int k = 0; k < pile_size; ++k) {
      if (pile_pair(2 + pile_size + k, pile_size) != first_rotation[static_cast<size_t>(k)])
         fail("pile-up arbitration did not repeat its N-frame rotation");
   }

   // The public three-way diagnostic also promises that sprites 3/4 (the
   // separate two-way overlap) and sprite 5 (isolated) remain solid.
   if (pile_size == 3) {
      for (int f = 2; f < 2 + pile_size * 2; ++f) {
         for (int logical = 3; logical < 6; ++logical) {
            if (!frame_has_logical_color(f, logical))
               fail("two-way overlap or isolated sprite disappeared");
         }
      }
   }

   for (int f = 2; f < 2 + pile_size * 2; ++f) {
      if (grp0_nonzero[static_cast<size_t>(f)] == 0)
         fail("P0 emitted no nonzero graphics in a sampled frame");
      if (grp1_nonzero[static_cast<size_t>(f)] == 0)
         fail("P1 emitted no nonzero graphics in a sampled frame");
   }

   std::printf("vcs_enhanced_multisprite arbitration ok: %d-way pile fair 2-of-%d rotation, both lanes active\n",
      pile_size, pile_size);
   return 0;
}
