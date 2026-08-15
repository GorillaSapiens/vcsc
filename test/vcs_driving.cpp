//! @file vcs_driving.cpp
//! @brief CPU/RIOT/TIA oracle for Atari Indy 500 driving controllers.

#include <array>
#include <cstdarg>
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
constexpr uint64_t kCyclesPerLine = 76;
constexpr uint64_t kRawFrameLines = 264;
constexpr uint16_t kVsync=0x0000, kVblank=0x0001, kWsync=0x0002;
constexpr uint16_t kColup0=0x0006, kColup1=0x0007;
constexpr uint16_t kInpt4=0x003c, kInpt5=0x003d;
constexpr uint16_t kSwcha=0x0280, kSwacnt=0x0281, kSwchb=0x0282;
constexpr uint16_t kIntim=0x0284, kTimint=0x0285;
constexpr uint16_t kTim1t=0x0294, kTim8t=0x0295, kTim64t=0x0296, kT1024t=0x0297;

[[noreturn]] void fail(const char *fmt, ...) {
   std::fprintf(stderr, "vcs_driving: ");
   va_list ap; va_start(ap,fmt); std::vfprintf(stderr,fmt,ap); va_end(ap);
   std::fputc('\n',stderr); std::exit(1);
}

uint16_t parse_addr(const char *text) {
   char *end=nullptr; const unsigned long value=std::strtoul(text,&end,0);
   if(!text[0] || !end || *end || value>0xffff) fail("bad address '%s'",text);
   return static_cast<uint16_t>(value);
}

enum class Scenario { Clockwise, Counterclockwise, Skip, Public };

struct Snapshot {
   int step=0, delta=0;
   uint8_t button=0, phase=0, direction=0;
   uint8_t left_value=0, right_value=0;
   uint8_t colup0=0, colup1=0;
};

class Machine {
public:
   Machine(const char *rom_path, const std::map<std::string,uint16_t>& a,
           int active_side, Scenario scenario, bool example=false)
      : cpu_(read_thunk,write_thunk,clock_thunk), a_(a), active_side_(active_side),
        scenario_(scenario), example_(example), reads_per_group_(example?2:1) {
      active_=this; std::memset(memory_,0,sizeof(memory_));
      std::ifstream rom(rom_path,std::ios::binary|std::ios::ate);
      if(!rom) fail("could not open %s",rom_path);
      const auto size=rom.tellg();
      if(size!=2048 && size!=4096) fail("unexpected ROM size %lld",static_cast<long long>(size));
      rom_size_=static_cast<size_t>(size); rom_base_=rom_size_==2048?0xf800:0xf000;
      rom_.resize(rom_size_); rom.seekg(0);
      rom.read(reinterpret_cast<char*>(rom_.data()),static_cast<std::streamsize>(rom_size_));
      cpu_.Reset();
   }

   void run(int frames=8) {
      constexpr uint64_t kInstructionLimit=30000000;
      for(uint64_t instructions=0; instructions<kInstructionLimit && frame_<frames; ++instructions) {
         pending_.clear(); const uint64_t before=cpu_cycles_;
         cpu_.Run(1,cpu_cycles_,mos6502::INST_COUNT);
         virtual_cycles_ += cpu_cycles_-before;
         apply_pending();
      }
      if(frame_<frames) fail("instruction limit before %d frames",frames);
      for(size_t i=4;i<starts_.size();++i) {
         const uint64_t delta=starts_[i]-starts_[i-1];
         if(delta!=kRawFrameLines*kCyclesPerLine)
            fail("frame %zu is %llu raw lines + %llu cycles, expected %llu lines",
                 i,static_cast<unsigned long long>(delta/kCyclesPerLine),
                 static_cast<unsigned long long>(delta%kCyclesPerLine),
                 static_cast<unsigned long long>(kRawFrameLines));
      }
   }

   const std::vector<Snapshot>& snapshots() const { return snapshots_; }
   uint8_t swacnt() const { return swacnt_; }
   uint8_t swcha_latch() const { return swcha_latch_; }

private:
   struct Pending { uint16_t address; uint8_t value; };
   static Machine *active_;
   uint8_t memory_[65536]{};
   std::vector<uint8_t> rom_;
   size_t rom_size_=0; uint16_t rom_base_=0;
   mos6502 cpu_;
   std::map<std::string,uint16_t> a_;
   int active_side_=-1; Scenario scenario_=Scenario::Clockwise; bool example_=false;
   int reads_per_group_=1; uint64_t swcha_reads_=0;
   uint64_t cpu_cycles_=0, virtual_cycles_=0;
   int frame_=0; bool vsync_=false;
   std::vector<uint64_t> starts_;
   std::vector<Snapshot> snapshots_;
   std::vector<Pending> pending_;
   uint8_t swcha_latch_=0xff, swacnt_=0;
   bool timer_active_=false; uint64_t timer_start_=0,timer_divisor_=1; uint8_t timer_loaded_=0;

   static uint8_t read_thunk(uint16_t a) { return active_->read(a); }
   static void write_thunk(uint16_t a,uint8_t v) { active_->write(a,v); }
   static void clock_thunk(mos6502*) {}

   uint8_t byte(const char *name) const {
      const auto it=a_.find(name); if(it==a_.end()) return 0;
      return memory_[it->second];
   }
   int sbyte(const char *name) const {
      return static_cast<int>(static_cast<int8_t>(byte(name)));
   }

   uint8_t phase_for(int side,uint64_t group) const {
      static constexpr std::array<uint8_t,4> cw{{3,1,0,2}};
      static constexpr std::array<uint8_t,4> ccw{{3,2,0,1}};
      if(example_) return side==0?cw[group&3u]:ccw[group&3u];
      if(side!=active_side_) return 3;
      if(scenario_==Scenario::Clockwise) return cw[group&3u];
      if(scenario_==Scenario::Counterclockwise) return ccw[group&3u];
      if(scenario_==Scenario::Skip) {
         static constexpr std::array<uint8_t,7> seq{{3,0,1,2,2,2,2}};
         return seq[group<seq.size()?static_cast<size_t>(group):seq.size()-1];
      }
      return 3;
   }

   uint8_t external_swcha() {
      const uint64_t group=swcha_reads_/static_cast<uint64_t>(reads_per_group_);
      ++swcha_reads_;
      uint8_t v=0xcc; // Unused input pins 3/4 are high on both ports.
      v=static_cast<uint8_t>(v | (phase_for(0,group)<<4) | phase_for(1,group));
      return v;
   }

   bool button_pressed(int side) const {
      if(example_) {
         if(side==0) return frame_>=2 && frame_<=3;
         return frame_>=4 && frame_<=5;
      }
      return side==active_side_ && frame_>=2 && frame_<=3;
   }

   bool timer_underflowed() const {
      return timer_active_ && (virtual_cycles_-timer_start_)/timer_divisor_>timer_loaded_;
   }
   uint8_t timer_value() const {
      if(!timer_active_) return memory_[kIntim];
      const uint64_t ticks=(virtual_cycles_-timer_start_)/timer_divisor_;
      if(ticks<=timer_loaded_) return static_cast<uint8_t>(timer_loaded_-ticks);
      return static_cast<uint8_t>(255-((ticks-timer_loaded_-1)&255));
   }

   uint8_t read(uint16_t a) {
      if(a>=rom_base_) return rom_[static_cast<size_t>(a-rom_base_) & (rom_size_-1)];
      if(a==kSwcha) {
         const uint8_t ext=external_swcha();
         return static_cast<uint8_t>((swcha_latch_&swacnt_) | (ext&~swacnt_));
      }
      if(a==kSwacnt) return swacnt_;
      if(a==kSwchb) return 0xff;
      if(a==kInpt4) return button_pressed(0)?0x00:0x80;
      if(a==kInpt5) return button_pressed(1)?0x00:0x80;
      if(a==kIntim) return timer_value();
      if(a==kTimint) return timer_underflowed()?0x80:0;
      return memory_[a];
   }

   void write(uint16_t a,uint8_t v) {
      if(a<rom_base_) memory_[a]=v;
      pending_.push_back({a,v});
   }
   void load_timer(uint16_t a,uint8_t v) {
      timer_active_=true; timer_start_=virtual_cycles_; timer_loaded_=v;
      timer_divisor_=a==kTim1t?1:a==kTim8t?8:a==kTim64t?64:1024;
   }
   void snapshot() {
      Snapshot s;
      if(example_) {
         s.left_value=byte("left_value"); s.right_value=byte("right_value");
         s.colup0=memory_[kColup0]; s.colup1=memory_[kColup1];
      } else {
         s.step=sbyte("step"); s.delta=sbyte("delta"); s.button=byte("button");
         s.phase=byte("phase"); s.direction=byte("direction");
      }
      snapshots_.push_back(s);
   }
   void begin_frame() { ++frame_; starts_.push_back(virtual_cycles_); snapshot(); }
   void apply_pending() {
      for(const auto&w:pending_) {
         if(w.address==kWsync) {
            const uint64_t within=virtual_cycles_%kCyclesPerLine;
            virtual_cycles_ += within ? kCyclesPerLine-within : kCyclesPerLine;
         } else if(w.address==kVsync) {
            const bool next=(w.value&2)!=0;
            if(next&&!vsync_) begin_frame();
            vsync_=next;
         } else if(w.address==kSwacnt) {
            swacnt_=w.value;
         } else if(w.address==kSwcha) {
            swcha_latch_=w.value;
         } else if(w.address>=kTim1t && w.address<=kT1024t) {
            load_timer(w.address,w.value);
         }
      }
      pending_.clear();
   }
};
Machine *Machine::active_=nullptr;

void require_regular(const std::vector<Snapshot>& s,int sign) {
   if(s.size()<6) fail("too few snapshots");
   const int want_delta=6*sign, want_step=sign;
   const uint8_t want_direction=sign>0?1:2;
   if(s[1].delta!=want_delta || s[2].delta!=want_delta)
      fail("delta did not reset per frame and accumulate six %s transitions",
           sign>0?"clockwise":"counterclockwise");
   if(s[1].step!=want_step || s[1].direction!=want_direction)
      fail("step/direction mismatch for %s motion",sign>0?"clockwise":"counterclockwise");
   if(s[1].button!=0 || s[2].button!=1 || s[4].button!=0)
      fail("fire button did not track press/hold/release live state");
}

void require_public(const std::vector<Snapshot>& s) {
   if(s.size()<6) fail("too few public snapshots");
   if(s[1].left_value!=6 || s[1].right_value!=10 ||
      s[2].left_value!=12 || s[2].right_value!=4 ||
      s[3].left_value!=2 || s[3].right_value!=14)
      fail("public hex counters lost CW/CCW arithmetic or 0/F wrap");
   const uint8_t white0=s[0].colup0, white1=s[0].colup1;
   if(s[1].colup0!=white0 || s[1].colup1!=white1)
      fail("released controller glyphs are not white");
   if(s[2].colup0==white0 || s[2].colup1!=white1)
      fail("left fire button did not make only left glyph red");
   if(s[4].colup0!=white0 || s[4].colup1==white1)
      fail("button release/right press did not restore left white and make right red");
}

} // namespace

int main(int argc,char **argv) {
   if(argc<2) return 2;
   const char *mode=argv[1];
   if(std::strcmp(mode,"fixture")==0) {
      if(argc!=9) return 2;
      const char *rom=argv[2];
      std::map<std::string,uint16_t> a;
      a["step"]=parse_addr(argv[3]); a["delta"]=parse_addr(argv[4]);
      a["button"]=parse_addr(argv[5]); a["phase"]=parse_addr(argv[6]);
      a["direction"]=parse_addr(argv[7]); const int side=std::atoi(argv[8]);
      for(const auto& spec : std::array<std::pair<Scenario,int>,2>{{
             {Scenario::Clockwise,1},{Scenario::Counterclockwise,-1}}}) {
         Machine m(rom,a,side,spec.first); m.run(); require_regular(m.snapshots(),spec.second);
         if(side==0) {
            if(m.swacnt()!=0x0f || (m.swcha_latch()&0x0f)!=0x05)
               fail("left driving controller disturbed right-port output nibble");
         } else {
            if(m.swacnt()!=0xf0 || (m.swcha_latch()&0xf0)!=0x50)
               fail("right driving controller disturbed left-port output nibble");
         }
      }
      Machine skip(rom,a,side,Scenario::Skip); skip.run();
      const auto& ss=skip.snapshots();
      if(ss.size()<2 || ss[1].delta!=-3 || ss[1].direction!=2 || ss[1].phase!=2)
         fail("ambiguous initial skip / direction-preserving two-step decode regressed");
   } else if(std::strcmp(mode,"example")==0) {
      if(argc!=5) return 2;
      std::map<std::string,uint16_t> a;
      a["left_value"]=parse_addr(argv[3]); a["right_value"]=parse_addr(argv[4]);
      Machine m(argv[2],a,-1,Scenario::Public,true); m.run(); require_public(m.snapshots());
      if(m.swacnt()!=0) fail("two-controller example did not leave both SWCHA nibbles as inputs");
   } else return 2;
   std::puts("vcs_driving ok: both ports, Gray direction/wrap/skip, buttons, hex display, stable frames");
   return 0;
}
