// CPU/input oracle. Collision inputs are injected; visual geometry is checked
// separately with Stella, not inferred from these simulated latches.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <regex>
#include <string>
#include <vector>
#include "mos6502.h"

namespace {
[[noreturn]] void fail(const char* s) { std::fprintf(stderr,"cinder_run: %s\n",s); std::exit(1); }
class Machine {
   static Machine* active;
   uint8_t mem[65536]{};
   mos6502 cpu;
   std::map<std::string,unsigned> symbols;
   std::vector<std::pair<uint16_t,uint8_t>> writes;
   uint64_t cycles=0, clock=0, timer_start=0;
   unsigned divisor=1, loaded=0;
   int frame=-1;
   bool sync=false, timer=false;
   std::vector<uint64_t> starts;
   bool jump=false, landed=false, left=false, right=false, scored=false;
   bool damaged=false, dead=false, restarted=false, reset=false, scrolling=false;
   uint8_t initial_hill=0;
   static uint8_t read_cb(uint16_t a) { return active->read(a); }
   static void write_cb(uint16_t a,uint8_t v) { active->write(a,v); }
   static void tick(mos6502*) {}
   unsigned addr(const char* s) { auto i=symbols.find(s); if(i==symbols.end()) fail(s); return i->second; }
   uint8_t value(const char* s) { return mem[addr(s)]; }
   uint8_t read(uint16_t a) {
      if(a>=0x180 && a<=0x1ff) return mem[a&255];
      if(a==0x280) return frame>=20&&frame<65 ? 0xbf : frame>=65&&frame<130 ? 0x7f : 0xff;
      if(a==0x282) return frame==510 ? 0xfe : 0xff;
      if(a==0x3c) return frame==5 || (frame>=25&&frame<=30) || frame==450 ? 0 : 0x80;
      if(a==0x37) return (frame>=150&&frame<=155)||frame==250||frame==350 ? 0x80 : 0;
      if(a==0x32) return frame==100 ? 0x40 : 0;
      if(a==0x284 || a==0x285) {
         const uint64_t ticks=timer ? (clock-timer_start)/divisor : 0;
         if(a==0x285) return ticks>loaded ? 0x80 : 0;
         return ticks<=loaded ? static_cast<uint8_t>(loaded-ticks) : static_cast<uint8_t>(255-((clock-timer_start-loaded*divisor-divisor)&255));
      }
      return mem[a];
   }
   void write(uint16_t a,uint8_t v) {
      if(a>=0x100&&a<=0x1ff) { mem[a&255]=v; mem[a]=v; }
      else mem[a]=v;
      writes.emplace_back(a,v);
   }
   void snapshot() {
      const auto y=value("game_player0_y");
      if(frame==10 && value("run_mode")!=1) fail("fire did not start game");
      if(frame>26&&frame<65&&y<60) jump=true;
      if(frame==75 && y==73) landed=true;
      if(frame==158 && value("run_lives")!=2) fail("immunity did not suppress repeated collisions");
      if(frame==64 && value("game_object_x")==24) left=true;
      if(frame==130 && value("game_object_x")==72) right=true;
      if(frame==102 && value("score_score")>=0x50) scored=true;
      if(frame==152 && value("run_lives")==2 && value("run_immunity")) damaged=true;
      if(frame==352 && value("run_mode")==2 && !value("run_lives")) dead=true;
      if(frame==352 && mem[addr("game_playfield")]!=0) fail("game over left a life lamp lit");
      if(frame==452 && value("run_mode")==1 && value("run_lives")==3) restarted=true;
      if(frame==512 && !value("run_mode") && !value("score_score")) reset=true;
      if(frame==10) initial_hill=mem[addr("game_playfield")+20];
      if(frame>10 && frame<100 && mem[addr("game_playfield")+20]!=initial_hill) scrolling=true;
   }
public:
   Machine(const char* rom,const char* map):cpu(read_cb,write_cb,tick) {
      active=this;
      std::ifstream f(rom,std::ios::binary); f.read(reinterpret_cast<char*>(mem+0xf000),4096);
      if(f.gcount()!=4096) fail("ROM size");
      std::ifstream m(map); std::string line;
      std::regex entry("^\\s*\\$([0-9a-fA-F]{4})\\s+(\\S+)");
      while(std::getline(m,line)) { std::smatch match; if(std::regex_search(line,match,entry)) symbols[match[2]]=std::stoul(match[1],nullptr,16); }
      cpu.Reset(); cpu.SetPC(static_cast<uint16_t>(mem[0xfffc]|(mem[0xfffd]<<8)));
   }
   void run() {
      for(unsigned long i=0;i<20000000 && frame<530;++i) {
         writes.clear(); auto before=cycles; cpu.Run(1,cycles,mos6502::INST_COUNT); clock+=cycles-before;
         for(auto w:writes) {
            if(w.first==2) clock+=76-clock%76;
            if(w.first==0) { bool next=(w.second&2)!=0; if(next&&!sync) { ++frame; starts.push_back(clock); snapshot(); } sync=next; }
            if(w.first>=0x294 && w.first<=0x297) { static const unsigned d[]={1,8,64,1024}; timer=true; timer_start=clock; loaded=w.second; divisor=d[w.first-0x294]; }
         }
      }
      if(frame<530) fail("instruction deadline");
      for(size_t i=4;i<starts.size();++i) {
         if(starts[i]-starts[i-1]!=264*76) { std::fprintf(stderr,"frame %zu: %llu cycles\n",i,static_cast<unsigned long long>(starts[i]-starts[i-1])); fail("unstable frame period"); }
      }
      if(!jump||!landed) fail("jump/landing");
      if(!left||!right) fail("horizontal limits");
      if(!scored) fail("spark score");
      if(!damaged||!dead) fail("damage/game over");
      if(!restarted||!reset) fail("restart/reset");
      if(!scrolling) fail("hill scrolling");
      std::puts("cinder_run CPU ok");
   }
};
Machine* Machine::active=nullptr;
}
int main(int argc,char** argv) { if(argc!=3) return 2; Machine m(argv[1],argv[2]); m.run(); }
