//! @file vcs_four_player_paddleball.cpp
//! @brief 4K CPU/TIA-input oracle for four-player Paddleball and four paddles.

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
constexpr uint16_t kRomBase=0xf000;
constexpr size_t kRomSize=4096;
constexpr uint64_t kCyclesPerLine=76;
constexpr uint64_t kRawFrameLines=264;
constexpr uint16_t kVsync=0x0000, kVblank=0x0001, kWsync=0x0002;
constexpr uint16_t kPf0=0x000d, kPf1=0x000e, kPf2=0x000f;
constexpr uint16_t kHmp0=0x0020, kHmp1=0x0021, kHmm0=0x0022, kHmm1=0x0023, kHmbl=0x0024;
constexpr uint16_t kHmove=0x002a, kHmclr=0x002b;
constexpr uint16_t kInpt0=0x0038, kInpt1=0x0039, kInpt2=0x003a, kInpt3=0x003b;
constexpr uint16_t kSwcha=0x0280, kSwchb=0x0282;
constexpr uint16_t kIntim=0x0284, kTimint=0x0285;
constexpr uint16_t kTim1t=0x0294, kTim8t=0x0295, kTim64t=0x0296, kT1024t=0x0297;

[[noreturn]] void fail(const char *fmt,...) {
   std::fprintf(stderr,"vcs_four_player_paddleball: ");
   va_list ap; va_start(ap,fmt); std::vfprintf(stderr,fmt,ap); va_end(ap);
   std::fputc('\n',stderr); std::exit(1);
}

uint16_t parse_addr(const char *text) {
   char *end=nullptr; const unsigned long value=std::strtoul(text,&end,0);
   if(!text[0] || !end || *end || value>0xffff) fail("bad address '%s'",text);
   return static_cast<uint16_t>(value);
}

struct Snapshot {
   std::array<uint8_t,4> p{{0,0,0,0}};
   std::array<uint8_t,4> b{{0,0,0,0}};
   std::array<uint8_t,4> y{{0,0,0,0}};
   uint8_t valid=0;
};

class Machine {
public:
   Machine(const char *rom_path,const std::map<std::string,uint16_t>& a,
           std::array<int,4> thresholds,int pressed=-1)
      : cpu_(read_thunk,write_thunk,clock_thunk), a_(a), thresholds_(thresholds), pressed_(pressed) {
      active_=this; std::memset(memory_,0,sizeof(memory_));
      std::ifstream rom(rom_path,std::ios::binary);
      if(!rom) fail("could not open ROM");
      rom.read(reinterpret_cast<char*>(rom_),kRomSize);
      if(rom.gcount()!=static_cast<std::streamsize>(kRomSize)) fail("ROM is not 8192 bytes");
      cpu_.Reset();
   }

   void run(int frames=100) {
      constexpr uint64_t kInstructionLimit=160000000;
      for(uint64_t instructions=0; instructions<kInstructionLimit && frame_<frames; ++instructions) {
         pending_.clear(); const uint64_t before=cpu_cycles_;
         cpu_.Run(1,cpu_cycles_,mos6502::INST_COUNT);
         virtual_cycles_ += cpu_cycles_-before;
         apply_pending();
      }
      if(frame_<frames) fail("instruction limit before %d frames",frames);
      check_frames();
   }

   const std::vector<Snapshot>& snapshots() const { return snapshots_; }
   uint64_t max_divider_pf_cycle() const { return max_divider_pf_cycle_; }
   uint64_t max_wall_pf_cycle() const { return max_wall_pf_cycle_; }
   uint64_t gameplay_scanline_overruns() const { return gameplay_scanline_overruns_; }
   uint64_t fixed_paddle_hmove_violations() const { return fixed_paddle_hmove_violations_; }
   bool saw_divider() const { return saw_divider_; }

private:
   struct Pending { uint16_t address; uint8_t value; };
   static Machine *active_;
   uint8_t memory_[65536]{};
   uint8_t rom_[kRomSize]{};
   mos6502 cpu_;
   std::map<std::string,uint16_t> a_;
   std::array<int,4> thresholds_;
   int pressed_=-1;
   uint64_t cpu_cycles_=0,virtual_cycles_=0,last_wsync_boundary_=0;
   uint64_t max_divider_pf_cycle_=0,max_wall_pf_cycle_=0,gameplay_scanline_overruns_=0;
   uint64_t fixed_paddle_hmove_violations_=0;
   bool divider_active_=false,saw_divider_=false;
   std::vector<Pending> pending_;
   std::vector<uint64_t> starts_;
   std::vector<Snapshot> snapshots_;
   bool vsync_=false,pot_dump_=true,timer_active_=false;
   uint64_t pot_release_=0,timer_start_=0;
   uint16_t timer_divisor_=1;
   uint8_t timer_loaded_=0;
   int frame_=-1;

   static uint8_t read_thunk(uint16_t a){ return active_->read(a); }
   static void write_thunk(uint16_t a,uint8_t v){ active_->write(a,v); }
   static void clock_thunk(mos6502*){}

   uint8_t byte(const char*n) const { return memory_[a_.at(n)]; }
   bool timer_underflowed() const { return timer_active_ && (virtual_cycles_-timer_start_)/timer_divisor_>timer_loaded_; }
   uint8_t timer_value() const {
      if(!timer_active_) return memory_[kIntim];
      const uint64_t ticks=(virtual_cycles_-timer_start_)/timer_divisor_;
      if(ticks<=timer_loaded_) return static_cast<uint8_t>(timer_loaded_-ticks);
      return static_cast<uint8_t>(255-((ticks-timer_loaded_-1)&255));
   }
   uint8_t pot(int channel) const {
      if(pot_dump_) return 0;
      return virtual_cycles_-pot_release_ >= static_cast<uint64_t>(thresholds_[channel])*kCyclesPerLine ? 0x80 : 0;
   }
   uint8_t read(uint16_t a) {
      if(a>=kRomBase) return rom_[a&0x0fff];
      if(a==kInpt0) return pot(0);
      if(a==kInpt1) return pot(1);
      if(a==kInpt2) return pot(2);
      if(a==kInpt3) return pot(3);
      if(a==kSwcha) {
         uint8_t v=0xff;
         if(pressed_==0) v&=0x7f;
         if(pressed_==1) v&=0xbf;
         if(pressed_==2) v&=0xf7;
         if(pressed_==3) v&=0xfb;
         return v;
      }
      if(a==kSwchb) return 0xff;
      if(a==kIntim) return timer_value();
      if(a==kTimint) return timer_underflowed()?0x80:0;
      return memory_[a];
   }
   void write(uint16_t a,uint8_t v) {
      if(a<kRomBase) memory_[a]=v;
      pending_.push_back({a,v});
   }
   void load_timer(uint16_t a,uint8_t v) {
      timer_active_=true; timer_start_=virtual_cycles_; timer_loaded_=v;
      timer_divisor_=a==kTim1t?1:a==kTim8t?8:a==kTim64t?64:1024;
   }
   void snapshot() {
      Snapshot s;
      for(int i=0;i<4;++i) {
         s.p[static_cast<size_t>(i)]=byte((std::string("p")+char('0'+i)).c_str());
         s.b[static_cast<size_t>(i)]=byte((std::string("b")+char('0'+i)).c_str());
      }
      s.y[0]=byte("p0_y"); s.y[1]=byte("m0_y"); s.y[2]=byte("p1_y"); s.y[3]=byte("m1_y");
      s.valid=byte("valid");
      snapshots_.push_back(s);
   }
   void begin_frame() {
      ++frame_; starts_.push_back(virtual_cycles_); snapshot();
      divider_active_=false;
   }
   void check_frames() const {
      for(size_t i=4;i<starts_.size();++i) {
         const uint64_t delta=starts_[i]-starts_[i-1];
         if(delta!=kRawFrameLines*kCyclesPerLine)
            fail("frame %zu is %llu raw lines + %llu cycles, expected %llu lines",
               i,static_cast<unsigned long long>(delta/kCyclesPerLine),
               static_cast<unsigned long long>(delta%kCyclesPerLine),
               static_cast<unsigned long long>(kRawFrameLines));
      }
   }
   void apply_pending() {
      for(const auto&w:pending_) {
         if(w.address==kWsync) {
            const uint64_t within=virtual_cycles_%kCyclesPerLine;
            virtual_cycles_ += within ? kCyclesPerLine-within : kCyclesPerLine;
            if(frame_>=4 && divider_active_ && last_wsync_boundary_ &&
               virtual_cycles_-last_wsync_boundary_>kCyclesPerLine) {
               ++gameplay_scanline_overruns_;
            }
            last_wsync_boundary_=virtual_cycles_;
         }
         else if((w.address==kPf0 || w.address==kPf1 || w.address==kPf2) &&
                 (memory_[kVblank]&2)==0) {
            const uint64_t within=virtual_cycles_%kCyclesPerLine;
            if(w.value==0xff && within>max_wall_pf_cycle_) max_wall_pf_cycle_=within;
            if(w.address==kPf2) {
               if(w.value==0x80) { divider_active_=true; saw_divider_=true; }
               if(divider_active_ && (w.value==0x00 || w.value==0x80) &&
                  within>max_divider_pf_cycle_) max_divider_pf_cycle_=within;
               if(divider_active_ && w.value==0xff) divider_active_=false;
            }
         }
         else if(w.address==kHmclr) {
            memory_[kHmp0]=0; memory_[kHmp1]=0;
            memory_[kHmm0]=0; memory_[kHmm1]=0; memory_[kHmbl]=0;
         }
         else if(w.address==kHmove) {
            // After startup, every HMOVE while VBLANK is asserted is the moving
            // Ball reposition. The four fixed-X paddles must all have zero
            // motion values, otherwise this HMOVE would make them creep.
            if(frame_>=4 && (memory_[kVblank]&2)!=0 &&
               (memory_[kHmp0] || memory_[kHmp1] || memory_[kHmm0] || memory_[kHmm1])) {
               ++fixed_paddle_hmove_violations_;
            }
         }
         else if(w.address==kVsync) {
            const bool next=(w.value&2)!=0;
            if(next&&!vsync_) begin_frame();
            vsync_=next;
         }
         else if(w.address==kVblank) {
            const bool next_dump=(w.value&0x80)!=0;
            if(pot_dump_ && !next_dump) pot_release_=virtual_cycles_;
            pot_dump_=next_dump;
         }
         else if(w.address>=kTim1t && w.address<=kT1024t) load_timer(w.address,w.value);
      }
      pending_.clear();
   }
};
Machine *Machine::active_=nullptr;

void require_raster_timing(const Machine& m,const char *label) {
   if(!m.saw_divider()) fail("%s never drew the center divider",label);
   if(m.max_divider_pf_cycle()>4)
      fail("%s center-divider PF2 write reached cycle %llu, expected <= 4",
           label,static_cast<unsigned long long>(m.max_divider_pf_cycle()));
   if(m.max_wall_pf_cycle()>24)
      fail("%s wall playfield write reached cycle %llu, expected <= 24",
           label,static_cast<unsigned long long>(m.max_wall_pf_cycle()));
   if(m.gameplay_scanline_overruns())
      fail("%s had %llu gameplay scanline overrun(s)",label,
           static_cast<unsigned long long>(m.gameplay_scanline_overruns()));
   if(m.fixed_paddle_hmove_violations())
      fail("%s had %llu HMOVE(s) with nonzero fixed-paddle motion registers",label,
           static_cast<unsigned long long>(m.fixed_paddle_hmove_violations()));
}

void require_distinct_channels(const std::vector<Snapshot>& snaps) {
   bool ok=false;
   for(const auto&s:snaps) {
      if(!s.valid) continue;
      if(s.p[0]+4<s.p[1] && s.p[1]+4<s.p[2] && s.p[2]+4<s.p[3]) { ok=true; break; }
   }
   if(!ok) fail("four independent RC thresholds never produced four distinct positions");
}

uint8_t player_y(uint8_t raw) {
   uint8_t y=0;
   if(raw>12) {
      y=static_cast<uint8_t>(raw-12);
      if(y>148) return 158;
   }
   return static_cast<uint8_t>((10+y)&0xfe);
}

uint8_t missile_y(uint8_t raw) {
   uint8_t y=0;
   if(raw>12) {
      y=static_cast<uint8_t>(raw-12);
      if(y>150) return 159;
   }
   return static_cast<uint8_t>((9+y)|1);
}

void require_channel_object_mapping(const std::vector<Snapshot>& snaps) {
   bool ok=false;
   for(const auto&s:snaps) {
      if(!s.valid) continue;
      if(s.y[0]==player_y(s.p[0]) && s.y[1]==missile_y(s.p[1]) &&
         s.y[2]==player_y(s.p[2]) && s.y[3]==missile_y(s.p[3])) {
         if(s.p[0]!=s.p[1] && s.p[1]!=s.p[2] && s.p[2]!=s.p[3]) { ok=true; break; }
      }
   }
   if(!ok) fail("four RC channels were not mapped independently to P0/M0/P1/M1");
}

void require_button(const std::vector<Snapshot>& snaps,int pressed) {
   bool ok=false;
   for(const auto&s:snaps) {
      if(!s.valid) continue;
      bool exact=true;
      for(int i=0;i<4;++i) exact &= (s.b[static_cast<size_t>(i)]==(i==pressed?1:0));
      if(exact) { ok=true; break; }
   }
   if(!ok) fail("button %d was not independently distinguishable",pressed);
}
} // namespace

int main(int argc,char **argv) {
   if(argc!=15) return 2;
   const char* names[]={"p0","p1","p2","p3","b0","b1","b2","b3","valid","p0_y","m0_y","p1_y","m1_y"};
   std::map<std::string,uint16_t> addresses;
   for(int i=0;i<13;++i) addresses[names[i]]=parse_addr(argv[i+2]);

   Machine distinct(argv[1],addresses,{{40,80,120,160}}); distinct.run(110);
   require_distinct_channels(distinct.snapshots());
   require_channel_object_mapping(distinct.snapshots());
   require_raster_timing(distinct,"distinct-threshold run");

   // Simultaneous and staggered threshold completion are the critical raster
   // cases. Every one must remain at the calibrated 264 raw intervals.
   Machine simultaneous(argv[1],addresses,{{200,200,200,200}}); simultaneous.run(90);
   require_raster_timing(simultaneous,"simultaneous-threshold run");
   Machine staggered(argv[1],addresses,{{200,160,120,80}}); staggered.run(90);
   require_raster_timing(staggered,"staggered-threshold run");

   // Sweep the region where RC completion lines coincide with paddle start/end
   // events. Older versions could hit or cross cycle 76 here, making the
   // playfield visibly shake even when a few spot-check frame counts passed.
   const int raster_thresholds[]={16,40,80,84,88,92,96,100,104,108,112,116,
                                  120,124,128,132,160,200,220};
   for(const int t:raster_thresholds) {
      Machine sweep(argv[1],addresses,{{t,t,t,t}}); sweep.run(30);
      char label[64]; std::snprintf(label,sizeof(label),"equal threshold %d",t);
      require_raster_timing(sweep,label);
   }

   // Equal-position sweeps are not sufficient: one channel's RC completion can
   // coincide with another paddle's start/end transition. Cross-sweep the two
   // player channels and the two missile channels independently. A previous
   // renderer hit cycle 76 for inner thresholds 88/84 and gained a scanline.
   const int cross_thresholds[]={40,80,84,88,96,104,112,120,128,132,160,200};
   for(const int a:cross_thresholds) for(const int b:cross_thresholds) {
      Machine outer(argv[1],addresses,{{a,80,b,120}}); outer.run(20);
      char label[80]; std::snprintf(label,sizeof(label),"outer cross %d/%d",a,b);
      require_raster_timing(outer,label);
      Machine inner(argv[1],addresses,{{80,a,120,b}}); inner.run(20);
      std::snprintf(label,sizeof(label),"inner cross %d/%d",a,b);
      require_raster_timing(inner,label);
   }

   for(int i=0;i<4;++i) {
      Machine button(argv[1],addresses,{{40,60,80,100}},i); button.run(40);
      require_button(button.snapshots(),i);
      require_raster_timing(button,"button run");
   }

   std::puts("vcs_four_player_paddleball ok: stable 4K raster, four independent RC channels and buttons");
   return 0;
}
