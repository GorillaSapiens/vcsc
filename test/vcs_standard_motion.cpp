//! @file vcs_standard_motion.cpp
//! @brief Lock the standard kernel's object rows and asynchronous X motion.

#include <array>
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
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kEnam0 = 0x001D;
constexpr uint16_t kEnam1 = 0x001E;
constexpr uint16_t kEnabl = 0x001F;
constexpr uint16_t kResp0 = 0x0010;
constexpr uint16_t kResbl = 0x0014;
constexpr uint16_t kHmp0 = 0x0020;
constexpr uint16_t kHmbl = 0x0024;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;
constexpr int kFramesToCheck = 320;
constexpr int kFirstRasterFrame = 2;
constexpr int kLastRasterFrame = 8;
constexpr uint64_t kExpectedFrameCycles = 20140; // fixed harness baseline; hook work must fit the timer

enum Object : size_t { P0, P1, M0, M1, BL, ObjectCount };

struct WriteEvent { uint16_t address; uint8_t value; };
struct ObjectLines {
   std::array<std::vector<uint64_t>, ObjectCount> lines;
};
struct PositionWrites {
   std::array<int, ObjectCount> resp_cycle;
   std::array<int, ObjectCount> hmp_value;
   PositionWrites() {
      resp_cycle.fill(-1);
      hmp_value.fill(-1);
   }
};

uint8_t memory_image[65536];
uint64_t virtual_cycles = 0;
uint64_t cpu_cycles = 0;
std::vector<WriteEvent> writes;
bool vsync_asserted = false;
int frame = -1;
uint64_t frame_start = 0;
bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;
std::map<int, ObjectLines> active_lines;
std::map<int, PositionWrites> position_writes;
std::map<int, std::array<uint8_t, ObjectCount>> frame_x;
std::vector<uint64_t> frame_periods;

uint8_t object_x_zp = 0;
std::array<uint8_t, ObjectCount> y_zp{};
uint8_t motion_frame_zp = 0;
std::array<uint8_t, ObjectCount> expected_x{{0, 159, 37, 121, 80}};
constexpr std::array<uint8_t, ObjectCount> expected_speed{{1, 2, 3, 4, 5}};
std::array<bool, ObjectCount> saw_low{};
std::array<bool, ObjectCount> saw_high{};
uint8_t expected_motion_frame = 0;
uint8_t expected_directions = 0x15;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_standard_motion: %s\n", message);
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

uint8_t parse_zp(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!text[0] || !end || *end || value > 0xFF) fail("bad zero-page argument");
   return static_cast<uint8_t>(value);
}

void move_expected(Object object, uint8_t direction) {
   uint8_t &x = expected_x[object];
   const uint8_t speed = expected_speed[object];
   if ((expected_directions & direction) != 0) {
      if (x >= static_cast<uint8_t>(159 - speed)) {
         x = 159;
         expected_directions ^= direction;
      }
      else {
         x = static_cast<uint8_t>(x + speed);
      }
   }
   else {
      if (x <= speed) {
         x = 0;
         expected_directions ^= direction;
      }
      else {
         x = static_cast<uint8_t>(x - speed);
      }
   }
}

void advance_expected_motion() {
   ++expected_motion_frame;
   move_expected(P0, 0x01);
   move_expected(P1, 0x02);
   move_expected(M0, 0x04);
   move_expected(M1, 0x08);
   move_expected(BL, 0x10);
}

void verify_frame_state() {
   if (frame < 0 || frame >= kFramesToCheck) return;
   static constexpr std::array<uint8_t, ObjectCount> expected_y{{18, 78, 34, 62, 48}};
   for (size_t i = 0; i < ObjectCount; ++i) {
      const uint8_t actual_x = memory_image[static_cast<uint8_t>(object_x_zp + i)];
      if (actual_x != expected_x[i]) {
         std::fprintf(stderr,
            "vcs_standard_motion: frame %d object %zu X is %u; expected %u\n",
            frame, i, actual_x, expected_x[i]);
         std::exit(1);
      }
      if (actual_x == 0) saw_low[i] = true;
      if (actual_x == 159) saw_high[i] = true;
      const uint8_t actual_y = memory_image[y_zp[i]];
      if (actual_y != expected_y[i]) {
         std::fprintf(stderr,
            "vcs_standard_motion: frame %d object %zu Y is %u; expected %u\n",
            frame, i, actual_y, expected_y[i]);
         std::exit(1);
      }
   }
   const uint8_t actual_motion_frame = memory_image[motion_frame_zp];
   if (actual_motion_frame != expected_motion_frame) {
      std::fprintf(stderr,
         "vcs_standard_motion: frame %d motion counter is %u; expected %u\n",
         frame, actual_motion_frame, expected_motion_frame);
      std::exit(1);
   }
   frame_x[frame] = expected_x;
   advance_expected_motion();
}

uint8_t expected_hmp(uint8_t x) {
   static constexpr std::array<uint8_t, 16> table{{
      0x80, 0x70, 0x60, 0x50, 0x40, 0x30, 0x20, 0x10,
      0x00, 0xF0, 0xE0, 0xD0, 0xC0, 0xB0, 0xA0, 0x90
   }};
   int remainder = x;
   do {
      remainder -= 15;
   } while (remainder >= 0);
   const int index = 16 + remainder;
   if (index < 0 || index >= static_cast<int>(table.size()))
      fail("horizontal remainder fell outside repostable");
   return table[static_cast<size_t>(index)];
}

int expected_resp_cycle(uint8_t x) {
   return 18 + 5 * (static_cast<int>(x) / 15 + 1);
}

void record_position_write(uint16_t address, uint8_t value) {
   if (frame < 0 || frame >= kFramesToCheck) return;
   PositionWrites &position = position_writes[frame];
   if (address >= kResp0 && address <= kResbl) {
      const size_t object = static_cast<size_t>(address - kResp0);
      if (position.resp_cycle[object] < 0)
         position.resp_cycle[object] = static_cast<int>(virtual_cycles % kCyclesPerScanline);
   }
   else if (address >= kHmp0 && address <= kHmbl) {
      const size_t object = static_cast<size_t>(address - kHmp0);
      if (position.hmp_value[object] < 0)
         position.hmp_value[object] = value;
   }
}

void record_active_write(uint16_t address, uint8_t value) {
   if (frame < kFirstRasterFrame || frame > kLastRasterFrame) return;
   const uint64_t relative = virtual_cycles - frame_start;
   const uint64_t line = relative / kCyclesPerScanline;
   if (line >= 210) return; // Ignore the score display below the object field.

   Object object;
   bool active;
   if (address == kGrp0) { object = P0; active = value != 0; }
   else if (address == kGrp1) { object = P1; active = value != 0; }
   else if (address == kEnam0) { object = M0; active = (value & 2) != 0; }
   else if (address == kEnam1) { object = M1; active = (value & 2) != 0; }
   else if (address == kEnabl) { object = BL; active = (value & 2) != 0; }
   else return;
   if (active) active_lines[frame].lines[object].push_back(line);
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
            if (frame >= 0) frame_periods.push_back(virtual_cycles - frame_start);
            ++frame;
            frame_start = virtual_cycles;
            verify_frame_state();
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
      else {
         record_position_write(event.address, event.value);
         record_active_write(event.address, event.value);
      }
   }
   writes.clear();
}

void expect_lines(int raster_frame,
                  Object object,
                  const std::vector<uint64_t> &expected) {
   const auto found = active_lines.find(raster_frame);
   if (found == active_lines.end()) fail("missing raster frame");
   const std::vector<uint64_t> &actual = found->second.lines[object];
   if (actual != expected) {
      std::fprintf(stderr,
         "vcs_standard_motion: frame %d object %zu active lines:",
         raster_frame, static_cast<size_t>(object));
      for (uint64_t line : actual) std::fprintf(stderr, " %llu", static_cast<unsigned long long>(line));
      std::fprintf(stderr, "; expected:");
      for (uint64_t line : expected) std::fprintf(stderr, " %llu", static_cast<unsigned long long>(line));
      std::fputc('\n', stderr);
      std::exit(1);
   }
}

void verify_horizontal_positioning() {
   for (int checked = 0; checked < kFramesToCheck; ++checked) {
      const auto xs = frame_x.find(checked);
      const auto writes_found = position_writes.find(checked);
      if (xs == frame_x.end() || writes_found == position_writes.end())
         fail("missing horizontal-position frame");
      for (size_t object = 0; object < ObjectCount; ++object) {
         const uint8_t x = xs->second[object];
         const int want_resp = expected_resp_cycle(x);
         const int want_hmp = expected_hmp(x);
         const int got_resp = writes_found->second.resp_cycle[object];
         const int got_hmp = writes_found->second.hmp_value[object];
         if (got_resp != want_resp || got_hmp != want_hmp) {
            std::fprintf(stderr,
               "vcs_standard_motion: frame %d object %zu X=%u RESP cycle=%d expected=%d HMP=%02X expected=%02X\n",
               checked, object, x, got_resp, want_resp,
               got_hmp < 0 ? 0xff : got_hmp, want_hmp);
            std::exit(1);
         }
      }
   }
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 9) {
      std::fprintf(stderr,
         "usage: %s ROM object_x p0_y p1_y m0_y m1_y ball_y motion_frame\n",
         argv[0]);
      return 2;
   }
   object_x_zp = parse_zp(argv[2]);
   y_zp = {{parse_zp(argv[3]), parse_zp(argv[4]), parse_zp(argv[5]),
            parse_zp(argv[6]), parse_zp(argv[7])}};
   motion_frame_zp = parse_zp(argv[8]);

   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) {
      fail("ROM is not exactly 4096 bytes");
   }

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   constexpr uint64_t kInstructionLimit = 200000000;
   for (uint64_t instructions = 0;
        instructions < kInstructionLimit && frame < kFramesToCheck;
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < kFramesToCheck) fail("instruction limit reached before motion check completed");

   if (frame_periods.size() < static_cast<size_t>(kFramesToCheck))
      fail("missing frame-period samples");
   for (uint64_t period : frame_periods) {
      if (period != kExpectedFrameCycles) {
         std::fprintf(stderr,
            "vcs_standard_motion: frame period is %llu cycles; expected %llu\n",
            static_cast<unsigned long long>(period),
            static_cast<unsigned long long>(kExpectedFrameCycles));
         return 1;
      }
   }

   verify_horizontal_positioning();
   for (size_t object = 0; object < ObjectCount; ++object) {
      if (!saw_low[object] || !saw_high[object]) {
         std::fprintf(stderr,
            "vcs_standard_motion: object %zu did not reach both X endpoints"
            " (low=%d high=%d)\n",
            object, saw_low[object] ? 1 : 0, saw_high[object] ? 1 : 0);
         return 1;
      }
   }

   const std::vector<uint64_t> p0{56, 58, 60, 62, 64, 66, 68, 70};
   const std::vector<uint64_t> p1{178, 180, 182, 184, 186, 188, 190, 192};
   const std::vector<uint64_t> m0{95, 97, 99, 101, 103, 105};
   const std::vector<uint64_t> m1{146, 148, 150, 152, 154, 156, 158, 160};
   const std::vector<uint64_t> bl{127, 129, 131, 133};
   for (int checked = kFirstRasterFrame; checked <= kLastRasterFrame; ++checked) {
      expect_lines(checked, P0, p0);
      expect_lines(checked, P1, p1);
      expect_lines(checked, M0, m0);
      expect_lines(checked, M1, m1);
      expect_lines(checked, BL, bl);
   }

   std::printf(
      "vcs_standard_motion ok: 320 full-range X/HMOVE states and seven exact object rasters locked\n");
   return 0;
}
