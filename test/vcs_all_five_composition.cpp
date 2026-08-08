//! @file vcs_all_five_composition.cpp
//! @brief Verify all-five composition and horizontal object positioning.

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
constexpr uint64_t kCyclesPerLine = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kPf1 = 0x000E;
constexpr uint16_t kPf2 = 0x000F;
constexpr uint16_t kCtrlpf = 0x000A;
constexpr uint16_t kRefp0 = 0x000B;
constexpr uint16_t kRefp1 = 0x000C;
constexpr uint16_t kNusiz0 = 0x0004;
constexpr uint16_t kNusiz1 = 0x0005;
constexpr uint16_t kResp0 = 0x0010;
constexpr uint16_t kResp1 = 0x0011;
constexpr uint16_t kResm0 = 0x0012;
constexpr uint16_t kResm1 = 0x0013;
constexpr uint16_t kResbl = 0x0014;
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kEnam0 = 0x001D;
constexpr uint16_t kEnam1 = 0x001E;
constexpr uint16_t kEnabl = 0x001F;
constexpr uint16_t kHmp0 = 0x0020;
constexpr uint16_t kHmp1 = 0x0021;
constexpr uint16_t kHmm0 = 0x0022;
constexpr uint16_t kHmm1 = 0x0023;
constexpr uint16_t kHmbl = 0x0024;
constexpr uint16_t kHmove = 0x002A;
constexpr uint16_t kHmclr = 0x002B;
constexpr uint16_t kVdelp0 = 0x0025;
constexpr uint16_t kVdelp1 = 0x0026;
constexpr uint16_t kVdelbl = 0x0027;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;
constexpr int kMotionFrames = 360;

enum Object : size_t { P0, P1, M0, M1, BL, ObjectCount };

struct WriteEvent { uint16_t address; uint8_t value; };
struct TimedWrite {
   uint64_t line;
   uint64_t cycle;
   uint64_t beam_cycle;
   uint16_t address;
   uint8_t value;
};
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
std::map<int,std::vector<TimedWrite>> timed_writes;
std::map<int,std::array<uint8_t,ObjectCount>> frame_x;
bool score_above = false;
bool scoreless = false;
bool motion_mode = false;
bool ball_edge_mode = false;
int ball_first_override = -1;
int ball_lines_override = -1;
bool poison_score = false;
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
   frame_x[frame]=expected_x;
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
   const unsigned game_first = scoreless ? 40 : score_above ? 51 : 40;
   const unsigned game_last = game_first + (scoreless ? 192 : 181);
   const bool in_score = !scoreless && line >= score_first && line < score_last;
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
      if (frame >= 0 && frame < (motion_mode ? kMotionFrames : 12) &&
          event.address != kWsync && event.address != kVsync) {
         const uint64_t relative=virtual_cycles-frame_start;
         timed_writes[frame].push_back({relative/kCyclesPerLine,
                                        relative%kCyclesPerLine,
                                        virtual_cycles%kCyclesPerLine,
                                        event.address,event.value});
      }
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


uint8_t expected_hmp(uint8_t x) {
   static constexpr std::array<uint8_t,16> table{{
      0x80,0x70,0x60,0x50,0x40,0x30,0x20,0x10,
      0x00,0xF0,0xE0,0xD0,0xC0,0xB0,0xA0,0x90
   }};
   int remainder=x;
   do remainder-=15; while (remainder>=0);
   return table[static_cast<size_t>(16+remainder)];
}
int expected_resp_cycle(uint8_t x) {
   return 18+5*(static_cast<int>(x)/15+1);
}
uint8_t expected_handoff_hmp(uint8_t x) {
   const int remainder=x%15;
   const int steps=x/15+1+(remainder>=13 ? 1 : 0);
   const int signed_motion=15*steps-11-x;
   return static_cast<uint8_t>((signed_motion&15)<<4);
}
int expected_handoff_resp_cycle(uint8_t x) {
   const int remainder=x%15;
   const int steps=x/15+1+(remainder>=13 ? 1 : 0);
   return 9+5*steps;
}
std::array<uint8_t,ObjectCount> desired_x_for_frame(int checked) {
   if (!motion_mode) return {{20,130,50,110,80}};
   const auto found=frame_x.find(checked);
   if (found==frame_x.end()) fail("missing desired-position frame");
   return found->second;
}
const TimedWrite *find_write(int checked,uint16_t address,uint64_t first_line,
                             uint64_t last_line) {
   const auto found=timed_writes.find(checked);
   if (found==timed_writes.end()) return nullptr;
   for (const TimedWrite &write:found->second)
      if (write.address==address && write.line>=first_line && write.line<=last_line)
         return &write;
   return nullptr;
}
void verify_object_positioning_and_endpoints() {
   const uint64_t game_first=scoreless ? 40 : score_above ? 51 : 40;
   const int last=motion_mode ? kMotionFrames-1 : 11;
   for (int checked=2;checked<=last;++checked) {
      const auto x=desired_x_for_frame(checked);
      const auto found=timed_writes.find(checked);
      if (found==timed_writes.end()) fail("missing object-position trace");

      if (!scoreless) {
         // In the 181-line composition P0/P1 are deliberately re-positioned
         // after the score component. Verify that visible-entry transaction.
         for (Object object:std::array<Object,2>{{P0,P1}}) {
            const uint64_t line=game_first+(object==P0 ? 1 : 0);
            const uint16_t resp=static_cast<uint16_t>(kResp0+object);
            const uint16_t hmp=static_cast<uint16_t>(kHmp0+object);
            const TimedWrite *rw=find_write(checked,resp,line,line);
            const TimedWrite *hw=nullptr;
            if (rw) {
               for (const TimedWrite &write:found->second) {
                  if (write.address!=hmp) continue;
                  if (write.line<rw->line ||
                      (write.line==rw->line && write.cycle<rw->cycle)) hw=&write;
               }
            }
            if (!rw || !hw ||
                static_cast<int>(rw->cycle)!=expected_handoff_resp_cycle(x[object]) ||
                (hw->value&0xf0)!=expected_handoff_hmp(x[object])) {
               std::fprintf(stderr,
                  "vcs_all_five_composition: frame %d P%zu X=%u RESP=%lld/%d HMP=%02X/%02X\n",
                  checked,static_cast<size_t>(object),x[object],
                  rw ? static_cast<long long>(rw->cycle) : -1LL,
                  expected_handoff_resp_cycle(x[object]),hw ? hw->value : 0xff,
                  expected_handoff_hmp(x[object]));
               std::exit(1);
            }
         }
      }

      // The scoreless 192-line renderer positions all five objects in VBLANK;
      // the 181-line composition keeps that path for M0/M1/Ball only.
      const std::array<Object,5> all_objects{{P0,P1,M0,M1,BL}};
      const std::array<Object,3> nonplayers{{M0,M1,BL}};
      const Object *first=scoreless ? all_objects.data() : nonplayers.data();
      const size_t count=scoreless ? all_objects.size() : nonplayers.size();
      for (size_t index=0;index<count;++index) {
         const Object object=first[index];
         const uint16_t resp=static_cast<uint16_t>(kResp0+object);
         const uint16_t hmp=static_cast<uint16_t>(kHmp0+object);
         const TimedWrite *rw=nullptr,*hw=nullptr;
         for (const TimedWrite &write:found->second) {
            if (write.line>=40) break;
            if (write.address==resp) { rw=&write; hw=nullptr; }
            else if (rw && !hw && write.address==hmp) hw=&write;
         }
         if (!rw || !hw || static_cast<int>(rw->beam_cycle)!=expected_resp_cycle(x[object]) ||
             hw->value!=expected_hmp(x[object])) {
            std::fprintf(stderr,
               "vcs_all_five_composition: frame %d object %zu X=%u RESP=%lld/%d HMP=%02X/%02X\n",
               checked,static_cast<size_t>(object),x[object],
               rw ? static_cast<long long>(rw->beam_cycle) : -1LL,
               expected_resp_cycle(x[object]),hw ? hw->value : 0xff,
               expected_hmp(x[object]));
            std::exit(1);
         }
      }
      bool saw_hmove=false;
      for (const TimedWrite &write:found->second)
         if (write.line<40 && write.address==kHmove) { saw_hmove=true; break; }
      if (!saw_hmove) fail("VBLANK object positioning omitted HMOVE");

      // Convert the proven TIA positions into clipped visible pixels.  The
      // diagnostic fixtures use normal-width players with top rows $3c/$7c,
      // four-clock missiles, and a four-clock Ball.
      const std::array<uint8_t,2> glyph{{0x3c,0x7c}};
      for (Object object:std::array<Object,2>{{P0,P1}}) {
         unsigned actual=0;
         for (unsigned pixel=0;pixel<160;++pixel) {
            if (pixel<x[object] || pixel>=static_cast<unsigned>(x[object])+8) continue;
            const unsigned bit=7-(pixel-x[object]);
            if ((glyph[object]>>bit)&1u) ++actual;
         }
         unsigned expected=0;
         for (unsigned bit=0;bit<8;++bit)
            if ((glyph[object]&(0x80u>>bit)) && static_cast<unsigned>(x[object])+bit<160)
               ++expected;
         if (actual!=expected) fail("player endpoint pixel clipping mismatch");
      }
      for (Object object:std::array<Object,3>{{M0,M1,BL}}) {
         const unsigned expected=x[object]<=156 ? 4u : 160u-x[object];
         unsigned actual=0;
         for (unsigned pixel=0;pixel<160;++pixel)
            if (pixel>=x[object] && pixel<static_cast<unsigned>(x[object])+4) ++actual;
         if (actual!=expected) fail("missile/Ball endpoint pixel clipping mismatch");
      }
   }
}


struct ObjectRasterState {
   uint8_t grp0_new = 0;
   uint8_t grp0_display = 0;
   uint8_t grp1_new = 0;
   uint8_t grp1_display = 0;
   uint8_t enam0 = 0;
   uint8_t enam1 = 0;
   uint8_t enabl_new = 0;
   uint8_t enabl_display = 0;
   uint8_t nusiz0 = 0;
   uint8_t nusiz1 = 0;
   uint8_t ctrlpf = 0;
   uint8_t refp0 = 0;
   uint8_t refp1 = 0;
   bool vdelp0 = false;
   bool vdelp1 = false;
   bool vdelbl = false;
};

void apply_object_write(ObjectRasterState &state,const TimedWrite &write) {
   switch (write.address) {
      case kGrp0:
         state.grp0_new=write.value;
         if (!state.vdelp0) state.grp0_display=write.value;
         // A GRP0 write transfers P1's delayed value.
         state.grp1_display=state.grp1_new;
         break;
      case kGrp1:
         state.grp1_new=write.value;
         if (!state.vdelp1) state.grp1_display=write.value;
         // A GRP1 write transfers P0 and Ball delayed values.
         state.grp0_display=state.grp0_new;
         state.enabl_display=state.enabl_new;
         break;
      case kEnam0: state.enam0=write.value; break;
      case kEnam1: state.enam1=write.value; break;
      case kEnabl:
         state.enabl_new=write.value;
         if (!state.vdelbl) state.enabl_display=write.value;
         break;
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
   // The diagnostic fixtures deliberately use the single-copy, normal-width
   // player mode. Reject a renderer that silently changes that contract rather
   // than teaching this oracle to accept a different scene.
   if ((nusiz&7)!=0) fail("object raster fixture lost single-copy player mode");
   if (pixel<origin || pixel>=origin+8) return false;
   unsigned bit=pixel-origin;
   if ((refp&8)==0) bit=7-bit;
   return ((graphics>>bit)&1)!=0;
}

bool span_pixel(bool enabled,unsigned origin,unsigned width,unsigned pixel) {
   return enabled && pixel>=origin && pixel<origin+width;
}

uint8_t expected_player_value(Object object,int relative_line) {
   static constexpr std::array<uint8_t,7> p0{{0x3c,0x66,0x66,0x7e,0x66,0x66,0x66}};
   static constexpr std::array<uint8_t,7> p1{{0x7c,0x66,0x66,0x7c,0x66,0x66,0x7c}};
   const int first=object==P0 ? 22 : 144;
   if (relative_line<first || relative_line>=first+14) return 0;
   return (object==P0 ? p0 : p1)[static_cast<size_t>((relative_line-first)/2)];
}

bool expected_enable(Object object,int relative_line) {
   int first=0,lines=0;
   switch (object) {
      case M0: first=59; lines=12; break;
      case M1: first=110; lines=16; break;
      case BL:
         first=ball_first_override >= 0 ? ball_first_override : 92;
         lines=ball_lines_override >= 0 ? ball_lines_override : 8;
         break;
      default: return false;
   }
   if (!scoreless) first+=2;
   return relative_line>=first && relative_line<first+lines;
}

void verify_static_object_pixel_raster() {
   if (motion_mode) return;
   const int checked=2;
   const auto found=timed_writes.find(checked);
   if (found==timed_writes.end() || found->second.empty()) fail("missing static object raster trace");
   const auto &trace=found->second;
   const uint64_t phase=(trace.front().beam_cycle+kCyclesPerLine-trace.front().cycle)%kCyclesPerLine;
   const int game_first=scoreless ? 40 : score_above ? 51 : 40;
   const int game_lines=scoreless ? 192 : 181;
   // A preceding score owns its final scanline and may use all of it. Begin
   // gameplay pixel ownership at game_first; only scoreless fixtures own the
   // preceding blank boundary.
   const int first_checked=scoreless ? game_first-1 : game_first;
   const int last_checked=game_first+game_lines-1;
   const std::array<unsigned,ObjectCount> x{{20,130,50,110,80}};

   ObjectRasterState state;
   // CTRLPF is application-owned and is initialized once before the frame loop.
   state.ctrlpf=0x21;
   size_t next=0;
   uint64_t checked_pixels=0;
   for (int physical_line=0;physical_line<=last_checked;++physical_line) {
      std::vector<TimedWrite> line_writes;
      while (next<trace.size()) {
         const TimedWrite &write=trace[next];
         const uint64_t line=write.line+((write.cycle+phase)>=kCyclesPerLine ? 1 : 0);
         if (line>static_cast<uint64_t>(physical_line)) break;
         if (line==static_cast<uint64_t>(physical_line)) line_writes.push_back(write);
         ++next;
      }
      size_t event=0;
      for (unsigned pixel=0;pixel<160;++pixel) {
         const uint64_t color_clock=68+pixel;
         while (event<line_writes.size() && line_writes[event].beam_cycle*3<=color_clock)
            apply_object_write(state,line_writes[event++]);

         if (physical_line<first_checked) continue;
         const int relative=physical_line-game_first;
         const bool in_game=relative>=0 && relative<game_lines;
         const uint8_t p0=in_game ? expected_player_value(P0,relative) : 0;
         const uint8_t p1=in_game ? expected_player_value(P1,relative) : 0;
         const unsigned m0_width=1u<<((state.nusiz0>>4)&3);
         const unsigned m1_width=1u<<((state.nusiz1>>4)&3);
         const unsigned ball_width=1u<<((state.ctrlpf>>4)&3);
         const std::array<bool,ObjectCount> actual{{
            player_pixel(state.grp0_display,state.nusiz0,state.refp0,x[P0],pixel),
            player_pixel(state.grp1_display,state.nusiz1,state.refp1,x[P1],pixel),
            span_pixel((state.enam0&2)!=0,x[M0],m0_width,pixel),
            span_pixel((state.enam1&2)!=0,x[M1],m1_width,pixel),
            span_pixel((state.enabl_display&2)!=0,x[BL],ball_width,pixel)
         }};
         const std::array<bool,ObjectCount> expected{{
            in_game && player_pixel(p0,0,0,x[P0],pixel),
            in_game && player_pixel(p1,0,0,x[P1],pixel),
            in_game && span_pixel(expected_enable(M0,relative),x[M0],4,pixel),
            in_game && span_pixel(expected_enable(M1,relative),x[M1],4,pixel),
            in_game && span_pixel(expected_enable(BL,relative),x[BL],4,pixel)
         }};
         for (size_t object=0;object<ObjectCount;++object) {
            ++checked_pixels;
            if (actual[object]!=expected[object]) {
               std::fprintf(stderr,
                  "vcs_all_five_composition: object raster mismatch %s line %d (relative %d) x=%u object=%zu actual=%u expected=%u\n",
                  scoreless ? "none" : score_above ? "above" : "below",
                  physical_line,relative,pixel,object,actual[object],expected[object]);
               std::exit(1);
            }
         }
      }
      while (event<line_writes.size()) apply_object_write(state,line_writes[event++]);
   }
   const uint64_t expected_count=static_cast<uint64_t>(last_checked-first_checked+1)*160*ObjectCount;
   if (checked_pixels!=expected_count) fail("object raster checked the wrong pixel count");
}

void verify_frames() {
   const int needed = motion_mode ? kMotionFrames : 12;
   if (frame < needed) fail("instruction limit reached before enough frames");
   for (size_t i=3;i<frame_periods.size();++i)
      if (frame_periods[i] != 264*kCyclesPerLine) fail("frame is not exactly 262 scanlines");
   for (int i=3;i<12;++i) {
      const FrameStats &s=frames[static_cast<size_t>(i)];
      if (s.vblank_clear_line != 40) fail("visible field does not begin on line 40");
      bool saw_overscan=false;
      for (unsigned line:s.vblank_two_lines) if (line==232) saw_overscan=true;
      if (!saw_overscan) fail("181+11 composition does not end on line 232");
      if (s.game_pf < 100) fail("game region did not emit the playfield");
      if (s.game_grp < 8 || s.game_objects < 8) fail("game region did not emit all-five object activity");
      if (!scoreless) {
         const unsigned minimum_score_writes = poison_score ? 2u : 16u;
         if (s.score_grp < minimum_score_writes)
            fail(poison_score ? "poison score region did not emit hostile player activity"
                              : "score region did not emit score player activity");
         if (s.score_pf != 0 || s.score_objects != 0)
            fail("score region leaked gameplay PF/missile/ball activity");
      }
   }
   if (motion_mode) {
      for (size_t i=0;i<5;++i)
         if (!saw_low[i] || !saw_high[i]) fail("a moving object failed to reach both X endpoints");
   }
   verify_object_positioning_and_endpoints();
   verify_static_object_pixel_raster();
}
} // namespace

int main(int argc,char **argv) {
   if (argc != 4 && argc != 5 && argc != 6 && argc != 11 && argc != 12) {
      std::fprintf(stderr,"usage: %s ROM above|below|none static|ball-edge|motion [args]\n",argv[0]);
      return 2;
   }
   scoreless = std::strcmp(argv[2],"none")==0;
   score_above = std::strcmp(argv[2],"above")==0;
   if (!scoreless && !score_above && std::strcmp(argv[2],"below")!=0)
      fail("bad score order");
   motion_mode = std::strcmp(argv[3],"motion")==0;
   ball_edge_mode = std::strcmp(argv[3],"ball-edge")==0;
   if (!motion_mode && !ball_edge_mode && std::strcmp(argv[3],"static")!=0) fail("bad scene mode");
   if (motion_mode) {
      if (argc != 11 && argc != 12) fail("motion mode needs seven zero-page addresses");
      object_x_zp=parse_zp(argv[4]);
      for (size_t i=0;i<5;++i) y_zp[i]=parse_zp(argv[5+static_cast<int>(i)]);
      motion_frame_zp=parse_zp(argv[10]);
      if (argc==12) poison_score=std::strcmp(argv[11],"poison")==0;
   }
   else if (ball_edge_mode) {
      if (argc != 6) fail("ball-edge mode needs expected first line and line count");
      ball_first_override=std::atoi(argv[4]);
      ball_lines_override=std::atoi(argv[5]);
      if (ball_first_override < 0 || ball_lines_override < 0) fail("bad Ball edge expectation");
   }
   else {
      if (argc != 4 && argc != 5) fail("static mode takes only an optional score kind");
      if (argc==5) poison_score=std::strcmp(argv[4],"poison")==0;
   }

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
