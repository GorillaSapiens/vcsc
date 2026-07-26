//! @file vcs_player_color_181.cpp
//! @brief Verify the official 181-line P0/P1/BL per-row-color component.

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
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kPf0 = 0x000D;
constexpr uint16_t kPf1 = 0x000E;
constexpr uint16_t kPf2 = 0x000F;
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
struct CompositionStats {
   int visible_start = -1;
   int overscan_line = -1;
   unsigned game_pf = 0;
   unsigned game_grp = 0;
   unsigned game_ball = 0;
   unsigned game_missiles = 0;
   unsigned score_pf = 0;
   unsigned score_grp = 0;
   unsigned score_objects = 0;
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
std::map<int, CompositionStats> composition_stats;

enum class ScoreOrder { None, Above, Below };
ScoreOrder score_order = ScoreOrder::None;
bool poison_score = false;
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
   std::fprintf(stderr, "vcs_player_color_181: %s\n", message);
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
      : std::array<uint8_t, 3>{{70, 42, 45}};
   for (size_t i = 0; i < expected_y.size(); ++i) {
      if (memory_image[y_zp[i]] != expected_y[i]) {
         std::fprintf(stderr,
            "vcs_player_color_181: frame %d Y%zu is %u; expected %u\n",
            frame, i, memory_image[y_zp[i]], expected_y[i]);
         std::exit(1);
      }
   }
   if (!motion_mode) return;

   for (size_t object = 0; object < ObjectCount; ++object) {
      const uint8_t actual = memory_image[static_cast<uint8_t>(object_x_zp + object)];
      if (actual != expected_x[object]) {
         std::fprintf(stderr,
            "vcs_player_color_181: frame %d object %zu X is %u; expected %u\n",
            frame, object, actual, expected_x[object]);
         std::exit(1);
      }
   }
   if (memory_image[direction_zp] != expected_directions) {
      std::fprintf(stderr,
         "vcs_player_color_181: frame %d directions are %02X; expected %02X\n",
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

void classify_composition_write(const WriteEvent &event) {
   if (score_order == ScoreOrder::None || frame < 0 || frame >= frames_to_check) return;
   const uint64_t relative = virtual_cycles - frame_start;
   const unsigned line = static_cast<unsigned>(relative / kCyclesPerScanline);
   CompositionStats &stats = composition_stats[frame];
   if (event.address == kVblank) {
      if (event.value == 0) stats.visible_start = static_cast<int>(line);
      else if ((event.value & 2) != 0) stats.overscan_line = static_cast<int>(line);
      return;
   }
   const unsigned score_first = score_order == ScoreOrder::Above ? 40 : 221;
   const unsigned game_first = score_order == ScoreOrder::Above ? 51 : 40;
   const bool in_score = line >= score_first && line < score_first + 11;
   const bool in_game = line >= game_first && line < game_first + 181;
   if (!in_score && !in_game) return;
   const bool pf = event.address >= kPf0 && event.address <= kPf2 && event.value != 0;
   const bool grp = (event.address == kGrp0 || event.address == kGrp1) && event.value != 0;
   const bool object = (event.address == kEnam0 || event.address == kEnam1 || event.address == kEnabl) &&
                       (event.value & 2) != 0;
   if (in_score) {
      if (pf) ++stats.score_pf;
      if (grp) ++stats.score_grp;
      if (object) ++stats.score_objects;
   }
   else {
      if (pf) ++stats.game_pf;
      if (grp) ++stats.game_grp;
      if ((event.address == kEnam0 || event.address == kEnam1) &&
          (event.value & 2) != 0) ++stats.game_missiles;
      if (event.address == kEnabl && (event.value & 2) != 0) ++stats.game_ball;
   }
}

void apply_writes() {
   for (const WriteEvent &event : writes) {
      classify_composition_write(event);
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
               if (line < 232) {
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
               "vcs_player_color_181: frame %d object %zu X=%u RESP=%d/%d HMP=%02X/%02X\n",
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
      if (score_order != ScoreOrder::None) {
         const uint64_t game_first = score_order == ScoreOrder::Above ? 51 : 40;
         if (write.line < game_first || write.line >= game_first + 181) continue;
      }
      const bool active = address == kEnabl ? (write.value & 2) != 0 : write.value != 0;
      if (write.address == address && active) out.push_back(write.line);
   }
   return out;
}

void expect_lines(int raster_frame, uint16_t address, const std::vector<uint64_t> &expected,
                  const char *name) {
   const std::vector<uint64_t> actual = active_lines(raster_frame, address);
   if (actual == expected) return;
   std::fprintf(stderr, "vcs_player_color_181: %s lines:", name);
   for (uint64_t line : actual) std::fprintf(stderr, " %llu", static_cast<unsigned long long>(line));
   std::fprintf(stderr, "; expected:");
   for (uint64_t line : expected) std::fprintf(stderr, " %llu", static_cast<unsigned long long>(line));
   std::fputc('\n', stderr);
   std::exit(1);
}


std::vector<uint64_t> shifted(std::initializer_list<uint64_t> lines, uint64_t offset) {
   std::vector<uint64_t> out;
   out.reserve(lines.size());
   for (uint64_t line : lines) out.push_back(line + offset);
   return out;
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
            "vcs_player_color_181: %s row %zu at line %llu cycle %llu is %02X (%u writes); expected %02X\n",
            name, i, static_cast<unsigned long long>(line),
            static_cast<unsigned long long>(cycle), actual, matches, expected[i]);
         std::exit(1);
      }
   }
}

void verify_raster() {
   const uint64_t offset = score_order == ScoreOrder::Above ? 11 : 0;
   const std::array<uint8_t, 8> p0_colors{{0x3e,0x4e,0x5e,0x6e,0x7e,0x8e,0x9e,0xae}};
   const std::array<uint8_t, 8> p1_colors{{0xce,0xbe,0xae,0x9e,0x8e,0x7e,0x6e,0x5e}};
   const int first = 2;
   const int last = motion_mode ? 8 : 2;
   for (int checked = first; checked <= last; ++checked) {
      if (motion_mode) {
         expect_lines(checked, kGrp0, shifted({61,63,65,67,69,71,73,75}, offset), "motion P0");
         expect_lines(checked, kGrp1, shifted({183,185,187,189,191,193,195,197}, offset), "motion P1");
         expect_lines(checked, kEnabl, shifted({132,134,136,138}, offset), "motion BL");
         expect_colors(checked, kColup0, 63 + offset, 17, p0_colors, "motion P0 colors");
         expect_colors(checked, kColup1, 183 + offset, 11, p1_colors, "motion P1 colors");
      }
      else {
         expect_lines(checked, kGrp0, shifted({165,167,169,171,173,175,177,179}, offset), "static P0");
         expect_lines(checked, kGrp1, shifted({111,113,115,117,119,121,123,125}, offset), "static P1");
         expect_lines(checked, kEnabl, shifted({126,128,130,132}, offset), "static BL");
         expect_colors(checked, kColup0, 167 + offset, 17, p0_colors, "static P0 colors");
         expect_colors(checked, kColup1, 111 + offset, 11, p1_colors, "static P1 colors");
      }
   }
}

void verify_composition() {
   if (score_order == ScoreOrder::None) return;
   const int last = motion_mode ? 8 : 3;
   for (int checked = 2; checked <= last; ++checked) {
      const auto found = composition_stats.find(checked);
      if (found == composition_stats.end()) fail("missing composition frame statistics");
      const CompositionStats &stats = found->second;
      if (stats.visible_start != 39) fail("VBLANK clear is not immediately before visible line 40");
      if (stats.overscan_line != 231) {
         std::fprintf(stderr, "vcs_player_color_181: frame %d overscan line %d\n", checked, stats.overscan_line);
         fail("181+11 composition does not end immediately before line 232");
      }
      if (stats.game_pf < 100) fail("game region did not emit the playfield");
      if (stats.game_grp < 8 || stats.game_ball < 2)
         fail("game region did not emit P0/P1/BL activity");
      if (stats.game_missiles != 0)
         fail("game region inherited an enabled missile");
      if (poison_score) {
         if (stats.score_pf < 3 || stats.score_grp < 2 || stats.score_objects < 3)
            fail("poison score region did not emit hostile TIA activity");
      }
      else {
         if (stats.score_grp < 16) fail("score region did not emit six-glyph activity");
         if (stats.score_pf != 0 || stats.score_objects != 0)
            fail("score region leaked playfield, missile, or ball activity");
      }
   }
}
} // namespace

int main(int argc, char **argv) {
   if (argc < 7 || argc > 9) {
      std::fprintf(stderr,
         "usage: %s static|motion ROM object_x p0_y p1_y ball_y [directions] [above|below|poison-above|poison-below|poison-prior]\n", argv[0]);
      return 2;
   }
   const std::string mode = argv[1];
   motion_mode = mode == "motion";
   if (!motion_mode && mode != "static") fail("mode must be static or motion");
   const int base_argc = motion_mode ? 8 : 7;
   if (argc != base_argc && argc != base_argc + 1) fail("wrong mode argument count");
   if (argc == base_argc + 1) {
      const std::string order = argv[base_argc];
      if (order == "above") score_order = ScoreOrder::Above;
      else if (order == "below") score_order = ScoreOrder::Below;
      else if (order == "poison-above") {
         score_order = ScoreOrder::Above;
         poison_score = true;
      }
      else if (order == "poison-below") {
         score_order = ScoreOrder::Below;
         poison_score = true;
      }
      else if (order == "poison-prior") {
         score_order = ScoreOrder::None;
         poison_score = true;
      }
      else fail("score order must be above, below, poison-above, poison-below, or poison-prior");
   }
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
   for (size_t i = 2; i < frame_periods.size(); ++i) {
      const uint64_t period = frame_periods[i];
      if (period < 262 * kCyclesPerScanline || period >= 263 * kCyclesPerScanline) {
         std::fprintf(stderr,
            "vcs_player_color_181: frame period is %llu cycles; expected 262 raw lines\n",
            static_cast<unsigned long long>(period));
         return 1;
      }
   }
   if (!poison_score && (missile0_enabled || missile1_enabled))
      fail("missile enable became active");
   verify_positioning();
   verify_raster();
   verify_composition();
   if (motion_mode) {
      for (size_t i = 0; i < 3; ++i) {
         if (!saw_low[i] || !saw_high[i]) fail("a supported object did not reach both X endpoints");
      }
      if (score_order == ScoreOrder::None)
         std::printf("vcs_player_color_181 motion ok: 320 frames, full-range P0/P1/BL motion, exact row colors\n");
      else
         std::printf("vcs_player_color_181 composition motion %s%s ok\n",
                     poison_score ? "poison-" : "",
                     score_order == ScoreOrder::Above ? "above" : "below");
   }
   else {
      if (score_order == ScoreOrder::None)
         std::printf("vcs_player_color_181 static ok: exact P0/P1 row colors, BL raster, no missiles\n");
      else
         std::printf("vcs_player_color_181 composition static %s%s ok\n",
                     poison_score ? "poison-" : "",
                     score_order == ScoreOrder::Above ? "above" : "below");
   }
   return 0;
}
