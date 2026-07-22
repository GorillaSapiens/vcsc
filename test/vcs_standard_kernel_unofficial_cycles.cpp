//! @file vcs_standard_kernel_unofficial_cycles.cpp
//! @brief Lock byte-cycle behavior of unofficial forms retained by the standard kernel.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "mos6502.h"

namespace {
std::array<uint8_t,65536> mem{};
uint8_t read_bus(uint16_t a) { return mem[a]; }
void write_bus(uint16_t a,uint8_t v) { mem[a]=v; }
[[noreturn]] void fail(const char *name,uint64_t got,uint64_t want) {
   std::fprintf(stderr,"%s cycles=%llu expected=%llu\n",name,
      static_cast<unsigned long long>(got),static_cast<unsigned long long>(want));
   std::exit(1);
}
uint64_t run_one(uint8_t op,uint8_t operand,uint8_t y=0,
                 uint16_t pointer=0,uint8_t pointer_slot=0) {
   mem.fill(0);
   mem[0xfffc]=0x00; mem[0xfffd]=0x80;
   mem[0x8000]=op; mem[0x8001]=operand;
   if (pointer_slot) {
      mem[pointer_slot]=static_cast<uint8_t>(pointer);
      mem[static_cast<uint8_t>(pointer_slot+1)]=static_cast<uint8_t>(pointer>>8);
   }
   mos6502 cpu(read_bus,write_bus);
   cpu.Reset();
   cpu.SetY(y);
   uint64_t cycles=0;
   cpu.Run(1,cycles,mos6502::INST_COUNT);
   return cycles;
}
void check(const char *name,uint64_t got,uint64_t want) {
   if (got!=want) fail(name,got,want);
}
}
int main() {
   check("LAX zp",run_one(0xa7,0x80),3);
   check("ASR imm",run_one(0x4b,0xf0),2);
   check("DCP zp",run_one(0xc7,0x81),5);
   check("SBX imm",run_one(0xcb,0xfc),2);
   check("LAX (zp),Y same",run_one(0xb3,0x82,0,0x2000,0x82),5);
   check("LAX (zp),Y crossing",run_one(0xb3,0x82,1,0x20ff,0x82),6);
   check("NOP zp",run_one(0x04,0x00),3);
   std::puts("vcs_standard_kernel_unofficial_cycles ok");
   return 0;
}
