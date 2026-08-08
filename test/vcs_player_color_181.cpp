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
constexpr uint16_t kSwcha = 0x0280;
constexpr uint16_t kSwchb = 0x0282;
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
constexpr uint16_t kCtrlpf = 0x000A;
constexpr uint16_t kRefp0 = 0x000B;
constexpr uint16_t kRefp1 = 0x000C;
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
constexpr uint16_t kHmove = 0x002A;
constexpr uint16_t kHmclr = 0x002B;
constexpr uint16_t kVdelp0 = 0x0025;
constexpr uint16_t kVdelp1 = 0x0026;
constexpr uint16_t kVdelbl = 0x0027;
constexpr uint16_t kNusiz0 = 0x0004;
constexpr uint16_t kNusiz1 = 0x0005;
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
   uint64_t beam_cycle;
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
bool interactive_artwork = false;
enum class TerminalMode { None, Lines181, Lines192 };
TerminalMode terminal_mode = TerminalMode::None;
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
      : terminal_mode == TerminalMode::Lines181
         ? std::array<uint8_t, 3>{{89, 88, 88}}
         : terminal_mode == TerminalMode::Lines192
            ? std::array<uint8_t, 3>{{89, 89, 89}}
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

   const std::array<Object, 3> public_objects{{P0, P1, BL}};
   for (Object object : public_objects) {
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
   if (memory_image[static_cast<uint8_t>(object_x_zp + 2)] != 0x20 ||
       memory_image[static_cast<uint8_t>(object_x_zp + 3)] != 0x20)
      fail("retained NUSIZ values were corrupted by motion");
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
                              event.address == kColup1 ||
                              (event.address >= kResp0 && event.address <= kResbl) ||
                              (event.address >= kHmp0 && event.address <= kHmbl) ||
                              (event.address == kHmove || event.address == kHmclr) || event.address == kNusiz0 ||
                              event.address == kNusiz1)) {
               const uint64_t relative = virtual_cycles - frame_start;
               const uint64_t line = relative / kCyclesPerScanline;
               if (line < 232) {
                  timed_writes[frame].push_back(
                     {line, relative % kCyclesPerScanline,
                      virtual_cycles % kCyclesPerScanline,event.address,event.value});
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
   return 10 + 5 * (static_cast<int>(x) / 15 + 1);
}

uint8_t expected_handoff_hmp(uint8_t x) {
   const int remainder=x % 15;
   const int steps=x / 15 + 1 + (remainder >= 13 ? 1 : 0);
   const int signed_motion=15 * steps - 11 - x;
   return static_cast<uint8_t>((signed_motion & 15) << 4);
}
int expected_handoff_resp_cycle(uint8_t x) {
   const int remainder=x % 15;
   const int steps=x / 15 + 1 + (remainder >= 13 ? 1 : 0);
   return 9 + 5 * steps;
}

uint8_t desired_x_for_frame(int checked, Object object) {
   if (!motion_mode) {
      static constexpr std::array<uint8_t, ObjectCount> fixed{{44,108,0,0,78}};
      return fixed[object];
   }
   const auto found=frame_x.find(checked);
   if (found==frame_x.end()) fail("missing desired-position frame");
   return found->second[object];
}

const TimedWrite *find_timed(int checked, uint16_t address, uint64_t first_line,
                             uint64_t last_line) {
   const auto found=timed_writes.find(checked);
   if (found==timed_writes.end()) return nullptr;
   for (const TimedWrite &write : found->second) {
      if (write.address==address && write.line>=first_line && write.line<=last_line)
         return &write;
   }
   return nullptr;
}

void verify_visible_handoff() {
   const uint64_t game_first = score_order == ScoreOrder::Above ? 51 : 40;
   const int last = motion_mode ? frames_to_check - 1 : 3;
   for (int checked=2; checked<=last; ++checked) {
      for (Object object : std::array<Object,2>{{P0,P1}}) {
         const uint64_t line=game_first+(object==P0 ? 1 : 0);
         const uint16_t resp=static_cast<uint16_t>(kResp0+object);
         const uint16_t hmp=static_cast<uint16_t>(kHmp0+object);
         const TimedWrite *rw=find_timed(checked,resp,line,line);
         const TimedWrite *hw=nullptr;
         const auto events=timed_writes.find(checked);
         if (events!=timed_writes.end() && rw) {
            for (const TimedWrite &write : events->second) {
               if (write.address!=hmp) continue;
               if (write.line<rw->line || (write.line==rw->line && write.cycle<rw->cycle))
                  hw=&write;
            }
         }
         const uint8_t x=desired_x_for_frame(checked,object);
         if (!rw || !hw || static_cast<int>(rw->cycle)!=expected_handoff_resp_cycle(x) ||
             (hw->value & 0xf0)!=expected_handoff_hmp(x)) {
            std::fprintf(stderr,
               "vcs_player_color_181: frame %d gameplay P%zu X=%u RESP=%lld/%d HMP=%02X/%02X\n",
               checked,static_cast<size_t>(object),x,
               rw ? static_cast<long long>(rw->cycle) : -1LL,expected_handoff_resp_cycle(x),
               hw ? hw->value : 0xff,expected_handoff_hmp(x));
            std::exit(1);
         }
      }
      const TimedWrite *move=find_timed(checked,kHmove,game_first+1,game_first+2);
      const TimedWrite *n0=find_timed(checked,kNusiz0,game_first+2,game_first+2);
      const TimedWrite *n1=find_timed(checked,kNusiz1,game_first+2,game_first+2);
      if (!move || !n0 || !n1 || n0->value!=0x20 || n1->value!=0x20)
         fail("gameplay entry did not apply motion and restore both NUSIZ values");

      // Ball is positioned during VBLANK. Match the RESBL/HMBL/HMOVE
      // transaction, then require every later HMOVE in the frame to carry
      // HMBL=0. The visible-entry HMOVE must not apply Ball fine motion twice,
      // regardless of whether the score is above, below, or absent.
      const TimedWrite *br=nullptr,*bh=nullptr,*bm=nullptr;
      const auto found=timed_writes.find(checked);
      uint8_t current_hmbl=0;
      if (found!=timed_writes.end()) {
         bool after_resbl=false;
         for (const TimedWrite &write : found->second) {
            if (write.address==kHmclr) {
               if (bm) {
                  const uint64_t now=write.line*kCyclesPerScanline+write.cycle;
                  const uint64_t moved=bm->line*kCyclesPerScanline+bm->cycle;
                  if (now-moved<8)
                     fail("HMCLR interrupted Ball fine motion");
               }
               current_hmbl=0;
            }
            if (write.address==kHmbl) current_hmbl=write.value;
            if (write.address==kResbl) {
               br=&write; bh=nullptr; bm=nullptr; after_resbl=true;
            }
            else if (after_resbl && write.address==kHmbl && !bm) bh=&write;
            else if (after_resbl && write.address==kHmove) {
               if (!bm) bm=&write;
               else if (current_hmbl!=0)
                  fail("later HMOVE re-applied Ball fine motion");
            }
         }
      }
      const uint8_t bx=desired_x_for_frame(checked,BL);
      if (!br || !bh || !bm || static_cast<int>(br->cycle)!=expected_resp_cycle(bx) ||
          bh->value!=expected_hmp(bx)) {
         std::fprintf(stderr,
            "vcs_player_color_181: frame %d gameplay BL X=%u RESP=%lld/%d HMBL=%02X/%02X\n",
            checked,bx,br ? static_cast<long long>(br->cycle) : -1LL,
            expected_resp_cycle(bx),bh ? bh->value : 0xff,expected_hmp(bx));
         std::exit(1);
      }

      // Convert the observed position contracts into the concrete horizontal
      // pixel spans used by this fixture: quad-width players and a 4-pixel Ball.
      // These endpoint checks are intentionally independent of object RAM.
      const unsigned p0x=desired_x_for_frame(checked,P0);
      const unsigned p1x=desired_x_for_frame(checked,P1);
      unsigned p0_pixels=0,p1_pixels=0,ball_pixels=0;
      for (unsigned pixel=0; pixel<160; ++pixel) {
         // First visible glyph rows are $7e for P0 and $fe for P1 at quad width.
         if (pixel>=p0x && pixel<p0x+32 && ((0x7e >> (7-(pixel-p0x)/4))&1)) ++p0_pixels;
         if (pixel>=p1x && pixel<p1x+32 && ((0xfe >> (7-(pixel-p1x)/4))&1)) ++p1_pixels;
         if (pixel>=bx && pixel<static_cast<unsigned>(bx)+4) ++ball_pixels;
      }
      const unsigned expect_p0=p0x>=156 ? 0 : (p0x<=132 ? 24 : 160-(p0x+4));
      const unsigned expect_p1=p1x>=160 ? 0 : (p1x<=132 ? 28 : 160-p1x);
      const unsigned expect_ball=bx<=156 ? 4 : 160-bx;
      if (p0_pixels!=expect_p0 || p1_pixels!=expect_p1 || ball_pixels!=expect_ball)
         fail("object pixel endpoint oracle disagrees with clipped 160-pixel spans");
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
   (void)first_line;
   (void)cycle;
   const auto found = timed_writes.find(raster_frame);
   if (found == timed_writes.end()) fail("missing color raster frame");
   const uint64_t game_first = score_order == ScoreOrder::Above ? 51 : 40;
   const uint64_t game_last = game_first + 181;
   size_t next = 0;
   for (const TimedWrite &write : found->second) {
      if (write.address != address || write.line < game_first || write.line >= game_last)
         continue;
      if (write.value == expected[next] && ++next == expected.size()) return;
   }
   std::fprintf(stderr, "vcs_player_color_181: %s emitted %zu of 8 ordered colors\n",
                name, next);
   std::exit(1);
}

void expect_color_write(int raster_frame, uint16_t address, uint64_t line,
                        uint64_t cycle, uint8_t expected, const char *name) {
   const auto found=timed_writes.find(raster_frame);
   if (found==timed_writes.end()) fail("missing terminal color raster frame");
   unsigned matches=0;
   uint8_t actual=0;
   for (const TimedWrite &write : found->second) {
      if (write.address==address && write.line==line && write.cycle==cycle) {
         ++matches;
         actual=write.value;
      }
   }
   if (matches!=1 || actual!=expected) {
      std::fprintf(stderr,
         "vcs_player_color_181: %s at line %llu cycle %llu is %02X (%u writes); expected %02X\n",
         name,static_cast<unsigned long long>(line),
         static_cast<unsigned long long>(cycle),actual,matches,expected);
      std::exit(1);
   }
}

void verify_player_handoffs() {
   const uint64_t game_first = score_order == ScoreOrder::Above ? 51 : 40;
   const uint64_t game_last = game_first + 181;
   for (const auto &frame_events : timed_writes) {
      if (frame_events.first < 2) continue;
      for (const TimedWrite &write : frame_events.second) {
         if ((write.address==kGrp0 || write.address==kGrp1) &&
             write.line>=game_first+3 && write.line<game_last && write.beam_cycle>=23) {
            std::fprintf(stderr,
               "vcs_player_color_181: player-graphics handoff at frame %d line %llu beam cycle %llu reaches visible pixels\n",
               frame_events.first,static_cast<unsigned long long>(write.line),
               static_cast<unsigned long long>(write.beam_cycle));
            std::exit(1);
         }
      }
   }
}

void verify_raster() {
   if (terminal_mode != TerminalMode::None) {
      const std::array<uint8_t,8> p0{{0xae,0x3e,0x4e,0x5e,0x6e,0x7e,0x8e,0x9e}};
      const std::array<uint8_t,8> p1{{0xce,0xbe,0xae,0x9e,0x8e,0x7e,0x6e,0x5e}};
      expect_lines(2,kGrp0,{202,204,206,208,210,212,214,216},"terminal P0");
      const std::vector<uint64_t> p1_lines = terminal_mode == TerminalMode::Lines181
         ? std::vector<uint64_t>{203,205,208,210,212,214,216,218}
         : std::vector<uint64_t>{206,208,210,212,214,216,218,220};
      expect_lines(2,kGrp1,p1_lines,"terminal P1");
      if (terminal_mode == TerminalMode::Lines181)
         expect_lines(2,kEnabl,{213,215,217},"terminal BL");
      else
         expect_lines(2,kEnabl,{214,215,219},"terminal BL");
      expect_colors(2,kColup0,0,0,p0,"terminal P0 colors");
      expect_colors(2,kColup1,0,0,p1,"terminal P1 colors");
      return;
   }
   const uint64_t offset = score_order == ScoreOrder::Above ? 11 : 0;
   const std::array<uint8_t, 8> p0_colors = interactive_artwork
      ? std::array<uint8_t,8>{{0xae,0x9e,0x8e,0x7e,0x6e,0x5e,0x4e,0x3e}}
      : std::array<uint8_t,8>{{0x3e,0x4e,0x5e,0x6e,0x7e,0x8e,0x9e,0xae}};
   const std::array<uint8_t, 8> p1_colors = interactive_artwork
      ? std::array<uint8_t,8>{{0x5e,0x6e,0x7e,0x8e,0x9e,0xae,0xbe,0xce}}
      : std::array<uint8_t,8>{{0xce,0xbe,0xae,0x9e,0x8e,0x7e,0x6e,0x5e}};
   const int first = 2;
   const int last = motion_mode ? 8 : 2;
   for (int checked = first; checked <= last; ++checked) {
      if (motion_mode) {
         expect_lines(checked, kGrp0, shifted({60,62,64,66,68,70,72,74}, offset), "motion P0");
         expect_lines(checked, kGrp1, shifted({184,186,187,189,192,194,196,198}, offset), "motion P1");
         expect_lines(checked, kEnabl, shifted({133,135,137,139}, offset), "motion BL");
         expect_colors(checked, kColup0, 63 + offset, 17, p0_colors, "motion P0 colors");
         expect_colors(checked, kColup1, 183 + offset, 11, p1_colors, "motion P1 colors");
      }
      else {
         expect_lines(checked, kGrp0, shifted({164,166,168,170,172,174,176,178}, offset), "static P0");
         expect_lines(checked, kGrp1, shifted({112,114,116,118,120,122,123,125}, offset), "static P1");
         expect_lines(checked, kEnabl, shifted({127,129,131,133}, offset), "static BL");
         expect_colors(checked, kColup0, 167 + offset, 17, p0_colors, "static P0 colors");
         expect_colors(checked, kColup1, 111 + offset, 11, p1_colors, "static P1 colors");
      }
   }
}


struct ObjectRasterState {
   uint8_t grp0_new=0,grp0_display=0;
   uint8_t grp1_new=0,grp1_display=0;
   uint8_t enabl_new=0,enabl_display=0;
   uint8_t enam0=0,enam1=0;
   uint8_t nusiz0=0,nusiz1=0;
   uint8_t ctrlpf=0x21,refp0=0,refp1=0;
   bool vdelp0=false,vdelp1=false,vdelbl=false;
};
void apply_object_write(ObjectRasterState &state,const TimedWrite &write) {
   switch (write.address) {
      case kGrp0:
         state.grp0_new=write.value;
         if (!state.vdelp0) state.grp0_display=write.value;
         state.grp1_display=state.grp1_new;
         break;
      case kGrp1:
         state.grp1_new=write.value;
         if (!state.vdelp1) state.grp1_display=write.value;
         state.grp0_display=state.grp0_new;
         state.enabl_display=state.enabl_new;
         break;
      case kEnabl:
         state.enabl_new=write.value;
         if (!state.vdelbl) state.enabl_display=write.value;
         break;
      case kEnam0: state.enam0=write.value; break;
      case kEnam1: state.enam1=write.value; break;
      case kNusiz0: state.nusiz0=write.value; break;
      case kNusiz1: state.nusiz1=write.value; break;
      case kCtrlpf: state.ctrlpf=write.value; break;
      case kRefp0: state.refp0=write.value; break;
      case kRefp1: state.refp1=write.value; break;
      case kVdelp0: state.vdelp0=(write.value&1)!=0; break;
      case kVdelp1: state.vdelp1=(write.value&1)!=0; break;
      case kVdelbl: state.vdelbl=(write.value&1)!=0; break;
      default: break;
   }
}
bool player_pixel(uint8_t graphics,uint8_t nusiz,uint8_t refp,unsigned origin,unsigned pixel) {
   if (graphics==0) return false;
   if ((nusiz&7)!=0) fail("pixel fixture lost single-copy player mode");
   if (pixel<origin || pixel>=origin+8) return false;
   unsigned bit=pixel-origin;
   if ((refp&8)==0) bit=7-bit;
   return ((graphics>>bit)&1)!=0;
}
bool span_pixel(bool enabled,unsigned origin,unsigned width,unsigned pixel) {
   return enabled && pixel>=origin && pixel<origin+width;
}
uint8_t expected_display_value(const std::array<uint8_t,8> &values,int first,int line) {
   if (line<first || line>=first+16) return 0;
   return values[static_cast<size_t>((line-first)/2)];
}
void verify_object_pixel_raster() {
   if (motion_mode) return;
   const auto found=timed_writes.find(2);
   if (found==timed_writes.end() || found->second.empty()) fail("missing object pixel trace");
   const auto &trace=found->second;
   const std::array<uint8_t,8> p0 = interactive_artwork
      ? std::array<uint8_t,8>{{0x42,0xa5,0xbd,0xff,0xdb,0x7e,0x3c,0x66}}
      : (score_order==ScoreOrder::None
         ? std::array<uint8_t,8>{{0x7e,0xc3,0xd3,0xcb,0xc7,0xc3,0xc3,0x7e}}
         : std::array<uint8_t,8>{{0x7e,0xc3,0xc3,0xc7,0xcb,0xd3,0xc3,0x7e}});
   const std::array<uint8_t,8> p1 = interactive_artwork
      ? std::array<uint8_t,8>{{0xa5,0x5a,0x24,0xff,0xdb,0xff,0x66,0x3c}}
      : (score_order==ScoreOrder::None
         ? std::array<uint8_t,8>{{0xfe,0xc3,0xc3,0xfe,0xc3,0xc3,0xc3,0xfe}}
         : std::array<uint8_t,8>{{0xfe,0xc3,0xc3,0xc3,0xfe,0xc3,0xc3,0xfe}});
   int p0_first=165,p1_first=112,ball_first=127,ball_lines=8;
   int game_first=score_order==ScoreOrder::Above ? 51 : 40;
   int game_lines=181;
   if (terminal_mode==TerminalMode::Lines181) {
      p0_first=203; p1_first=204; ball_first=213; ball_lines=7;
      game_first=40;
   }
   else if (terminal_mode==TerminalMode::Lines192) {
      // This mode is retained for the 192-line compatibility fixture; its
      // dedicated 192-line harness performs the authoritative pixel check.
      return;
   }
   else if (score_order==ScoreOrder::Above) {
      p0_first+=11; p1_first+=11; ball_first+=11;
   }
   // The preceding component owns its final scanline. A full-height score may
   // legitimately keep pixels active there; gameplay ownership begins at
   // game_first. Scoreless/terminal fixtures retain the extra blank-boundary
   // check because no predecessor owns that line.
   const int first_checked=score_order==ScoreOrder::None ? game_first-1 : game_first;
   const int last_checked=game_first+game_lines-1;
   const std::array<unsigned,3> x{{44,108,78}};
   const uint64_t phase=(trace.front().beam_cycle+kCyclesPerScanline-trace.front().cycle)%kCyclesPerScanline;
   ObjectRasterState state;
   size_t next=0;
   uint64_t checked=0;
   for (int physical_line=0;physical_line<=last_checked;++physical_line) {
      std::vector<TimedWrite> events;
      while (next<trace.size()) {
         const TimedWrite &write=trace[next];
         const uint64_t line=write.line+((write.cycle+phase)>=kCyclesPerScanline ? 1 : 0);
         if (line>static_cast<uint64_t>(physical_line)) break;
         if (line==static_cast<uint64_t>(physical_line)) events.push_back(write);
         ++next;
      }
      size_t event=0;
      for (unsigned pixel=0;pixel<160;++pixel) {
         const uint64_t color_clock=68+pixel;
         while (event<events.size() && events[event].beam_cycle*3<=color_clock)
            apply_object_write(state,events[event++]);
         if (physical_line<first_checked) continue;
         const bool in_game=physical_line>=game_first && physical_line<=last_checked;
         const uint8_t want0=in_game ? expected_display_value(p0,p0_first,physical_line) : 0;
         const uint8_t want1=in_game ? expected_display_value(p1,p1_first,physical_line) : 0;
         const bool want_ball=in_game && physical_line>=ball_first && physical_line<ball_first+ball_lines;
         const unsigned ball_width=1u<<((state.ctrlpf>>4)&3);
         const std::array<bool,5> actual{{
            player_pixel(state.grp0_display,state.nusiz0,state.refp0,x[0],pixel),
            player_pixel(state.grp1_display,state.nusiz1,state.refp1,x[1],pixel),
            span_pixel((state.enam0&2)!=0,0,1,pixel),
            span_pixel((state.enam1&2)!=0,0,1,pixel),
            span_pixel((state.enabl_display&2)!=0,x[2],ball_width,pixel)
         }};
         const std::array<bool,5> expected{{
            player_pixel(want0,0,0,x[0],pixel),
            player_pixel(want1,0,0,x[1],pixel),
            false,false,
            span_pixel(want_ball,x[2],4,pixel)
         }};
         for (size_t object=0;object<actual.size();++object) {
            ++checked;
            if (actual[object]!=expected[object]) {
               std::fprintf(stderr,
                  "vcs_player_color_181: object raster mismatch line %d x=%u object=%zu actual=%u expected=%u\n",
                  physical_line,pixel,object,actual[object],expected[object]);
               std::exit(1);
            }
         }
      }
      while (event<events.size()) apply_object_write(state,events[event++]);
   }
   const uint64_t expected_count=static_cast<uint64_t>(last_checked-first_checked+1)*160*5;
   if (checked!=expected_count) fail("object raster checked the wrong pixel count");
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
         if (stats.score_grp < 2)
            fail("poison score region did not emit hostile P0/P1 activity");
         if (stats.score_pf != 0 || stats.score_objects != 0)
            fail("poison score exceeded the P0/P1 ownership contract");
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
         "usage: %s static|terminal181|terminal192|motion ROM object_x p0_y p1_y ball_y [directions] [above|below|interactive-above|interactive-below|poison-above|poison-below|poison-prior]\n", argv[0]);
      return 2;
   }
   const std::string mode = argv[1];
   motion_mode = mode == "motion";
   if (mode == "terminal181") terminal_mode=TerminalMode::Lines181;
   else if (mode == "terminal192") terminal_mode=TerminalMode::Lines192;
   if (!motion_mode && terminal_mode == TerminalMode::None && mode != "static")
      fail("mode must be static, terminal181, terminal192, or motion");
   const int base_argc = motion_mode ? 8 : 7;
   if (argc != base_argc && argc != base_argc + 1) fail("wrong mode argument count");
   if (argc == base_argc + 1) {
      const std::string order = argv[base_argc];
      if (order == "above") score_order = ScoreOrder::Above;
      else if (order == "below") score_order = ScoreOrder::Below;
      else if (order == "interactive-above") {
         score_order = ScoreOrder::Above;
         interactive_artwork = true;
      }
      else if (order == "interactive-below") {
         score_order = ScoreOrder::Below;
         interactive_artwork = true;
      }
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
      else fail("score order must be above, below, interactive-above, interactive-below, poison-above, poison-below, or poison-prior");
   }
   frames_to_check = motion_mode ? 320 : 4;
   object_x_zp = parse_zp(argv[3]);
   y_zp = {{parse_zp(argv[4]), parse_zp(argv[5]), parse_zp(argv[6])}};
   if (motion_mode) direction_zp = parse_zp(argv[7]);
   else expected_x = {{44,108,0,0,78}};

   std::memset(memory_image, 0, sizeof(memory_image));
   memory_image[kSwcha] = 0xff;
   memory_image[kSwchb] = 0xff;
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
      if (period < 264 * kCyclesPerScanline || period >= 265 * kCyclesPerScanline) {
         const auto pos=frame_x.find(static_cast<int>(i));
         if (pos!=frame_x.end())
            std::fprintf(stderr,
               "vcs_player_color_181: frame %zu period is %llu cycles at P0=%u P1=%u BL=%u; expected the 264-line raw-harness period calibrated to Stella's 262-line display\n",
               i,static_cast<unsigned long long>(period),pos->second[P0],pos->second[P1],pos->second[BL]);
         else
            std::fprintf(stderr,
               "vcs_player_color_181: frame %zu period is %llu cycles; expected the 264-line raw-harness period calibrated to Stella's 262-line display\n",
               i,static_cast<unsigned long long>(period));
         return 1;
      }
   }
   if (!poison_score && (missile0_enabled || missile1_enabled))
      fail("missile enable became active");
   verify_visible_handoff();
   verify_player_handoffs();
   verify_raster();
   verify_object_pixel_raster();
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
      if (terminal_mode == TerminalMode::Lines181)
         std::printf("vcs_player_color_181 terminal ok: complete P0/P1 colors and BL raster reach the terminal gameplay lines\n");
      else if (terminal_mode == TerminalMode::Lines192)
         std::printf("vcs_player_color_192 terminal ok: twelfth-row P0/P1 colors and BL raster reach the final gameplay band\n");
      else if (score_order == ScoreOrder::None)
         std::printf("vcs_player_color_181 static ok: exact P0/P1 row colors, P0/P1/BL position and pixel endpoints, no missiles\n");
      else
         std::printf("vcs_player_color_181 composition static %s%s ok\n",
                     poison_score ? "poison-" : "",
                     score_order == ScoreOrder::Above ? "above" : "below");
   }
   return 0;
}
