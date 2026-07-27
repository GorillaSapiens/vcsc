//! @file vcs_multicolor_display_raster.cpp
//! @brief Verify the public multicolor examples' actual TIA display tables.

#include <algorithm>
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
constexpr uint16_t kPf0 = 0x000D;
constexpr uint16_t kPf1 = 0x000E;
constexpr uint16_t kPf2 = 0x000F;
constexpr uint16_t kColup0 = 0x0006;
constexpr uint16_t kColup1 = 0x0007;
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kEnam0 = 0x001D;
constexpr uint16_t kEnam1 = 0x001E;
constexpr uint16_t kEnabl = 0x001F;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct Write { uint16_t address; uint8_t value; };
struct TimedWrite { uint64_t line; uint64_t cycle; uint16_t address; uint8_t value; };
uint8_t memory_image[65536];
uint64_t virtual_cycles = 0;
uint64_t cpu_cycles = 0;
std::vector<Write> writes;
std::vector<TimedWrite> frame_writes;
std::vector<uint64_t> frame_periods;
bool vsync_asserted = false;
int frame = -1;
uint64_t frame_start = 0;
bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;

[[noreturn]] void fail(const std::string &message) {
   std::fprintf(stderr, "vcs_multicolor_display_raster: %s\n", message.c_str());
   std::exit(1);
}
uint16_t parse_u16(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text, &end, 0);
   if (!text[0] || !end || *end || value > 0xffff) fail("bad address argument");
   return static_cast<uint16_t>(value);
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
void load_timer(uint16_t address, uint8_t value) {
   timer_active = true;
   timer_start = virtual_cycles;
   timer_loaded = value;
   timer_divisor = address == kTim1t ? 1 : address == kTim8t ? 8 :
                   address == kTim64t ? 64 : 1024;
}
void apply_writes() {
   for (const Write &event : writes) {
      if (frame == 2 && event.address != kWsync && event.address != kVsync) {
         const uint64_t relative = virtual_cycles - frame_start;
         frame_writes.push_back({relative / kCyclesPerLine,
                                 relative % kCyclesPerLine,
                                 event.address, event.value});
      }
      if (event.address == kWsync) {
         const uint64_t phase = virtual_cycles % kCyclesPerLine;
         virtual_cycles += phase ? kCyclesPerLine - phase : kCyclesPerLine;
      }
      else if (event.address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (next && !vsync_asserted) {
            if (frame >= 0) frame_periods.push_back(virtual_cycles - frame_start);
            ++frame;
            frame_start = virtual_cycles;
         }
         vsync_asserted = next;
      }
      else if (event.address == kTim1t || event.address == kTim8t ||
               event.address == kTim64t || event.address == kT1024t) {
         load_timer(event.address, event.value);
      }
   }
   writes.clear();
}
std::vector<TimedWrite> events_on_line(uint64_t line, uint16_t low, uint16_t high) {
   std::vector<TimedWrite> out;
   for (const TimedWrite &event : frame_writes)
      if (event.line == line && event.address >= low && event.address <= high) out.push_back(event);
   return out;
}
void expect_pf_line(uint64_t line, const std::vector<TimedWrite> &want, const char *what) {
   std::vector<TimedWrite> got;
   for (const TimedWrite &event : frame_writes)
      if (event.line == line && (event.address == kPf1 || event.address == kPf2)) got.push_back(event);
   if (got.size() != want.size()) {
      std::fprintf(stderr,
         "vcs_multicolor_display_raster: %s line %llu has %zu PF writes; expected %zu\n",
         what, static_cast<unsigned long long>(line), got.size(), want.size());
      std::exit(1);
   }
   for (size_t i=0;i<want.size();++i) {
      if (got[i].cycle != want[i].cycle || got[i].address != want[i].address ||
          got[i].value != want[i].value) {
         std::fprintf(stderr,
            "vcs_multicolor_display_raster: %s line %llu write %zu is c%llu $%02x=%02x; "
            "expected c%llu $%02x=%02x\n",
            what, static_cast<unsigned long long>(line), i,
            static_cast<unsigned long long>(got[i].cycle), got[i].address, got[i].value,
            static_cast<unsigned long long>(want[i].cycle), want[i].address, want[i].value);
         std::exit(1);
      }
   }
}
std::vector<uint8_t> reversed_rom_table(uint16_t address) {
   std::vector<uint8_t> values;
   for (int i=7;i>=0;--i) values.push_back(memory_image[static_cast<uint16_t>(address+i)]);
   return values;
}
} // namespace

int main(int argc, char **argv) {
   if (argc != 8) {
      std::fprintf(stderr,
         "usage: %s ROM full|above|below playfield p0_graphics p1_graphics p0_colors p1_colors\n",
         argv[0]);
      return 2;
   }
   const std::string placement = argv[2];
   if (placement != "full" && placement != "above" && placement != "below")
      fail("bad placement");
   const uint16_t playfield = parse_u16(argv[3]);
   const uint16_t p0_graphics = parse_u16(argv[4]);
   const uint16_t p1_graphics = parse_u16(argv[5]);
   const uint16_t p0_colors = parse_u16(argv[6]);
   const uint16_t p1_colors = parse_u16(argv[7]);

   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("cannot open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) fail("ROM is not 4096 bytes");

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   constexpr uint64_t kInstructionLimit = 100000000;
   for (uint64_t instructions=0; instructions<kInstructionLimit && frame<4; ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < 4) fail("instruction limit reached");
   for (size_t i=2;i<frame_periods.size();++i)
      if (frame_periods[i] != 262*kCyclesPerLine) fail("frame is not exactly 262 lines");

   const uint64_t game_first = placement == "above" ? 51 : 40;
   const uint64_t first_row = placement == "full" ? game_first : game_first + 3;
   const int rows = placement == "full" ? 12 : 11;
   auto pf = [](uint64_t line,uint64_t cycle,uint16_t address,uint8_t value) {
      return TimedWrite{line,cycle,address,value};
   };
   auto row_byte = [&](int row,int byte) {
      return memory_image[static_cast<uint16_t>(playfield+row*4+byte)];
   };
   if (rows == 12) {
      auto register_at = [&](uint64_t line, uint64_t cycle, uint16_t address) {
         uint8_t value = 0;
         for (const TimedWrite &event : frame_writes) {
            if (event.address != address) continue;
            if (event.line < line || (event.line == line && event.cycle <= cycle))
               value = event.value;
         }
         return value;
      };
      auto bit = [](uint8_t value, unsigned index) {
         return ((value >> index) & 1u) != 0;
      };
      for (int row=0;row<12;++row) {
         for (int subline=0;subline<16;++subline) {
            const uint64_t line=first_row+row*16+subline;
            for (unsigned pixel=0;pixel<160;++pixel) {
               const uint64_t cycle=(68+pixel)/3;
               const uint8_t pf1=register_at(line,cycle,kPf1);
               const uint8_t pf2=register_at(line,cycle,kPf2);
               bool actual=false,want=false;
               if (pixel>=16 && pixel<48) {
                  const unsigned n=(pixel-16)/4;
                  actual=bit(pf1,7-n); want=bit(row_byte(row,0),7-n);
               }
               else if (pixel>=48 && pixel<80) {
                  const unsigned n=(pixel-48)/4;
                  actual=bit(pf2,n); want=bit(row_byte(row,1),n);
               }
               else if (pixel>=80 && pixel<112) {
                  const unsigned n=(pixel-80)/4;
                  actual=bit(pf2,7-n); want=bit(row_byte(row,2),7-n);
               }
               else if (pixel>=112 && pixel<144) {
                  const unsigned n=(pixel-112)/4;
                  actual=bit(pf1,n); want=bit(row_byte(row,3),n);
               }
               if (actual!=want) {
                  std::fprintf(stderr,
                     "vcs_multicolor_display_raster: row %d line %d pixel %u is %d; expected %d\n",
                     row,subline,pixel,actual?1:0,want?1:0);
                  return 1;
               }
            }
         }
      }
      bool boundary=false;
      for (const TimedWrite &event:frame_writes)
         if (event.address==kVblank && event.line==232 && (event.value&2)) boundary=true;
      if (!boundary) fail("full-height raster does not enter overscan after line 231");
   }
   else {
      expect_pf_line(first_row-1, {
         pf(first_row-1,26,kPf1,0), pf(first_row-1,29,kPf2,0)
      }, "setup clear");

      // The score-composable 181-line profile retains its inherited preload
      // schedule. Its detailed raster is checked independently of the repaired
      // full-height branch.
      const int ordinary_rows=11;
      for (int row=0;row<ordinary_rows;++row) {
         const uint64_t first=first_row+row*16;
         expect_pf_line(first, {
            pf(first,28,kPf2,row_byte(row,1)),
            pf(first,38,kPf1,row_byte(row,3)),
            pf(first,45,kPf2,row_byte(row,2))
         }, "row entry");
         for (int sub=1;sub<=14;++sub) {
            const uint64_t line=first+sub;
            expect_pf_line(line, {
               pf(line,24,kPf1,row_byte(row,0)),
               pf(line,31,kPf2,row_byte(row,1)),
               pf(line,38,kPf1,row_byte(row,3)),
               pf(line,45,kPf2,row_byte(row,2))
            }, "steady row");
         }
         const uint64_t last=first+15;
         if (row+1<ordinary_rows)
            expect_pf_line(last,{pf(last,70,kPf1,row_byte(row+1,0))},"row preload");
         else
            expect_pf_line(last,{},"ordinary terminal line");
      }
   }

   const uint64_t game_end = game_first + (placement == "full" ? 192 : 181);
   auto graphics_sequence = [&](uint16_t address) {
      std::vector<TimedWrite> out;
      for (const TimedWrite &event:frame_writes)
         if (event.line>=game_first && event.line<game_end && event.address==address && event.value)
            out.push_back(event);
      return out;
   };
   const std::array<uint16_t,2> grp_regs{{kGrp0,kGrp1}};
   const std::array<uint16_t,2> color_regs{{kColup0,kColup1}};
   const std::array<uint16_t,2> gfx_tables{{p0_graphics,p1_graphics}};
   const std::array<uint16_t,2> color_tables{{p0_colors,p1_colors}};
   for (size_t player=0;player<2;++player) {
      const std::vector<TimedWrite> grp=graphics_sequence(grp_regs[player]);
      const std::vector<uint8_t> expected_gfx=reversed_rom_table(gfx_tables[player]);
      if (grp.size()!=expected_gfx.size()) fail("player glyph did not emit exactly eight rows");
      for (size_t i=0;i<grp.size();++i)
         if (grp[i].value!=expected_gfx[i]) fail("player glyph row order/value mismatch");
      const std::vector<uint8_t> expected_colors=reversed_rom_table(color_tables[player]);
      for (uint8_t expected_color:expected_colors) {
         bool seen=false;
         for (const TimedWrite &event:frame_writes)
            if (event.line>=game_first && event.line<game_end &&
                event.address==color_regs[player] && event.value==expected_color) seen=true;
         if (!seen) fail("player color table value did not reach the gameplay raster");
      }
   }
   unsigned balls=0,missiles=0;
   for (const TimedWrite &event:frame_writes) {
      if (event.line<game_first || event.line>=game_end) continue;
      if (event.address==kEnabl && (event.value&2)) ++balls;
      if ((event.address==kEnam0 || event.address==kEnam1) && (event.value&2)) ++missiles;
   }
   if (balls<3) fail("Ball raster is missing");
   if (missiles) fail("gameplay unexpectedly enabled a missile");

   if (placement != "full") {
      const uint64_t score_first=placement=="above" ? 40 : 221;
      unsigned score_grp=0,score_pf=0,score_objects=0;
      for (const TimedWrite &event:frame_writes) {
         if (event.line<score_first || event.line>=score_first+11) continue;
         if ((event.address==kGrp0 || event.address==kGrp1) && event.value) ++score_grp;
         if (event.address>=kPf0 && event.address<=kPf2 && event.value) ++score_pf;
         if ((event.address==kEnam0 || event.address==kEnam1 || event.address==kEnabl) &&
             (event.value&2)) ++score_objects;
      }
      if (score_grp<16) fail("score region lacks six-glyph activity");
      if (score_pf || score_objects) fail("score region leaked into playfield/missile/Ball ownership");
   }

   std::printf("vcs_multicolor_display_raster %s ok: exact PF rows, glyph bytes/colors, Ball, and score ownership\n",
               placement.c_str());
   return 0;
}
