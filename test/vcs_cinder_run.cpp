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
   uint8_t rom[8192]{};
   unsigned bank=1;
   bool endurance=false,fast=false;
   unsigned lanes=0;
   mos6502 cpu;
   std::map<std::string,unsigned> symbols;
   std::vector<std::pair<uint16_t,uint8_t>> writes;
   uint64_t cycles=0, clock=0, timer_start=0;
   unsigned divisor=1, loaded=0;
   int frame=-1;
   bool sync=false, timer=false;
   std::vector<uint64_t> starts;
   bool jump=false, landed=false, left=false, right=false, scored=false;
   bool lower=false,middle=false,upper=false,duck=false,fall=false;
   bool swept=false,unsupported=false,ceiling=false;
   bool fired=false,killed=false,m0=false,m1=false;
   bool damaged=false, dead=false, restarted=false, reset=false, scrolling=false;
   uint8_t initial_ledge=0;
   int jump_tone=-1,jump_next=-1,catch_tone=-1,catch_next=-1;
   static uint8_t read_cb(uint16_t a) { return active->read(a); }
   static void write_cb(uint16_t a,uint8_t v) { active->write(a,v); }
   static void tick(mos6502*) {}
   unsigned addr(const char* s) {
      auto i=symbols.find(s); if(i==symbols.end()) fail(s); return i->second;
   }
   uint8_t value(const char* s) { return mem[addr(s)]; }
   uint8_t read(uint16_t a) {
      if(a>=0x180 && a<=0x1ff) return mem[a&255];
      if((a&0x1fff)>=0x1000) {
         if((a&0xfff)==0xff8) bank=0;
         if((a&0xfff)==0xff9) bank=1;
         return rom[bank*4096+(a&0xfff)];
      }
      if(a==0x280) {
         uint8_t keys=0xff;
         if(endurance) {
            keys=frame%240<120 ? 0x7f : 0xbf;
            if(frame>10 && frame%48==0) keys&=0xef;
            return keys;
         }
         if(frame>=165&&frame<175) keys&=0xdf;
         if(frame>=190&&frame<250) keys&=0xbf;
         if(frame>=250&&frame<340) keys&=0x7f;
         if((frame>=7&&frame<=60)||frame==65||frame==135) keys&=0xef;
         return keys;
      }
      if(a==0x282) return !endurance&&frame==510 ? 0xfe : 0xff;
      if(endurance && a==0x3c) return frame==5 || (frame>10&&frame%90==0) ? 0 : 0x80;
      if(a==0x3c) return frame==5 || (frame>=100&&frame<=110) || frame==450 ? 0 : 0x80;
      if(endurance && a==0x37) return 0;
      if(a==0x37) return (frame>=150&&frame<=155)||frame==250||frame==350 ? 0x80 : 0;
      if(a==0x30) return !endurance&&frame==102 ? 0x80 : 0;
      if(endurance && a==0x31) return frame>800&&frame%32==0 ? 0x80 : 0;
      if(a==0x31) return frame==95 ? 0x80 : 0;
      if(a==0x284 || a==0x285) {
         const uint64_t ticks=timer ? (clock-timer_start)/divisor : 0;
         if(a==0x285) return ticks>loaded ? 0x80 : 0;
         return ticks<=loaded ? static_cast<uint8_t>(loaded-ticks) : static_cast<uint8_t>(255-((clock-timer_start-loaded*divisor-divisor)&255));
      }
      return mem[a];
   }
   void write(uint16_t a,uint8_t v) {
      if((a&0x1fff)>=0x1000) {
         if((a&0xfff)==0xff8) bank=0;
         if((a&0xfff)==0xff9) bank=1;
         return;
      }
      if(a>=0x100&&a<=0x1ff) { mem[a&255]=v; mem[a]=v; }
      else mem[a]=v;
      writes.emplace_back(a,v);
   }
   void snapshot() {
      if(endurance) {
         if(value("run_speed")>=24) fast=true;
         if(frame==1200 && value("run_speed")>=8) fail("pace increased before 34 seconds");
         switch(value("game_player1_y")) { case 73:lanes|=1;break; case 69:lanes|=2;break; case 41:lanes|=4;break; case 25:lanes|=8;break; }
         return;
      }
      if(std::getenv("CINDER_TRACE") && frame<210 && frame%5==0)
         std::fprintf(stderr,"f%d x%u feet%u v%d ground%u duck%u jump%u\n",frame,value("game_object_x"),value("run_feet"),static_cast<int8_t>(value("run_velocity")),value("run_grounded"),value("run_duck"),value("run_jump"));
      const auto y=value("game_player0_y");
      if(frame==10 && value("run_mode")!=1) fail("fire did not start game");
      if(mem[0x19]) {
         if(frame==10) jump_tone=mem[0x17];
         if(frame==11) jump_next=mem[0x17];
         if(frame==97) catch_tone=mem[0x17];
         if(frame==98) catch_next=mem[0x17];
      }
      if(frame==60 && (value("run_feet")!=57 || !value("run_grounded"))) fail("held Up jumped again after landing");
      if(frame>7&&frame<100&&y<60) jump=true;
      if(frame>100 && frame<340 && value("run_feet")==73) landed=true;
      if(frame<190 && value("run_grounded")) {
         if(value("run_feet")==57) lower=true;
         if(value("run_feet")==41) middle=true;
         if(value("run_feet")==25) upper=true;
      }
      if(frame>=166&&frame<=175 && value("run_duck") && value("game_player0_height")==3) duck=true;
      if(frame>100&&frame<340 && !value("run_grounded") && static_cast<int8_t>(value("run_velocity"))>0) fall=true;
      if(frame==158 && value("run_lives")!=2) fail("immunity did not suppress repeated collisions");
      if(value("game_object_x")==24) left=true;
      if(value("game_object_x")==100) right=true;
      if(frame==102 && value("score_score")>=0x50) scored=true;
      if(frame==101 && value("run_shot_x") && value("run_grounded")) fired=true;
      if(frame==103) {
         if(value("run_shot_x")) fail("M0 kill did not remove shot");
         killed=true;
      }
      if(frame==110 && value("run_shot_x")) fail("held Fire repeatedly spawned shots");
      if(frame==152 && value("run_lives")==2 && value("run_immunity")) damaged=true;
      if(frame==352 && value("run_mode")==2 && !value("run_lives")) dead=true;
      if(frame==352 && mem[addr("game_playfield")]!=0) fail("game over left a life lamp lit");
      if(frame==452 && value("run_mode")==1 && value("run_lives")==3) restarted=true;
      if(frame==512 && !value("run_mode") && !value("score_score")) reset=true;
      if(frame==10) initial_ledge=mem[addr("game_playfield")+28];
      if(frame>10 && frame<100 && mem[addr("game_playfield")+28]!=initial_ledge) scrolling=true;
      // Controlled edge cases supplement the unmodified continuous climb.
      // They exercise the real game routine against independently placed PF
      // rectangles, not a host-side replacement for the collision algorithm.
      if(frame==270 || frame==280 || frame==282 || frame==284) {
         for(unsigned row:{3u,5u,7u}) for(unsigned i=0;i<4;++i)
            mem[addr("game_playfield")+row*4+i]=0;
         unsigned row=frame==282 ? 5 : frame==284 ? 3 : 7;
         for(unsigned i=0;i<4;++i) mem[addr("game_playfield")+row*4+i]=255;
          mem[addr("run_feet")]=frame==270 ? 55 : frame==280 ? 67 : frame==282 ? 39 : 23;
         mem[addr("run_velocity")]=frame==280 ? static_cast<uint8_t>(-3) : 3;
         mem[addr("run_grounded")]=0;
         mem[addr("run_jump")]=0;
      }
      if(frame==271) swept=value("run_feet")==57 && value("run_grounded");
      if(frame==272) {
         for(unsigned i=0;i<4;++i) mem[addr("game_playfield")+28+i]=0;
      }
      if(frame==278) unsupported=value("run_feet")>57 && !value("run_grounded");
       if(frame==281) ceiling=value("run_feet")==67 && !value("run_velocity");
      if(frame==283 && (value("run_feet")!=41 || !value("run_grounded"))) fail("middle swept landing");
      if(frame==285 && (value("run_feet")!=25 || !value("run_grounded"))) fail("upper swept landing");
      if(frame==286) for(unsigned row:{3u,5u,7u}) for(unsigned i=0;i<4;++i)
         mem[addr("game_playfield")+row*4+i]=0;
   }
public:
   Machine(const char* rom,const char* map,bool long_run=false):endurance(long_run),cpu(read_cb,write_cb,tick) {
      active=this;
      std::ifstream f(rom,std::ios::binary); f.read(reinterpret_cast<char*>(this->rom),8192);
      if(f.gcount()!=8192) fail("ROM size");
      std::ifstream m(map); std::string line;
      std::regex entry("^\\s*\\$([0-9a-fA-F]{4})\\s+(\\S+)");
      while(std::getline(m,line)) { std::smatch match; if(std::regex_search(line,match,entry)) symbols[match[2]]=std::stoul(match[1],nullptr,16); }
      cpu.Reset(); cpu.SetPC(static_cast<uint16_t>(read(0xfffc)|(read(0xfffd)<<8)));
   }
   void run() {
      const int deadline=endurance ? 7200 : 530;
      for(unsigned long i=0;i<80000000 && frame<deadline;++i) {
         writes.clear(); auto before=cycles; cpu.Run(1,cycles,mos6502::INST_COUNT); clock+=cycles-before;
         for(auto w:writes) {
            if(w.first==0x0f && w.second && !(mem[1]&2) && clock%76>48)
               fail("late playfield PF2 write");
            if((w.first==0x1d || w.first==0x1e) && (w.second&2) && !(mem[1]&2) && clock%76>22)
               fail("missile enable changed after horizontal blanking");
            if(w.first==0x1d && (w.second&2)) m0=true;
            if(w.first==0x1e && (w.second&2)) m1=true;
            if(w.first==0x1f && (w.second&2)) fail("Ball was enabled instead of missiles");
            if(w.first==2) clock+=76-clock%76;
            if(w.first==0) { bool next=(w.second&2)!=0; if(next&&!sync) { ++frame; starts.push_back(clock); snapshot(); } sync=next; }
            if(w.first>=0x294 && w.first<=0x297) { static const unsigned d[]={1,8,64,1024}; timer=true; timer_start=clock; loaded=w.second; divisor=d[w.first-0x294]; }
         }
      }
      if(frame<deadline) fail("instruction deadline");
      for(size_t i=4;i<starts.size();++i) {
         if(starts[i]-starts[i-1]!=264*76) { std::fprintf(stderr,"frame %zu: %llu cycles\n",i,static_cast<unsigned long long>(starts[i]-starts[i-1])); fail("unstable frame period"); }
      }
      if(endurance) { if(!fast || lanes!=15) fail("fast-world/four hazard elevation coverage"); return; }
      if(!jump||!landed) fail("jump/landing");
      if(!lower||!middle||!upper) fail("four-height platform route");
      if(!duck||!fall) fail("ducking/walking off platforms");
      if(!swept||!unsupported||!ceiling) fail("swept landing, lost support, or solid underside");
      if(!fired||!killed||!m0||!m1) fail("Fire/M0 kill or M1 collectible controls");
      if(!left||!right) fail("horizontal limits");
      if(!scored) fail("spark score");
      if(!damaged||!dead) fail("damage/game over");
      if(!restarted||!reset) fail("restart/reset");
      if(!scrolling) fail("platform scrolling");
      if(jump_tone<0 || jump_next<0 || catch_tone<0 || catch_next<0 ||
         jump_tone==jump_next || catch_tone!=catch_next || jump_tone==catch_tone)
         fail("jump sweep and collection chime are not distinct");
   }
};
Machine* Machine::active=nullptr;
}
int main(int argc,char** argv) {
   if(argc!=3) return 2;
   Machine m(argv[1],argv[2]); m.run();
   Machine endurance(argv[1],argv[2],true); endurance.run();
   std::puts("cinder_run CPU ok");
}
