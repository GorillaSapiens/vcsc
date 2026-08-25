#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xf000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerLine = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kColup0 = 0x0006;
constexpr uint16_t kColup1 = 0x0007;
constexpr uint16_t kColupf = 0x0008;
constexpr uint16_t kColubk = 0x0009;
constexpr uint16_t kSwcha = 0x0280;
constexpr uint16_t kSwchb = 0x0282;
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
std::vector<TimedWrite> vblank_writes;
std::vector<TimedWrite> color_writes;
bool vsync_asserted = false;
Timer timer;

[[noreturn]] void fail(const std::string &m) {
   std::fprintf(stderr, "vcs_frame_50hz_interactive: %s\n", m.c_str());
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
   if (elapsed < threshold)
      return static_cast<uint8_t>(timer.loaded - elapsed / timer.divisor);
   return static_cast<uint8_t>(255 - ((elapsed - threshold) & 255));
}

uint8_t read_bus(uint16_t a) {
   if (a == kTimint) {
      sync_timer();
      return timer.interrupt_flag ? 0x80 : 0;
   }
   if (a == kIntim) {
      sync_timer();
      const uint8_t v = current_timer_value();
      timer.interrupt_flag = false;
      return v;
   }
   return memory_image[a];
}

void write_bus(uint16_t a, uint8_t v) {
   if (a < kRomBase) memory_image[a] = v;
   pending_writes.push_back({a, v});
}
void clock_cycle(mos6502 *) {}

void load_timer(uint16_t a, uint8_t v) {
   timer.active = true;
   timer.start = virtual_cycles;
   timer.loaded = v;
   timer.underflowed = false;
   timer.interrupt_flag = false;
   switch (a) {
      case kTim1t: timer.divisor = 1; break;
      case kTim8t: timer.divisor = 8; break;
      case kTim64t: timer.divisor = 64; break;
      case kT1024t: timer.divisor = 1024; break;
      default: std::abort();
   }
}

void apply_writes() {
   for (const auto &e : pending_writes) {
      if (e.address == kWsync) {
         const uint64_t within = virtual_cycles % kCyclesPerLine;
         virtual_cycles += within ? kCyclesPerLine - within : kCyclesPerLine;
      }
      else if (e.address == kVsync) {
         const bool next = (e.value & 2) != 0;
         if (next && !vsync_asserted) vsync_assertions.push_back(virtual_cycles);
         vsync_asserted = next;
      }
      else if (e.address == kVblank) {
         vblank_writes.push_back({virtual_cycles, e.address, e.value});
      }
      else if (e.address >= kColup0 && e.address <= kColubk) {
         color_writes.push_back({virtual_cycles, e.address, e.value});
      }
      else if (e.address >= kTim1t && e.address <= kT1024t) {
         load_timer(e.address, e.value);
      }
   }
   pending_writes.clear();
}

const TimedWrite &find_vblank(uint64_t start, uint64_t end, uint8_t value,
                             size_t occurrence) {
   size_t seen = 0;
   for (const auto &e : vblank_writes) {
      if (e.cycle < start || e.cycle >= end || e.value != value) continue;
      if (seen++ == occurrence) return e;
   }
   fail("missing expected VBLANK write");
}

uint8_t color_at(uint16_t address, uint64_t cycle) {
   uint8_t value = 0;
   for (const auto &e : color_writes) {
      if (e.cycle > cycle) break;
      if (e.address == address) value = e.value;
   }
   return value;
}

void check_active_field_colors(uint64_t frame_base_line, uint64_t line,
                               const char *which) {
   const uint64_t sample = (frame_base_line + line) * kCyclesPerLine + 23;
   const uint8_t bg = color_at(kColubk, sample);
   const uint8_t p0 = color_at(kColup0, sample);
   const uint8_t p1 = color_at(kColup1, sample);
   const uint8_t pf = color_at(kColupf, sample);
   if (p0 == bg || p1 == bg || pf == bg) {
      char message[192];
      std::snprintf(message, sizeof(message),
         "%s visible line %llu is still border-colored: bg=$%02x p0=$%02x p1=$%02x pf=$%02x",
         which, static_cast<unsigned long long>(line), bg, p0, p1, pf);
      fail(message);
   }
}
}

int main(int argc, char **argv) {
   if (argc != 2) {
      std::fprintf(stderr, "usage: %s ROM.bin\n", argv[0]);
      return 2;
   }
   std::memset(memory_image, 0, sizeof(memory_image));
   // Real inactive joystick/console-switch inputs are high.  Zero would hold
   // Reset and make the public interactive examples intentionally reboot.
   memory_image[kSwcha] = 0xff;
   memory_image[kSwchb] = 0xff;
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("cannot open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) fail("bad ROM size");

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   uint64_t cpu_cycles = 0;
   const uint64_t limit = 20000000;
   for (uint64_t instructions = 0;
        instructions < limit && vsync_assertions.size() < 10;
        ++instructions) {
      pending_writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (vsync_assertions.size() < 10) fail("instruction limit reached");

   for (size_t i = 2; i + 1 < vsync_assertions.size(); ++i) {
      const uint64_t start = vsync_assertions[i];
      const uint64_t end = vsync_assertions[i + 1];
      if (end - start != 314 * kCyclesPerLine)
         fail("frame is not 314 raw lines / 312 Stella lines");
      const auto &begin_vblank = find_vblank(start, end, 2, 0);
      const auto &end_vblank = find_vblank(start, end, 0, 0);
      const auto &begin_overscan = find_vblank(start, end, 2, 1);
      const uint64_t base = start / kCyclesPerLine;
      if (begin_vblank.cycle / kCyclesPerLine != base + 3)
         fail("VBLANK did not begin after three VSYNC lines");
      if (end_vblank.cycle / kCyclesPerLine != base + 48)
         fail("visible phase did not begin after 45 VBLANK lines");
      if (begin_overscan.cycle / kCyclesPerLine != base + 276)
         fail("overscan did not begin after 228 visible lines");

      // The PAL/SECAM example now instantiates the renderer for the complete
      // 228-line visible field.  There must be no synthetic 17/19-line border
      // wrapper: active P0/P1/PF colors are already live on the first visible
      // line and remain live through the last one.
      check_active_field_colors(base, 48, "first");
      check_active_field_colors(base, 275, "last");
   }
   std::puts("vcs_frame_50hz_interactive ok");
   return 0;
}
