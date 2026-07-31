//! @file vcs_all_five_composition.cpp
//! @brief Prove 181-line all-five gameplay composes above/below an 11-line score.

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerLine = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kPf1 = 0x000E;
constexpr uint16_t kPf2 = 0x000F;
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kEnam0 = 0x001D;
constexpr uint16_t kEnam1 = 0x001E;
constexpr uint16_t kEnabl = 0x001F;
constexpr uint16_t kHmm0 = 0x0022;
constexpr uint16_t kHmm1 = 0x0023;
constexpr uint16_t kHmbl = 0x0024;
constexpr uint16_t kHmove = 0x002A;
constexpr uint16_t kHmclr = 0x002B;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;
constexpr int kMotionFrames = 360;

struct WriteEvent { uint16_t address; uint8_t value; };
struct FrameStats {
   std::vector<unsigned> vblank_two_lines;
   int vblank_clear_line = -1;
   unsigned game_pf = 0;
   unsigned game_grp = 0;
   unsigned game_objects = 0;
   unsigned score_pf = 0;
   unsigned score_grp = 0;
   unsigned score_objects = 0;
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
std::vector<FrameStats> frames;
bool score_above = false;
bool motion_mode = false;
uint8_t object_x_zp = 0;
std::array<uint8_t,5> y_zp{};
uint8_t motion_frame_zp = 0;
std::array<uint8_t,5> expected_x{{20,130,50,110,80}};
uint8_t expected_directions = 0x15;
uint8_t expected_motion_frame = 0;
std::array<bool,5> saw_low{};
std::array<bool,5> saw_high{};
std::array<uint8_t,3> nonplayer_motion{};
unsigned frame_hmoves = 0;
uint64_t first_hmove_cycle = 0;

[[noreturn]] void fail(const std::string &message) {
   std::fprintf(stderr, "vcs_all_five_composition: %s\n", message.c_str());
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
   writes.push_back({address,value});
}
void clock_cycle(mos6502 *) {}

uint8_t parse_zp(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text,&end,0);
   if (!text[0] || !end || *end || value > 0xff) fail("bad zero-page address");
   return static_cast<uint8_t>(value);
}

void move_expected(size_t object, uint8_t bit, uint8_t speed) {
   uint8_t &x = expected_x[object];
   if (expected_directions & bit) {
      const unsigned next = static_cast<unsigned>(x) + speed;
      if (next >= 160) { x = 159; expected_directions ^= bit; }
      else x = static_cast<uint8_t>(next);
   }
   else {
      if (x <= speed) { x = 0; expected_directions ^= bit; }
      else x = static_cast<uint8_t>(x - speed);
   }
}
void advance_expected() {
   ++expected_motion_frame;
   move_expected(0,0x01,1);
   move_expected(1,0x02,2);
   move_expected(2,0x04,3);
   move_expected(3,0x08,4);
   move_expected(4,0x10,5);
}

void check_motion_state() {
   if (!motion_mode || frame < 0 || frame >= kMotionFrames) return;
   static constexpr std::array<uint8_t,5> expected_y{{18,78,34,62,48}};
   for (size_t i=0;i<5;++i) {
      const uint8_t x = memory_image[static_cast<uint8_t>(object_x_zp+i)];
      if (x != expected_x[i]) {
         char buffer[160];
         std::snprintf(buffer,sizeof(buffer),"frame %d object %zu X=%u expected=%u",
                       frame,i,x,expected_x[i]);
         fail(buffer);
      }
      if (x==0) saw_low[i]=true;
      if (x==159) saw_high[i]=true;
      if (memory_image[y_zp[i]] != expected_y[i]) {
         char buffer[160];
         std::snprintf(buffer,sizeof(buffer),"frame %d object %zu Y=%u expected=%u",
                       frame,i,memory_image[y_zp[i]],expected_y[i]);
         fail(buffer);
      }
   }
   if (memory_image[motion_frame_zp] != expected_motion_frame)
      fail("motion frame counter did not advance exactly once per frame");
   advance_expected();
}

void classify_write(const WriteEvent &event) {
   if (frame < 0 || static_cast<size_t>(frame) >= frames.size()) return;
   const unsigned line = static_cast<unsigned>(virtual_cycles / kCyclesPerLine -
                                                  frame_start / kCyclesPerLine);
   FrameStats &stats = frames[static_cast<size_t>(frame)];
   if (event.address == kVblank) {
      if (event.value == 0) stats.vblank_clear_line = static_cast<int>(line);
      else if ((event.value & 2) != 0) stats.vblank_two_lines.push_back(line);
      return;
   }
   const unsigned score_first = score_above ? 40 : 221;
   const unsigned score_last = score_first + 11;
   const unsigned game_first = score_above ? 51 : 40;
   const unsigned game_last = game_first + 181;
   const bool in_score = line >= score_first && line < score_last;
   const bool in_game = line >= game_first && line < game_last;
   if (!in_score && !in_game) return;
   unsigned *pf = in_score ? &stats.score_pf : &stats.game_pf;
   unsigned *grp = in_score ? &stats.score_grp : &stats.game_grp;
   unsigned *objects = in_score ? &stats.score_objects : &stats.game_objects;
   if ((event.address == kPf1 || event.address == kPf2) && event.value) ++*pf;
   if ((event.address == kGrp0 || event.address == kGrp1) && event.value) ++*grp;
   if ((event.address == kEnam0 || event.address == kEnam1 || event.address == kEnabl) &&
       (event.value & 2)) ++*objects;
}

void apply_writes() {
   for (const WriteEvent &event : writes) {
      if (event.address == kWsync) {
         const uint64_t within = virtual_cycles % kCyclesPerLine;
         virtual_cycles += within ? kCyclesPerLine-within : kCyclesPerLine;
      }
      else if (event.address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (next && !vsync_asserted) {
            if (frame >= 0) frame_periods.push_back(virtual_cycles-frame_start);
            ++frame;
            frame_start=virtual_cycles;
            frames.emplace_back();
            frame_hmoves=0;
            first_hmove_cycle=0;
            check_motion_state();
         }
         vsync_asserted=next;
      }
      else if (event.address >= kTim1t && event.address <= kT1024t) {
         timer_active=true;
         timer_start=virtual_cycles;
         timer_loaded=event.value;
         timer_divisor=event.address==kTim1t ? 1 : event.address==kTim8t ? 8 :
                       event.address==kTim64t ? 64 : 1024;
      }
      else {
         if (event.address == kHmclr) {
            // HMCLR immediately after HMOVE aborts the motion transaction on
            // real TIA hardware. A later clear is legal, but not this one.
            if (frame >= 2 && frame_hmoves == 1 &&
                virtual_cycles - first_hmove_cycle < 8)
               fail("HMCLR interrupted missile/Ball fine motion");
            nonplayer_motion.fill(0);
         }
         else if (event.address >= kHmm0 && event.address <= kHmbl)
            nonplayer_motion[static_cast<size_t>(event.address-kHmm0)] = event.value;
         else if (event.address == kHmove && frame >= 2) {
            if (frame_hmoves != 0 &&
                (nonplayer_motion[0] != 0 || nonplayer_motion[1] != 0 ||
                 nonplayer_motion[2] != 0))
               fail("later HMOVE re-applied missile/Ball fine motion");
            if (frame_hmoves == 0) first_hmove_cycle = virtual_cycles;
            ++frame_hmoves;
         }
         classify_write(event);
      }
   }
   writes.clear();
}

void verify_frames() {
   const int needed = motion_mode ? kMotionFrames : 12;
   if (frame < needed) fail("instruction limit reached before enough frames");
   for (size_t i=3;i<frame_periods.size();++i)
      if (frame_periods[i] != 262*kCyclesPerLine) fail("frame is not exactly 262 scanlines");
   for (int i=3;i<12;++i) {
      const FrameStats &s=frames[static_cast<size_t>(i)];
      if (s.vblank_clear_line != 40) fail("visible field does not begin on line 40");
      bool saw_overscan=false;
      for (unsigned line:s.vblank_two_lines) if (line==232) saw_overscan=true;
      if (!saw_overscan) fail("181+11 composition does not end on line 232");
      if (s.game_pf < 100) fail("game region did not emit the playfield");
      if (s.game_grp < 8 || s.game_objects < 8) fail("game region did not emit all-five object activity");
      if (s.score_grp < 16) fail("score region did not emit six-glyph player activity");
      if (s.score_pf != 0 || s.score_objects != 0) fail("score region leaked gameplay PF/missile/ball activity");
   }
   if (motion_mode) {
      for (size_t i=0;i<5;++i)
         if (!saw_low[i] || !saw_high[i]) fail("a moving object failed to reach both X endpoints");
   }
}
} // namespace

int main(int argc,char **argv) {
   if (argc != 4 && argc != 11) {
      std::fprintf(stderr,"usage: %s ROM above|below static|motion [object_x p0_y p1_y m0_y m1_y ball_y motion_frame]\n",argv[0]);
      return 2;
   }
   score_above = std::strcmp(argv[2],"above")==0;
   if (!score_above && std::strcmp(argv[2],"below")!=0) fail("bad score order");
   motion_mode = std::strcmp(argv[3],"motion")==0;
   if (!motion_mode && std::strcmp(argv[3],"static")!=0) fail("bad scene mode");
   if (motion_mode) {
      if (argc != 11) fail("motion mode needs seven zero-page addresses");
      object_x_zp=parse_zp(argv[4]);
      for (size_t i=0;i<5;++i) y_zp[i]=parse_zp(argv[5+static_cast<int>(i)]);
      motion_frame_zp=parse_zp(argv[10]);
   }
   else if (argc != 4) fail("static mode takes no addresses");

   std::memset(memory_image,0,sizeof(memory_image));
   std::ifstream rom(argv[1],std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image+kRomBase),kRomSize);
   if (rom.gcount()!=static_cast<std::streamsize>(kRomSize)) fail("ROM is not exactly 4K");

   mos6502 cpu(read_bus,write_bus,clock_cycle);
   cpu.Reset();
   const int wanted = motion_mode ? kMotionFrames : 12;
   constexpr uint64_t kInstructionLimit=300000000;
   for (uint64_t instructions=0;instructions<kInstructionLimit && frame<wanted;++instructions) {
      writes.clear();
      const uint64_t before=cpu_cycles;
      cpu.Run(1,cpu_cycles,mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles-before;
      apply_writes();
   }
   verify_frames();
   std::printf("vcs_all_five_composition %s %s ok\n",argv[3],argv[2]);
   return 0;
}
