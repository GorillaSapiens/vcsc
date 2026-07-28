//! @file vcs_player_color_192.cpp
//! @brief Verify the official 192-line P0/P1/BL per-row-color component.

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
constexpr uint16_t kRomBase=0xF000;
constexpr size_t kRomSize=4096;
constexpr uint64_t kCyclesPerLine=76;
constexpr uint16_t kVsync=0x0000;
constexpr uint16_t kVblank=0x0001;
constexpr uint16_t kWsync=0x0002;
constexpr uint16_t kNusiz0=0x0004;
constexpr uint16_t kNusiz1=0x0005;
constexpr uint16_t kColup0=0x0006;
constexpr uint16_t kColup1=0x0007;
constexpr uint16_t kResp0=0x0010;
constexpr uint16_t kResp1=0x0011;
constexpr uint16_t kResbl=0x0014;
constexpr uint16_t kGrp0=0x001B;
constexpr uint16_t kGrp1=0x001C;
constexpr uint16_t kEnam0=0x001D;
constexpr uint16_t kEnam1=0x001E;
constexpr uint16_t kEnabl=0x001F;
constexpr uint16_t kHmp0=0x0020;
constexpr uint16_t kHmp1=0x0021;
constexpr uint16_t kHmbl=0x0024;
constexpr uint16_t kHmove=0x002A;
constexpr uint16_t kIntim=0x0284;
constexpr uint16_t kTim1t=0x0294;
constexpr uint16_t kTim8t=0x0295;
constexpr uint16_t kTim64t=0x0296;
constexpr uint16_t kT1024t=0x0297;

struct Write { uint16_t address; uint8_t value; };
struct TimedWrite {
   uint64_t line;
   uint64_t cycle;
   uint64_t beam_cycle;
   uint16_t address;
   uint8_t value;
};
uint8_t memory_image[65536];
uint64_t virtual_cycles=0;
uint64_t cpu_cycles=0;
std::vector<Write> writes;
std::vector<TimedWrite> frame_writes;
std::vector<uint64_t> frame_periods;
bool vsync_asserted=false;
int frame=-1;
uint64_t frame_start=0;
bool timer_active=false;
uint64_t timer_start=0;
uint16_t timer_divisor=1;
uint8_t timer_loaded=0;
std::array<uint8_t,3> y_address{};
std::array<uint8_t,3> expected_y{};

[[noreturn]] void fail(const std::string &message) {
   std::fprintf(stderr,"vcs_player_color_192: %s\n",message.c_str());
   std::exit(1);
}
uint8_t parse_zp(const char *text) {
   char *end=nullptr;
   const unsigned long value=std::strtoul(text,&end,0);
   if (!text[0] || !end || *end || value>0xff) fail("bad zero-page argument");
   return static_cast<uint8_t>(value);
}
uint8_t timer_value() {
   if (!timer_active) return memory_image[kIntim];
   const uint64_t ticks=(virtual_cycles-timer_start)/timer_divisor;
   if (ticks<=timer_loaded) return static_cast<uint8_t>(timer_loaded-ticks);
   return static_cast<uint8_t>(255-((ticks-timer_loaded-1)&255));
}
uint8_t read_bus(uint16_t address) {
   return address==kIntim ? timer_value() : memory_image[address];
}
void write_bus(uint16_t address,uint8_t value) {
   if (address<kRomBase) memory_image[address]=value;
   writes.push_back({address,value});
}
void clock_cycle(mos6502 *) {}
void verify_public_y() {
   if (frame<0) return;
   for (size_t i=0;i<expected_y.size();++i) {
      if (memory_image[y_address[i]]!=expected_y[i]) {
         std::fprintf(stderr,"vcs_player_color_192: frame %d Y%zu is %u; expected %u\n",
                      frame,i,memory_image[y_address[i]],expected_y[i]);
         std::exit(1);
      }
   }
}
void apply_writes() {
   for (const Write &event:writes) {
      if (frame==2 && event.address!=kWsync && event.address!=kVsync) {
         const uint64_t relative=virtual_cycles-frame_start;
         frame_writes.push_back({relative/kCyclesPerLine,relative%kCyclesPerLine,
                                 virtual_cycles%kCyclesPerLine,event.address,event.value});
      }
      if (event.address==kWsync) {
         const uint64_t phase=virtual_cycles%kCyclesPerLine;
         virtual_cycles+=phase ? kCyclesPerLine-phase : kCyclesPerLine;
      }
      else if (event.address==kVsync) {
         const bool next=(event.value&2)!=0;
         if (next && !vsync_asserted) {
            if (frame>=0) frame_periods.push_back(virtual_cycles-frame_start);
            ++frame;
            frame_start=virtual_cycles;
            verify_public_y();
         }
         vsync_asserted=next;
      }
      else if (event.address>=kTim1t && event.address<=kT1024t) {
         timer_active=true;
         timer_start=virtual_cycles;
         timer_loaded=event.value;
         timer_divisor=event.address==kTim1t ? 1 : event.address==kTim8t ? 8 :
                       event.address==kTim64t ? 64 : 1024;
      }
   }
   writes.clear();
}
const TimedWrite *find_write(uint16_t address,uint64_t line,uint64_t cycle) {
   for (const TimedWrite &event:frame_writes)
      if (event.address==address && event.line==line && event.cycle==cycle) return &event;
   return nullptr;
}
void expect_write(uint16_t address,uint64_t line,uint64_t cycle,uint8_t value,const char *what) {
   const TimedWrite *event=find_write(address,line,cycle);
   if (!event || event->value!=value) {
      std::fprintf(stderr,
         "vcs_player_color_192: %s missing at line %llu cycle %llu ($%02x=%02x)\n",
         what,static_cast<unsigned long long>(line),
         static_cast<unsigned long long>(cycle),address,value);
      std::exit(1);
   }
}
void expect_nonzero_lines(uint16_t address,const std::vector<uint64_t> &lines,
                          const std::vector<uint8_t> &values,const char *what) {
   std::vector<TimedWrite> got;
   for (const TimedWrite &event:frame_writes)
      if (event.address==address && event.line>=40 && event.line<232 &&
          (address==kEnabl ? (event.value&2)!=0 : event.value!=0))
         got.push_back(event);
   if (got.size()!=lines.size() || got.size()!=values.size()) {
      std::fprintf(stderr,"vcs_player_color_192: %s has %zu nonzero writes; expected %zu\n",
                   what,got.size(),lines.size());
      std::exit(1);
   }
   for (size_t i=0;i<got.size();++i) {
      if (got[i].line!=lines[i] || got[i].value!=values[i]) {
         std::fprintf(stderr,
            "vcs_player_color_192: %s write %zu is line %llu value %02x; expected line %llu value %02x\n",
            what,i,static_cast<unsigned long long>(got[i].line),got[i].value,
            static_cast<unsigned long long>(lines[i]),values[i]);
         std::exit(1);
      }
   }
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
   return 10+5*(static_cast<int>(x)/15+1);
}
uint8_t expected_resp_value(uint8_t x) {
   int remainder=x;
   do remainder-=15; while (remainder>=0);
   return static_cast<uint8_t>(remainder);
}
void verify_positioning() {
   const std::array<uint8_t,3> x{{44,108,78}};
   const std::array<uint16_t,3> resp{{kResp0,kResp1,kResbl}};
   const std::array<uint16_t,3> hmp{{kHmp0,kHmp1,kHmbl}};
   const std::array<uint64_t,3> line{{14,13,12}};
   for (size_t i=0;i<x.size();++i) {
      const int rc=expected_resp_cycle(x[i]);
      expect_write(resp[i],line[i],static_cast<uint64_t>(rc),expected_resp_value(x[i]),"VBLANK RESP");
      expect_write(hmp[i],line[i],static_cast<uint64_t>(rc+11),expected_hmp(x[i]),"VBLANK HMP");
   }
   expect_write(kHmove,14,71,0,"VBLANK HMOVE");
   for (const TimedWrite &event:frame_writes) {
      const bool position=(event.address>=kResp0 && event.address<=kResbl) ||
                          (event.address>=kHmp0 && event.address<=kHmbl) ||
                          event.address==kHmove;
      if (position && event.line>=40 && event.line<232)
         fail("object positioning leaked into visible scanlines");
   }
   uint8_t nusiz0=0,nusiz1=0;
   for (const TimedWrite &event:frame_writes) {
      if (event.line>=40) continue;
      if (event.address==kNusiz0) nusiz0=event.value;
      if (event.address==kNusiz1) nusiz1=event.value;
   }
   if (nusiz0!=0x20 || nusiz1!=0x20) fail("NUSIZ was not restored before visible drawing");
}
void verify_boundaries() {
   bool visible=false,overscan=false;
   uint64_t visible_line=0;
   for (const TimedWrite &event:frame_writes) {
      if (event.address!=kVblank) continue;
      if (event.line==39 && event.value==0) {
         visible=true;
         visible_line=event.line;
      }
      // The terminal WSYNC returns draw() at cycle zero of line 232.  With the
      // caller's immediate LDA/STA sequence, VBLANK must land at physical beam
      // cycle five exactly 192 lines after the visible-phase transition.  The
      // trace's frame-relative line/cycle pair is offset by the VSYNC entry
      // phase, so beam_cycle is the authoritative horizontal phase here.
      if (visible && event.line==visible_line+192 && event.beam_cycle==5 &&
          (event.value&2)) overscan=true;
   }
   if (!visible || !overscan) {
      for (const TimedWrite &event:frame_writes)
         if (event.address==kVblank)
            std::fprintf(stderr,"vcs_player_color_192: VBLANK line %llu cycle %llu value %02x\n",
                         static_cast<unsigned long long>(event.line),
                         static_cast<unsigned long long>(event.cycle),event.value);
   }
   if (!visible) fail("VBLANK was not cleared immediately before line 40");
   if (!overscan) fail("VBLANK was not asserted at beam cycle five after 192 visible lines");
}
} // namespace

int main(int argc,char **argv) {
   if (argc!=7) {
      std::fprintf(stderr,"usage: %s static|terminal ROM object_x p0_y p1_y ball_y\n",argv[0]);
      return 2;
   }
   const std::string mode=argv[1];
   if (mode!="static" && mode!="terminal") fail("mode must be static or terminal");
   y_address={{parse_zp(argv[4]),parse_zp(argv[5]),parse_zp(argv[6])}};
   expected_y=mode=="static" ? std::array<uint8_t,3>{{70,42,45}} :
                               std::array<uint8_t,3>{{89,89,89}};

   std::memset(memory_image,0,sizeof(memory_image));
   std::ifstream rom(argv[2],std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image+kRomBase),kRomSize);
   if (rom.gcount()!=static_cast<std::streamsize>(kRomSize)) fail("ROM is not 4096 bytes");

   mos6502 cpu(read_bus,write_bus,clock_cycle);
   cpu.Reset();
   constexpr uint64_t kInstructionLimit=100000000;
   for (uint64_t instructions=0;instructions<kInstructionLimit && frame<4;++instructions) {
      writes.clear();
      const uint64_t before=cpu_cycles;
      cpu.Run(1,cpu_cycles,mos6502::INST_COUNT);
      virtual_cycles+=cpu_cycles-before;
      apply_writes();
   }
   if (frame<4) fail("instruction limit reached");
   for (size_t i=2;i<frame_periods.size();++i)
      if (frame_periods[i]!=262*kCyclesPerLine) fail("frame is not exactly 262 raw lines");

   verify_boundaries();
   verify_positioning();
   for (const TimedWrite &event:frame_writes)
      if ((event.address==kEnam0 || event.address==kEnam1) && (event.value&2))
         fail("missile enable became active");

   const std::vector<uint8_t> p0{{0x7e,0xc3,0xd3,0xcb,0xc7,0xc3,0xc3,0x7e}};
   const std::vector<uint8_t> p1{{0xfe,0xc3,0xc3,0xfe,0xc3,0xc3,0xc3,0xfe}};
   if (mode=="static") {
      expect_nonzero_lines(kGrp0,{164,166,168,170,172,174,176,178},p0,"static P0");
      expect_nonzero_lines(kGrp1,{111,113,115,117,119,121,123,125},p1,"static P1");
      expect_nonzero_lines(kEnabl,{125,127,129,131},{2,2,2,2},"static Ball");
      std::printf("vcs_player_color_192 static ok: exact 192-line frame, VBLANK positioning, P0/P1 rows, Ball, and no missiles\n");
   }
   else {
      expect_nonzero_lines(kGrp0,{202,204,206,208,210,212,214,216},p0,"terminal P0");
      expect_nonzero_lines(kGrp1,{205,207,209,211,213,215,217,219},p1,"terminal P1");
      expect_nonzero_lines(kEnabl,{213,216,217,219},{2,2,2,2},"terminal Ball");
      std::printf("vcs_player_color_192 terminal ok: P0/P1/Ball reach the uniform twelfth-row raster\n");
   }
   return 0;
}
