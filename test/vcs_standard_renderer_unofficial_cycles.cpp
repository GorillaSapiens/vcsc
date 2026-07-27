//! @file vcs_standard_renderer_unofficial_cycles.cpp
//! @brief Verify the final unofficial forms and their task-20r legal replacements.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <initializer_list>
#include <vector>
#include "mos6502.h"

namespace {
std::array<uint8_t,65536> mem{};
std::vector<uint16_t> reads;
std::vector<uint16_t> writes;
uint8_t read_bus(uint16_t a) { reads.push_back(a); return mem[a]; }
void write_bus(uint16_t a,uint8_t v) { writes.push_back(a); mem[a]=v; }

struct Result {
   uint64_t cycles;
   uint8_t a,x,y,p;
};

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr,"vcs_standard_renderer_unofficial_cycles: %s\n",message);
   std::exit(1);
}

Result run(std::initializer_list<uint8_t> code,unsigned instructions,
           uint8_t a,uint8_t x,uint8_t y,uint8_t p,uint8_t zero=0) {
   mem.fill(0);
   mem[0xfffc]=0x00; mem[0xfffd]=0x80;
   unsigned offset=0;
   for (uint8_t byte:code) mem[0x8000+offset++]=byte;
   mem[0]=zero;
   mos6502 cpu(read_bus,write_bus);
   cpu.Reset();
   cpu.SetA(a); cpu.SetX(x); cpu.SetY(y); cpu.SetP(p);
   reads.clear(); writes.clear();
   uint64_t cycles=0;
   cpu.Run(instructions,cycles,mos6502::INST_COUNT);
   return {cycles,cpu.GetA(),cpu.GetX(),cpu.GetY(),cpu.GetP()};
}

void check_asr_replacement() {
   for (unsigned a=0;a<256;++a) {
      for (unsigned p=0;p<256;++p) {
         const Result old=run({0x4b,0xf0},1,a,0,0,p);
         if (!writes.empty()) fail("ASR wrote the bus");
         const Result legal=run({0x29,0xf0,0x4a},2,a,0,0,p);
         if (!writes.empty()) fail("AND/LSR wrote the bus");
         if (old.cycles!=2 || legal.cycles!=4 || old.a!=legal.a || old.p!=legal.p) {
            fail("AND/LSR does not match ASR #$F0 state");
         }
      }
   }
}

void check_sbx_replacement() {
   // The visible loop reaches only offsets 0,4,...,40. At this point C, D, and
   // V are clear; CPX immediately replaces N/Z/C, and A is dead afterward.
   for (uint8_t x=0;x<=40;x=static_cast<uint8_t>(x+4)) {
      for (unsigned preserved=0;preserved<4;++preserved) {
         const uint8_t p=static_cast<uint8_t>((preserved&1?0x04:0) |
                                              (preserved&2?0x10:0));
         const Result old=run({0x8a,0xcb,0xfc,0xe0,0x2c},3,0,x,0,p);
         if (!writes.empty()) fail("TXA/SBX/CPX wrote the bus");
         const Result legal=run({0x8a,0x69,0x04,0xaa,0xe0,0x2c},4,0,x,0,p);
         if (!writes.empty()) fail("TXA/ADC/TAX/CPX wrote the bus");
         if (old.cycles!=6 || legal.cycles!=8 || old.x!=legal.x || old.p!=legal.p) {
            fail("legal row advance does not match SBX state after CPX");
         }
      }
   }
}

void check_bit_delay() {
   const uint8_t initial_p=0x0d; // C, I, and D set; N/V/Z initially clear.
   const Result legal=run({0x24,0x00},1,0x3c,0x56,0x78,initial_p,0xc0);
   if (legal.cycles!=3) fail("BIT zp is not three cycles");
   if (!writes.empty()) fail("BIT delay wrote the bus");
   unsigned reads_from_zero=0;
   for (uint16_t address:reads) reads_from_zero += address==0;
   if (reads_from_zero!=1) fail("BIT delay did not perform exactly one TIA read");
   if (legal.a!=0x3c || legal.x!=0x56 || legal.y!=0x78)
      fail("BIT delay changed A, X, or Y");
   // $C0 supplies N/V, A&$C0 is zero, while C/I/D remain preserved.
   if ((legal.p&0xcf)!=(static_cast<uint8_t>(initial_p|0xc2)&0xcf))
      fail("BIT delay flag behavior changed");
}
}

int main() {
   check_asr_replacement();
   check_sbx_replacement();
   check_bit_delay();
   std::puts("vcs_standard_renderer_unofficial_cycles ok");
   return 0;
}
