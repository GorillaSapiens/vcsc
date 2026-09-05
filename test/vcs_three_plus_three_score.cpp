//! @file vcs_three_plus_three_score.cpp
//! @brief Exact timing, BCD-boundary, and glyph-write oracle for 3+3 score.

#include <array>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase=0xF000;
constexpr size_t kRomSize=4096;
constexpr uint64_t kCyclesPerLine=76;
constexpr uint64_t kRawFrameLines=264; // frame_ntsc's 262 Stella lines + harness accounting
constexpr int kFramesToRun=8;

constexpr uint16_t kVsync=0x0000, kVblank=0x0001, kWsync=0x0002;
constexpr uint16_t kNusiz0=0x0004, kNusiz1=0x0005;
constexpr uint16_t kColup0=0x0006, kColup1=0x0007;
constexpr uint16_t kRefp0=0x000b, kRefp1=0x000c;
constexpr uint16_t kResp0=0x0010, kResp1=0x0011;
constexpr uint16_t kGrp0=0x001b, kGrp1=0x001c;
constexpr uint16_t kHmp0=0x0020, kHmp1=0x0021;
constexpr uint16_t kHmm0=0x0022, kHmm1=0x0023, kHmbl=0x0024;
constexpr uint16_t kVdelp0=0x0025, kVdelp1=0x0026, kHmove=0x002a;
constexpr uint16_t kIntim=0x0284, kTimint=0x0285;
constexpr uint16_t kTim1t=0x0294, kTim8t=0x0295, kTim64t=0x0296, kT1024t=0x0297;

constexpr uint8_t kFont[10][8]={
   {0x3e,0x63,0x67,0x6f,0x7b,0x73,0x63,0x3e},
   {0x1c,0x3c,0x7c,0x1c,0x1c,0x1c,0x1c,0x7f},
   {0x3e,0x63,0x03,0x03,0x3e,0x60,0x60,0x7f},
   {0x3e,0x63,0x03,0x1e,0x03,0x03,0x63,0x3e},
   {0x06,0x1e,0x36,0x66,0x46,0x7f,0x06,0x06},
   {0x7f,0x60,0x60,0x3e,0x03,0x03,0x63,0x3e},
   {0x3e,0x63,0x60,0x7e,0x63,0x63,0x63,0x3e},
   {0x3f,0x61,0x03,0x06,0x1c,0x30,0x30,0x30},
   {0x3e,0x63,0x63,0x3e,0x63,0x63,0x63,0x3e},
   {0x3e,0x63,0x63,0x63,0x3f,0x03,0x63,0x3e}
};

struct PendingWrite { uint16_t address; uint8_t value; };
struct Event { uint64_t line,cycle; uint16_t address; uint8_t value; };
struct Frame { uint16_t left=0,right=0; std::vector<Event> events; };

[[noreturn]] void fail(const char *fmt,...) {
   std::fprintf(stderr,"vcs_three_plus_three_score: ");
   va_list ap; va_start(ap,fmt); std::vfprintf(stderr,fmt,ap); va_end(ap);
   std::fputc('\n',stderr); std::exit(1);
}

uint8_t parse_zp(const char *text) {
   char *end=nullptr; const unsigned long value=std::strtoul(text,&end,0);
   if (!text[0] || !end || *end || value>0xfe) fail("bad zero-page address '%s'",text);
   return static_cast<uint8_t>(value);
}

class Machine {
public:
   Machine(const char *rom_path,uint8_t left_addr,uint8_t right_addr)
      : cpu_(read_thunk,write_thunk,clock_thunk), left_addr_(left_addr), right_addr_(right_addr) {
      active_=this; std::memset(memory_,0,sizeof(memory_));
      std::ifstream rom(rom_path,std::ios::binary);
      if (!rom) fail("could not open ROM");
      rom.read(reinterpret_cast<char *>(memory_+kRomBase),kRomSize);
      if (rom.gcount()!=static_cast<std::streamsize>(kRomSize)) fail("ROM is not exactly 4096 bytes");
      cpu_.Reset();
   }

   std::vector<Frame> run() {
      constexpr uint64_t kInstructionLimit=100000000;
      for (uint64_t instructions=0; instructions<kInstructionLimit && frame_<kFramesToRun; ++instructions) {
         pending_.clear(); const uint64_t before=cpu_cycles_;
         cpu_.Run(1,cpu_cycles_,mos6502::INST_COUNT);
         virtual_cycles_ += cpu_cycles_-before; apply_pending();
      }
      if (frame_<kFramesToRun) fail("instruction limit reached before %d frames",kFramesToRun);
      const uint64_t expected=kRawFrameLines*kCyclesPerLine;
      for (size_t i=3;i<starts_.size();++i) {
         const uint64_t delta=starts_[i]-starts_[i-1];
         if (delta!=expected) fail("frame %zu has %llu raw cycles (%llu lines), expected %llu (%llu lines)",
            i,static_cast<unsigned long long>(delta),
            static_cast<unsigned long long>(delta/kCyclesPerLine),
            static_cast<unsigned long long>(expected),
            static_cast<unsigned long long>(kRawFrameLines));
      }
      return frames_;
   }

private:
   static Machine *active_;
   uint8_t memory_[65536]{}; mos6502 cpu_; uint8_t left_addr_,right_addr_;
   uint64_t cpu_cycles_=0,virtual_cycles_=0,frame_start_=0;
   std::vector<PendingWrite> pending_; std::vector<Frame> frames_; std::vector<uint64_t> starts_;
   bool vsync_=false,vblank_=true,timer_active_=false; int frame_=-1;
   uint64_t timer_start_=0; uint16_t timer_divisor_=1; uint8_t timer_loaded_=0;

   static uint8_t read_thunk(uint16_t a){ return active_->read(a); }
   static void write_thunk(uint16_t a,uint8_t v){ active_->write(a,v); }
   static void clock_thunk(mos6502 *){}
   uint16_t word(uint8_t a) const { return static_cast<uint16_t>(memory_[a] | (memory_[a+1]<<8)); }
   bool timer_underflowed() const { return timer_active_ && (virtual_cycles_-timer_start_)/timer_divisor_>timer_loaded_; }
   uint8_t timer_value() const {
      if (!timer_active_) return memory_[kIntim];
      const uint64_t ticks=(virtual_cycles_-timer_start_)/timer_divisor_;
      if (ticks<=timer_loaded_) return static_cast<uint8_t>(timer_loaded_-ticks);
      return static_cast<uint8_t>(255-((ticks-timer_loaded_-1)&255));
   }
   uint8_t read(uint16_t a){ if(a==kIntim)return timer_value(); if(a==kTimint)return timer_underflowed()?0x80:0; return memory_[a]; }
   void write(uint16_t a,uint8_t v){ if(a<kRomBase)memory_[a]=v; pending_.push_back({a,v}); }
   void load_timer(uint16_t a,uint8_t v){ timer_active_=true;timer_start_=virtual_cycles_;timer_loaded_=v;timer_divisor_=a==kTim1t?1:a==kTim8t?8:a==kTim64t?64:1024; }
   void begin_frame(){
      ++frame_; frame_start_=virtual_cycles_; starts_.push_back(virtual_cycles_);
      Frame f; f.left=word(left_addr_); f.right=word(right_addr_); frames_.push_back(f);
   }
   void record(const PendingWrite &w){
      if(frame_<0 || vblank_ || w.address>0x002c || w.address==kVsync || w.address==kVblank || w.address==kWsync) return;
      const uint64_t rel=virtual_cycles_-frame_start_;
      frames_.back().events.push_back({rel/kCyclesPerLine,rel%kCyclesPerLine,w.address,w.value});
   }
   void apply_pending(){
      for(const PendingWrite &w:pending_){
         record(w);
         if(w.address==kWsync){ const uint64_t within=virtual_cycles_%kCyclesPerLine; virtual_cycles_ += within?kCyclesPerLine-within:kCyclesPerLine; }
         else if(w.address==kVsync){ const bool next=(w.value&2)!=0; if(next&&!vsync_)begin_frame(); vsync_=next; }
         else if(w.address==kVblank) vblank_=(w.value&2)!=0;
         else if(w.address>=kTim1t && w.address<=kT1024t) load_timer(w.address,w.value);
      }
      pending_.clear();
   }
};
Machine *Machine::active_=nullptr;

const Event &need(const Frame &f,uint64_t line,uint64_t cycle,uint16_t address,uint8_t value,const char *name){
   for(const auto &e:f.events) if(e.line==line&&e.cycle==cycle&&e.address==address){
      if(e.value!=value) fail("%s at %llu:%02llu is %02x, expected %02x",name,
         static_cast<unsigned long long>(line),static_cast<unsigned long long>(cycle),e.value,value);
      return e;
   }
   fail("missing %s at %llu:%02llu address %02x",name,
      static_cast<unsigned long long>(line),static_cast<unsigned long long>(cycle),address);
}

std::array<unsigned,3> digits(uint16_t packed){
   const unsigned h=(packed>>8)&15,t=(packed>>4)&15,o=packed&15;
   if(h>9||t>9||o>9) fail("displayed packed BCD %04x has a nondecimal low-three digit",packed);
   return {h,t,o};
}

void verify_frame(const Frame &f,uint16_t expected_left,uint16_t expected_right){
   uint64_t entry=~uint64_t{0};
   for(const auto &e:f.events) if(e.address==kNusiz0 && e.value==3 && e.cycle==32){ entry=e.line; break; }
   if(entry==~uint64_t{0}) fail("could not locate score setup in frame with %zu visible writes",f.events.size());
   if(f.left!=expected_left||f.right!=expected_right)
      fail("score state is %04x/%04x, expected %04x/%04x",f.left,f.right,expected_left,expected_right);
   const auto l=digits(f.left), r=digits(f.right);

   need(f,entry,0,kGrp0,0,"setup GRP0 clear 1");
   need(f,entry,3,kGrp1,0,"setup GRP1 clear");
   need(f,entry,6,kGrp0,0,"setup GRP0 clear 2");
   need(f,entry,9,kVdelp0,0,"setup VDELP0");
   need(f,entry,12,kVdelp1,0,"setup VDELP1");
   need(f,entry,15,kRefp0,0,"setup REFP0");
   need(f,entry,18,kRefp1,0,"setup REFP1");
   need(f,entry,21,kHmm0,0,"setup HMM0");
   need(f,entry,24,kHmm1,0,"setup HMM1");
   need(f,entry,27,kHmbl,0,"setup HMBL");
   need(f,entry,32,kNusiz0,3,"setup NUSIZ0");
   need(f,entry,35,kNusiz1,3,"setup NUSIZ1");
   need(f,entry,41,kColup0,0x3e,"left color");
   need(f,entry,47,kColup1,0xae,"right color");
   need(f,entry,73,kHmp0,0xb2,"left fixed HMP");
   need(f,entry+1,18,kResp0,2,"left RESP0");
   need(f,entry+1,73,kHmp1,0x58,"right fixed HMP");
   need(f,entry+2,48,kResp1,8,"right RESP1");
   need(f,entry+2,56,kGrp0,kFont[l[0]][0],"left hundreds row 0 preload");
   need(f,entry+2,71,kHmove,kFont[l[0]][0],"single HMOVE");

   for(unsigned row=0;row<7;++row){
      const uint64_t line=entry+3+row;
      need(f,line,18,kGrp1,kFont[r[0]][row],"right hundreds row");
      need(f,line,24,kGrp0,kFont[l[1]][row],"left tens row");
      need(f,line,29,kGrp0,kFont[l[2]][row],"left ones row");
      need(f,line,53,kGrp1,kFont[r[1]][row],"right tens row");
      need(f,line,58,kGrp1,kFont[r[2]][row],"right ones row");
      need(f,line,50,kGrp0,kFont[l[0]][row+1],"next left hundreds preload");
   }
   const uint64_t final=entry+10;
   need(f,final,18,kGrp1,kFont[r[0]][7],"final right hundreds row");
   need(f,final,24,kGrp0,kFont[l[1]][7],"final left tens row");
   need(f,final,29,kGrp0,kFont[l[2]][7],"final left ones row");
   need(f,final,53,kGrp1,kFont[r[1]][7],"final right tens row");
   need(f,final,58,kGrp1,kFont[r[2]][7],"final right ones row");
   need(f,final,47,kGrp0,0,"final GRP0 cleanup");
   need(f,final,61,kGrp1,0,"final GRP1 cleanup");

   unsigned hmoves=0;
   for(const auto &e:f.events) if(e.address==kHmove) ++hmoves;
   if(hmoves!=1) fail("visible score frame contains %u HMOVE writes, expected 1",hmoves);
}
} // namespace

int main(int argc,char **argv){
   if(argc!=4) return 2;
   Machine machine(argv[1],parse_zp(argv[2]),parse_zp(argv[3]));
   const auto frames=machine.run();
   if(frames.size()<4) fail("too few frames captured");
   verify_frame(frames[4],0x0098,0x0998);
   verify_frame(frames[5],0x0099,0x0999);
   verify_frame(frames[6],0x0100,0x1000);
   verify_frame(frames[7],0x0101,0x1001);
   std::printf("vcs_three_plus_three_score ok: exact 3+3 raster, independent colors, BCD carries, and 262-line frames\n");
   return 0;
}
