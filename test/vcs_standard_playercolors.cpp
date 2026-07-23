//! @file vcs_standard_playercolors.cpp
//! @brief Verify the P0+P1+BL per-row-color standard-kernel profile.

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint64_t kExpectedFrameCycles = 20140;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kColup0 = 0x0006;
constexpr uint16_t kColup1 = 0x0007;
constexpr uint16_t kResp0 = 0x0010;
constexpr uint16_t kResbl = 0x0014;
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kEnam0 = 0x001D;
constexpr uint16_t kEnam1 = 0x001E;
constexpr uint16_t kEnabl = 0x001F;
constexpr uint16_t kHmp0 = 0x0020;
constexpr uint16_t kHmbl = 0x0024;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

enum Object : size_t { P0, P1, M0, M1, BL, ObjectCount };

struct WriteEvent { uint16_t address; uint8_t value; };
struct TimedWrite {
   uint64_t line;
   uint64_t cycle;
   uint16_t address;
   uint8_t value;
};
struct PositionWrites {
   std::array<int, ObjectCount> resp_cycle;
   std::array<int, ObjectCount> hmp_value;
   PositionWrites() { resp_cycle.fill(-1); hmp_value.fill(-1); }
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
std::vector<uint64_t> frame_periods;
std::map<int, std::vector<TimedWrite>> timed_writes;
std::map<int, PositionWrites> position_writes;
std::map<int, std::array<uint8_t, ObjectCount>> frame_x;

bool motion_mode = false;
int frames_to_check = 4;
uint8_t object_x_zp = 0;
std::array<uint8_t, 3> y_zp{};
uint8_t direction_zp = 0;
std::array<uint8_t, ObjectCount> expected_x{{0, 159, 0, 0, 80}};
uint8_t expected_directions = 0x05;
std::array<bool, 3> saw_low{};
std::array<bool, 3> saw_high{};
unsigned missile0_enabled = 0;
unsigned missile1_enabled = 0;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_standard_playercolors: %s\n", message);
   std::exit(1);
}

uint8_t parse_zp(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!text[0] || !end || *end || value > 0xFF) fail("bad zero-page argument");
   return static_cast<uint8_t>(value);
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

void move_expected(Object object, uint8_t direction, uint8_t speed) {
   uint8_t &x = expected_x[object];
   if ((expected_directions & direction) != 0) {
      if (x >= static_cast<uint8_t>(159 - speed)) {
         x = 159;
         expected_directions ^= direction;
      }
      else x = static_cast<uint8_t>(x + speed);
   }
   else {
      if (x <= speed) {
         x = 0;
         expected_directions ^= direction;
      }
      else x = static_cast<uint8_t>(x - speed);
   }
}

void advance_expected_motion() {
   move_expected(P0, 0x01, 1);
   move_expected(P1, 0x02, 5);
   move_expected(BL, 0x04, 7);
}

void verify_frame_state() {
   if (frame < 0 || frame >= frames_to_check) return;
   const std::array<uint8_t, 3> expected_y = motion_mode
      ? std::array<uint8_t, 3>{{18, 78, 48}}
      : std::array<uint8_t, 3>{{78, 42, 45}};
   for (size_t i = 0; i < expected_y.size(); ++i) {
      if (memory_image[y_zp[i]] != expected_y[i]) {
         std::fprintf(stderr,
            "vcs_standard_playercolors: frame %d Y%zu is %u; expected %u\n",
            frame, i, memory_image[y_zp[i]], expected_y[i]);
         std::exit(1);
      }
   }
   if (!motion_mode) return;

   for (size_t object = 0; object < ObjectCount; ++object) {
      const uint8_t actual = memory_image[static_cast<uint8_t>(object_x_zp + object)];
      if (actual != expected_x[object]) {
         std::fprintf(stderr,
            "vcs_standard_playercolors: frame %d object %zu X is %u; expected %u\n",
            frame, object, actual, expected_x[object]);
         std::exit(1);
      }
   }
   if (memory_image[direction_zp] != expected_directions) {
      std::fprintf(stderr,
         "vcs_standard_playercolors: frame %d directions are %02X; expected %02X\n",
         frame, memory_image[direction_zp], expected_directions);
      std::exit(1);
   }
   const std::array<Object, 3> public_objects{{P0, P1, BL}};
   for (size_t i = 0; i < public_objects.size(); ++i) {
      const uint8_t x = expected_x[public_objects[i]];
      if (x == 0) saw_low[i] = true;
      if (x == 159) saw_high[i] = true;
   }
   frame_x[frame] = expected_x;
   advance_expected_motion();
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
         if (event.address == kEnam0 && (event.value & 2)) ++missile0_enabled;
         if (event.address == kEnam1 && (event.value & 2)) ++missile1_enabled;
         if (frame >= 0 && frame < frames_to_check) {
            if (event.address >= kResp0 && event.address <= kResbl) {
               const size_t object = static_cast<size_t>(event.address - kResp0);
               if (position_writes[frame].resp_cycle[object] < 0)
                  position_writes[frame].resp_cycle[object] =
                     static_cast<int>(virtual_cycles % kCyclesPerScanline);
            }
            else if (event.address >= kHmp0 && event.address <= kHmbl) {
               const size_t object = static_cast<size_t>(event.address - kHmp0);
               if (position_writes[frame].hmp_value[object] < 0)
                  position_writes[frame].hmp_value[object] = event.value;
            }
            if (frame >= 2 && (event.address == kGrp0 || event.address == kGrp1 ||
                              event.address == kEnabl || event.address == kColup0 ||
                              event.address == kColup1)) {
               const uint64_t relative = virtual_cycles - frame_start;
               const uint64_t line = relative / kCyclesPerScanline;
               if (line < 215) {
                  timed_writes[frame].push_back(
                     {line, relative % kCyclesPerScanline, event.address, event.value});
               }
            }
         }
      }
   }
   writes.clear();
}

uint8_t expected_hmp(uint8_t x) {
   static constexpr std::array<uint8_t, 16> table{{
      0x80, 0x70, 0x60, 0x50, 0x40, 0x30, 0x20, 0x10,
      0x00, 0xF0, 0xE0, 0xD0, 0xC0, 0xB0, 0xA0, 0x90
   }};
   int remainder = x;
   do remainder -= 15; while (remainder >= 0);
   return table[static_cast<size_t>(16 + remainder)];
}
int expected_resp_cycle(uint8_t x) {
   return 18 + 5 * (static_cast<int>(x) / 15 + 1);
}

void verify_positioning() {
   if (!motion_mode) return;
   for (int checked = 0; checked < frames_to_check; ++checked) {
      const auto xs = frame_x.find(checked);
      const auto pw = position_writes.find(checked);
      if (xs == frame_x.end() || pw == position_writes.end())
         fail("missing horizontal-position frame");
      for (size_t object = 0; object < ObjectCount; ++object) {
         const uint8_t x = xs->second[object];
         const int got_resp = pw->second.resp_cycle[object];
         const int got_hmp = pw->second.hmp_value[object];
         if (got_resp != expected_resp_cycle(x) || got_hmp != expected_hmp(x)) {
            std::fprintf(stderr,
               "vcs_standard_playercolors: frame %d object %zu X=%u RESP=%d/%d HMP=%02X/%02X\n",
               checked, object, x, got_resp, expected_resp_cycle(x),
               got_hmp < 0 ? 0xff : got_hmp, expected_hmp(x));
            std::exit(1);
         }
      }
   }
}

std::vector<uint64_t> active_lines(int raster_frame, uint16_t address) {
   std::vector<uint64_t> out;
   const auto found = timed_writes.find(raster_frame);
   if (found == timed_writes.end()) return out;
   for (const TimedWrite &write : found->second) {
      const bool active = address == kEnabl ? (write.value & 2) != 0 : write.value != 0;
      if (write.address == address && active) out.push_back(write.line);
   }
   return out;
}

void expect_lines(int raster_frame, uint16_t address, const std::vector<uint64_t> &expected,
                  const char *name) {
   const std::vector<uint64_t> actual = active_lines(raster_frame, address);
   if (actual == expected) return;
   std::fprintf(stderr, "vcs_standard_playercolors: %s lines:", name);
   for (uint64_t line : actual) std::fprintf(stderr, " %llu", static_cast<unsigned long long>(line));
   std::fprintf(stderr, "; expected:");
   for (uint64_t line : expected) std::fprintf(stderr, " %llu", static_cast<unsigned long long>(line));
   std::fputc('\n', stderr);
   std::exit(1);
}

void expect_colors(int raster_frame, uint16_t address, uint64_t first_line,
                   uint64_t cycle, const std::array<uint8_t, 8> &expected,
                   const char *name) {
   const auto found = timed_writes.find(raster_frame);
   if (found == timed_writes.end()) fail("missing color raster frame");
   for (size_t i = 0; i < expected.size(); ++i) {
      const uint64_t line = first_line + 2 * i;
      unsigned matches = 0;
      uint8_t actual = 0;
      for (const TimedWrite &write : found->second) {
         if (write.address == address && write.line == line && write.cycle == cycle) {
            ++matches;
            actual = write.value;
         }
      }
      if (matches != 1 || actual != expected[i]) {
         std::fprintf(stderr,
            "vcs_standard_playercolors: %s row %zu at line %llu cycle %llu is %02X (%u writes); expected %02X\n",
            name, i, static_cast<unsigned long long>(line),
            static_cast<unsigned long long>(cycle), actual, matches, expected[i]);
         std::exit(1);
      }
   }
}

void verify_raster() {
   const std::array<uint8_t, 8> p0_colors{{0x3e,0x4e,0x5e,0x6e,0x7e,0x8e,0x9e,0xae}};
   const std::array<uint8_t, 8> p1_colors{{0xce,0xbe,0xae,0x9e,0x8e,0x7e,0x6e,0x5e}};
   const int first = 2;
   const int last = motion_mode ? 8 : 2;
   for (int checked = first; checked <= last; ++checked) {
      if (motion_mode) {
         expect_lines(checked, kGrp0, {57,59,61,63,65,67,69,71}, "motion P0");
         expect_lines(checked, kGrp1, {179,181,183,185,187,189,191,193}, "motion P1");
         expect_lines(checked, kEnabl, {128,130,132,134}, "motion BL");
         expect_colors(checked, kColup0, 59, 17, p0_colors, "motion P0 colors");
         expect_colors(checked, kColup1, 179, 11, p1_colors, "motion P1 colors");
      }
      else {
         expect_lines(checked, kGrp0, {177,179,181,183,185,187,189,191}, "static P0");
         expect_lines(checked, kGrp1, {107,109,111,113,115,117,119,121}, "static P1");
         expect_lines(checked, kEnabl, {122,124,126,128}, "static BL");
         expect_colors(checked, kColup0, 179, 17, p0_colors, "static P0 colors");
         expect_colors(checked, kColup1, 107, 11, p1_colors, "static P1 colors");
      }
   }
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 7 && argc != 8) {
      std::fprintf(stderr,
         "usage: %s static|motion ROM object_x p0_y p1_y ball_y [directions]\n", argv[0]);
      return 2;
   }
   const std::string mode = argv[1];
   motion_mode = mode == "motion";
   if (!motion_mode && mode != "static") fail("mode must be static or motion");
   if ((motion_mode && argc != 8) || (!motion_mode && argc != 7)) fail("wrong mode argument count");
   frames_to_check = motion_mode ? 320 : 4;
   object_x_zp = parse_zp(argv[3]);
   y_zp = {{parse_zp(argv[4]), parse_zp(argv[5]), parse_zp(argv[6])}};
   if (motion_mode) direction_zp = parse_zp(argv[7]);
   else expected_x = {{44,108,0,0,78}};

   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[2], std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize))
      fail("ROM is not exactly 4096 bytes");

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   constexpr uint64_t kInstructionLimit = 250000000;
   for (uint64_t instructions = 0;
        instructions < kInstructionLimit && frame < frames_to_check;
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < frames_to_check) fail("instruction limit reached before verification completed");
   if (frame_periods.size() < static_cast<size_t>(frames_to_check))
      fail("missing frame-period samples");
   for (uint64_t period : frame_periods) {
      if (period != kExpectedFrameCycles) {
         std::fprintf(stderr,
            "vcs_standard_playercolors: frame period is %llu; expected %llu\n",
            static_cast<unsigned long long>(period),
            static_cast<unsigned long long>(kExpectedFrameCycles));
         return 1;
      }
   }
   if (missile0_enabled || missile1_enabled) fail("missile enable became active");
   verify_positioning();
   verify_raster();
   if (motion_mode) {
      for (size_t i = 0; i < 3; ++i) {
         if (!saw_low[i] || !saw_high[i]) fail("a supported object did not reach both X endpoints");
      }
      std::printf("vcs_standard_playercolors motion ok: 320 frames, full-range P0/P1/BL motion, exact row colors\n");
   }
   else {
      std::printf("vcs_standard_playercolors static ok: exact P0/P1 row colors, BL raster, no missiles\n");
   }
   return 0;
}
