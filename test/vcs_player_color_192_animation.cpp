//! @file vcs_player_color_192_animation.cpp
//! @brief Verify the public 192-line animated-sprite gallery sequence and pixels.

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
constexpr uint16_t kRomBase=0xf000;
constexpr size_t kRomSize=4096;
constexpr uint64_t kCyclesPerLine=76;
constexpr uint16_t kVsync=0x0000;
constexpr uint16_t kVblank=0x0001;
constexpr uint16_t kWsync=0x0002;
constexpr uint16_t kNusiz0=0x0004;
constexpr uint16_t kNusiz1=0x0005;
constexpr uint16_t kColup0=0x0006;
constexpr uint16_t kColup1=0x0007;
constexpr uint16_t kRefp0=0x000b;
constexpr uint16_t kRefp1=0x000c;
constexpr uint16_t kGrp0=0x001b;
constexpr uint16_t kGrp1=0x001c;
constexpr uint16_t kVdelp0=0x0025;
constexpr uint16_t kVdelp1=0x0026;
constexpr uint16_t kIntim=0x0284;
constexpr uint16_t kSwchb=0x0282;
constexpr uint16_t kInpt4=0x003c;
constexpr uint16_t kTim1t=0x0294;
constexpr uint16_t kTim8t=0x0295;
constexpr uint16_t kTim64t=0x0296;
constexpr uint16_t kT1024t=0x0297;

struct Addresses {
   uint8_t sprite0, sprite1, animation_frame, animation_clock;
   uint8_t pause_animation, select_ready, fire_ready, object_x;
   uint8_t p0_pointer, p1_pointer;
   std::array<uint16_t,4> frame_pages{};
   std::array<uint16_t,2> color_pages{};
   uint16_t p0_colors=0, p1_colors=0;
   uint16_t pico8_palette=0;
};
struct Write { uint16_t address; uint8_t value; };
struct TimedWrite { uint64_t line, cycle, beam_cycle; uint16_t address; uint8_t value; };
struct Capture {
   uint64_t period=0;
   uint8_t sprite0=0,sprite1=0,animation_frame=0,animation_clock=0,pause=0;
   uint8_t player0_x=0,player1_x=0;
   uint16_t p0_pointer=0,p1_pointer=0;
   std::array<uint8_t,8> p0_colors{},p1_colors{};
   std::vector<TimedWrite> writes;
};

uint8_t memory_image[65536];
uint64_t virtual_cycles=0,cpu_cycles=0,frame_start=0;
bool vsync_asserted=false,timer_active=false;
uint64_t timer_start=0;
uint16_t timer_divisor=1;
uint8_t timer_loaded=0;
uint8_t swchb=0xff,inpt4=0x80;
int current_frame=-1;
std::vector<Write> pending;
std::vector<Capture> frames;
Addresses address{};

[[noreturn]] void fail(const std::string &s) {
   std::fprintf(stderr,"vcs_player_color_192_animation: %s\n",s.c_str());
   std::exit(1);
}
uint64_t parse_number(const char *s,uint64_t max) {
   char *end=nullptr; unsigned long long v=std::strtoull(s,&end,0);
   if (!s[0] || !end || *end || v>max) fail("bad numeric argument");
   return v;
}
uint8_t timer_value() {
   if (!timer_active) return memory_image[kIntim];
   const uint64_t ticks=(virtual_cycles-timer_start)/timer_divisor;
   if (ticks<=timer_loaded) return static_cast<uint8_t>(timer_loaded-ticks);
   return static_cast<uint8_t>(255-((ticks-timer_loaded-1)&255));
}
uint8_t read_bus(uint16_t a) {
   if (a==kIntim) return timer_value();
   if (a==kSwchb) return swchb;
   if (a==kInpt4) return inpt4;
   return memory_image[a];
}
void write_bus(uint16_t a,uint8_t v) {
   if (a<kRomBase) memory_image[a]=v;
   pending.push_back({a,v});
}
void clock_cycle(mos6502 *) {}
uint16_t word_at(uint8_t zp) {
   return static_cast<uint16_t>(memory_image[zp] | (memory_image[static_cast<uint8_t>(zp+1)]<<8));
}
void begin_capture() {
   Capture c;
   c.sprite0=memory_image[address.sprite0];
   c.sprite1=memory_image[address.sprite1];
   c.animation_frame=memory_image[address.animation_frame];
   c.animation_clock=memory_image[address.animation_clock];
   c.pause=memory_image[address.pause_animation];
   c.player0_x=memory_image[address.object_x];
   c.player1_x=memory_image[static_cast<uint8_t>(address.object_x+1)];
   c.p0_pointer=word_at(address.p0_pointer);
   c.p1_pointer=word_at(address.p1_pointer);
   for (size_t i=0;i<8;++i) {
      c.p0_colors[i]=memory_image[static_cast<uint16_t>(address.p0_colors+i)];
      c.p1_colors[i]=memory_image[static_cast<uint16_t>(address.p1_colors+i)];
   }
   frames.push_back(c);
}
void apply_writes() {
   for (const Write &w:pending) {
      if (current_frame>=0 && !frames.empty() && w.address!=kWsync && w.address!=kVsync) {
         const uint64_t rel=virtual_cycles-frame_start;
         frames.back().writes.push_back({rel/kCyclesPerLine,rel%kCyclesPerLine,
                                          virtual_cycles%kCyclesPerLine,w.address,w.value});
      }
      if (w.address==kWsync) {
         const uint64_t phase=virtual_cycles%kCyclesPerLine;
         virtual_cycles+=phase ? kCyclesPerLine-phase : kCyclesPerLine;
      }
      else if (w.address==kVsync) {
         const bool next=(w.value&2)!=0;
         if (next && !vsync_asserted) {
            if (current_frame>=0 && !frames.empty()) frames.back().period=virtual_cycles-frame_start;
            ++current_frame;
            frame_start=virtual_cycles;
            begin_capture();
         }
         vsync_asserted=next;
      }
      else if (w.address>=kTim1t && w.address<=kT1024t) {
         timer_active=true; timer_start=virtual_cycles; timer_loaded=w.value;
         timer_divisor=w.address==kTim1t?1:w.address==kTim8t?8:w.address==kTim64t?64:1024;
      }
   }
   pending.clear();
}
void run_until_frames(mos6502 &cpu,size_t count) {
   constexpr uint64_t limit=300000000;
   for (uint64_t n=0;n<limit && frames.size()<count;++n) {
      pending.clear(); const uint64_t before=cpu_cycles;
      cpu.Run(1,cpu_cycles,mos6502::INST_COUNT);
      virtual_cycles+=cpu_cycles-before; apply_writes();
   }
   if (frames.size()<count) fail("instruction limit reached");
}

struct PlayerState {
   uint8_t grp0_new=0,grp0_display=0,grp1_new=0,grp1_display=0;
   uint8_t nusiz0=0,nusiz1=0,refp0=0,refp1=0,colup0=0,colup1=0;
   bool vdelp0=false,vdelp1=false;
};
void apply(PlayerState &s,const TimedWrite &w) {
   switch (w.address) {
      case kGrp0: s.grp0_new=w.value; if (!s.vdelp0) s.grp0_display=w.value; s.grp1_display=s.grp1_new; break;
      case kGrp1: s.grp1_new=w.value; if (!s.vdelp1) s.grp1_display=w.value; s.grp0_display=s.grp0_new; break;
      case kNusiz0: s.nusiz0=w.value; break;
      case kNusiz1: s.nusiz1=w.value; break;
      case kRefp0: s.refp0=w.value; break;
      case kRefp1: s.refp1=w.value; break;
      case kColup0: s.colup0=w.value; break;
      case kColup1: s.colup1=w.value; break;
      case kVdelp0: s.vdelp0=(w.value&1)!=0; break;
      case kVdelp1: s.vdelp1=(w.value&1)!=0; break;
      default: break;
   }
}
bool player_pixel(uint8_t graphics,uint8_t nusiz,uint8_t refp,unsigned origin,unsigned pixel) {
   if ((nusiz&7)!=0) fail("gallery lost single-copy player mode");
   if (pixel<origin || pixel>=origin+8) return false;
   unsigned bit=pixel-origin;
   if ((refp&8)==0) bit=7-bit;
   return ((graphics>>bit)&1)!=0;
}
uint8_t source_row(uint16_t pointer,int row) {
   return memory_image[static_cast<uint16_t>(pointer+7-row)];
}
void verify_pixels(const Capture &c,size_t index) {
   const uint64_t phase=c.writes.empty()?0:
      (c.writes.front().beam_cycle+kCyclesPerLine-c.writes.front().cycle)%kCyclesPerLine;
   PlayerState state;
   size_t next=0;
   uint64_t checked=0;
   for (int line=0;line<232;++line) {
      std::vector<TimedWrite> events;
      while (next<c.writes.size()) {
         const TimedWrite &w=c.writes[next];
         const uint64_t physical=w.line+((w.cycle+phase)>=kCyclesPerLine?1:0);
         if (physical>static_cast<uint64_t>(line)) break;
         if (physical==static_cast<uint64_t>(line)) events.push_back(w);
         ++next;
      }
      size_t event=0;
      for (unsigned x=0;x<160;++x) {
         const uint64_t color_clock=68+x;
         while (event<events.size() && events[event].beam_cycle*3<=color_clock) apply(state,events[event++]);
         if (line<39) continue;
         const int row0=(line>=136 && line<152)?(line-136)/2:-1;
         const int row1=(line>=116 && line<132)?(line-116)/2:-1;
         const uint8_t want0=row0>=0?source_row(c.p0_pointer,row0):0;
         const uint8_t want1=row1>=0?source_row(c.p1_pointer,row1):0;
         const bool actual0=player_pixel(state.grp0_display,state.nusiz0,state.refp0,c.player0_x,x);
         const bool actual1=player_pixel(state.grp1_display,state.nusiz1,state.refp1,c.player1_x,x);
         const bool expected0=player_pixel(want0,0,0,c.player0_x,x);
         const bool expected1=player_pixel(want1,0,0,c.player1_x,x);
         if (actual0!=expected0 || actual1!=expected1) {
            std::fprintf(stderr,"vcs_player_color_192_animation: frame %zu pixel mismatch line %d x=%u P0 %u/%u P1 %u/%u\n",
                         index,line,x,actual0,expected0,actual1,expected1);
            std::exit(1);
         }
         if (expected0 && state.colup0!=c.p0_colors[static_cast<size_t>(7-row0)])
            fail("P0 scanline color does not match its source-derived row color");
         if (expected1 && state.colup1!=c.p1_colors[static_cast<size_t>(7-row1)])
            fail("P1 scanline color does not match its source-derived row color");
         checked+=2;
      }
      while (event<events.size()) apply(state,events[event++]);
   }
   if (checked!=static_cast<uint64_t>(232-39)*160*2) fail("wrong pixel count");
}
uint16_t frame_pointer(uint8_t sprite,uint8_t animation_frame) {
   if (sprite>=30 || animation_frame>=4) fail("invalid sprite/frame selector");
   const uint16_t page=address.frame_pages[sprite/8];
   return static_cast<uint16_t>(page+(sprite&7)*32+animation_frame*8);
}
uint16_t row_color_pointer(uint8_t sprite,uint8_t frame) {
   if (sprite>=30 || frame>=4) fail("invalid row-color selector");
   const uint16_t page=address.color_pages[sprite/16];
   return static_cast<uint16_t>(page+(sprite&15)*16+frame*4);
}
void verify_source_row_colors(const Capture &c) {
   const uint8_t frame0=static_cast<uint8_t>(c.animation_frame&3);
   const uint8_t frame1=c.sprite1==3
      ? static_cast<uint8_t>((c.animation_frame>>2)&3)
      : static_cast<uint8_t>(c.animation_frame&3);
   const std::array<uint16_t,2> pointers{{
      row_color_pointer(c.sprite0,frame0),
      row_color_pointer(c.sprite1,frame1)
   }};
   const std::array<std::array<uint8_t,8>,2> actual{{c.p0_colors,c.p1_colors}};
   for (size_t player=0;player<2;++player) {
      std::array<uint8_t,8> expected{};
      for (size_t pair=0;pair<4;++pair) {
         const uint8_t packed=memory_image[static_cast<uint16_t>(pointers[player]+pair)];
         expected[pair*2]=memory_image[static_cast<uint16_t>(address.pico8_palette+(packed&15))];
         expected[pair*2+1]=memory_image[static_cast<uint16_t>(address.pico8_palette+(packed>>4))];
      }
      if (actual[player]!=expected)
         fail(std::string(player==0?"P0":"P1")+" color table does not match the selected source frame");
   }
}
void verify_state(const Capture &c,size_t f) {
   const uint8_t step=static_cast<uint8_t>(f%125);
   const uint8_t position=static_cast<uint8_t>(16+step);
   const uint8_t pair=static_cast<uint8_t>(((f/125)*2)%30);
   const uint8_t anim=static_cast<uint8_t>((step/8)%4);
   const uint8_t anim3=static_cast<uint8_t>((step/8)%3);
   const uint8_t packed=static_cast<uint8_t>(anim | (anim3<<2));
   if (c.sprite0!=pair || c.sprite1!=pair+1 || c.animation_frame!=packed ||
       c.animation_clock!=position%8 ||
       c.player0_x!=position || c.player1_x!=position)
      fail("automatic moving-animation sequence mismatch at frame "+std::to_string(f));
   const uint16_t want0=frame_pointer(c.sprite0,c.animation_frame&3);
   const uint8_t p1_frame=c.sprite1==3?static_cast<uint8_t>((c.animation_frame>>2)&3):static_cast<uint8_t>(c.animation_frame&3);
   const uint16_t want1=frame_pointer(c.sprite1,p1_frame);
   if (c.p0_pointer!=want0 || c.p1_pointer!=want1) fail("graphics pointer sequence mismatch");
   verify_source_row_colors(c);
   if (c.pause) fail("gallery unexpectedly paused");
}
} // namespace

int main(int argc,char **argv) {
   if (argc!=21) {
      std::fprintf(stderr,"usage: %s ROM sprite0 sprite1 packed_frame clock pause select_ready fire_ready object_x p0ptr p1ptr frames0 frames1 frames2 frames3 colors0 colors1 p0colors p1colors pico8palette\n",argv[0]);
      return 2;
   }
   address.sprite0=parse_number(argv[2],255); address.sprite1=parse_number(argv[3],255);
   address.animation_frame=parse_number(argv[4],255); address.animation_clock=parse_number(argv[5],255);
   address.pause_animation=parse_number(argv[6],255); address.select_ready=parse_number(argv[7],255);
   address.fire_ready=parse_number(argv[8],255); address.object_x=parse_number(argv[9],254);
   address.p0_pointer=parse_number(argv[10],254); address.p1_pointer=parse_number(argv[11],254);
   for (size_t i=0;i<address.frame_pages.size();++i)
      address.frame_pages[i]=parse_number(argv[12+i],65535);
   for (size_t i=0;i<address.color_pages.size();++i)
      address.color_pages[i]=parse_number(argv[16+i],65535);
   address.p0_colors=parse_number(argv[18],65535);
   address.p1_colors=parse_number(argv[19],65535);
   address.pico8_palette=parse_number(argv[20],65535);

   std::memset(memory_image,0,sizeof(memory_image));
   memory_image[0x0280]=0xff;
   std::ifstream rom(argv[1],std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image+kRomBase),kRomSize);
   if (rom.gcount()!=static_cast<std::streamsize>(kRomSize)) fail("ROM is not 4096 bytes");

   mos6502 cpu(read_bus,write_bus,clock_cycle);
   cpu.Reset();

   constexpr size_t kAutomaticFrames=15*125;
   run_until_frames(cpu,kAutomaticFrames+1);
   for (size_t f=0;f<kAutomaticFrames;++f) {
      if (f>=2 && frames[f].period!=262*kCyclesPerLine) fail("frame is not exactly 262 lines");
      verify_state(frames[f],f);
      if (f>=8 && ((f%8)==0 || (f%125)==124)) verify_pixels(frames[f],f);
   }
   if (frames[kAutomaticFrames].sprite0!=0 || frames[kAutomaticFrames].sprite1!=1 ||
       frames[kAutomaticFrames].player0_x!=16 || frames[kAutomaticFrames].player1_x!=16)
      fail("automatic gallery did not wrap all fifteen pairs back to the first pair");

   size_t next=kAutomaticFrames+1;

   // Game Select advances one pair, restarts at the left edge, and does not autorepeat.
   swchb=0xfd;
   run_until_frames(cpu,next+1);
   if (frames[next].sprite0!=2 || frames[next].sprite1!=3 || frames[next].animation_frame!=0 ||
       frames[next].player0_x!=16 || frames[next].player1_x!=16)
      fail("Game Select did not advance one pair at the left edge");
   ++next;
   run_until_frames(cpu,next+1);
   if (frames[next].sprite0!=2 || frames[next].sprite1!=3 ||
       frames[next].player0_x!=17 || frames[next].player1_x!=17)
      fail("held Game Select autorepeated or stopped motion");
   ++next;
   swchb=0xff;
   run_until_frames(cpu,next+1);
   ++next;
   swchb=0xfd;
   run_until_frames(cpu,next+1);
   if (frames[next].sprite0!=4 || frames[next].sprite1!=5 ||
       frames[next].player0_x!=16 || frames[next].player1_x!=16)
      fail("second Game Select press did not advance at the left edge");
   ++next;
   swchb=0xff;

   // Left fire pauses both movement and frame animation once per press.
   inpt4=0x00;
   run_until_frames(cpu,next+1);
   const uint8_t paused_frame=frames[next].animation_frame;
   const uint8_t paused_clock=frames[next].animation_clock;
   const uint8_t paused_x=frames[next].player0_x;
   if (!frames[next].pause) fail("left fire did not pause animation");
   ++next;
   run_until_frames(cpu,next+8);
   for (size_t f=next;f<next+8;++f)
      if (!frames[f].pause || frames[f].animation_frame!=paused_frame ||
          frames[f].animation_clock!=paused_clock ||
          frames[f].player0_x!=paused_x ||
          frames[f].player1_x!=paused_x)
         fail("paused animation moved or held fire retriggered");
   next+=8;
   inpt4=0x80;
   run_until_frames(cpu,next+1);
   ++next;
   inpt4=0x00;
   run_until_frames(cpu,next+1);
   if (frames[next].pause) fail("second left-fire press did not resume animation");

   std::puts("vcs_player_color_192_animation ok: 29 four-frame animations use modulo-4 playback while source set 03 independently uses modulo-3 playback, preserve exact source pixels without displaying blank sprite 16, use source-derived row colors that move with each original frame, wrap at X=16, keep 262-line frames, and retain pair selection and pause controls");
   return 0;
}
