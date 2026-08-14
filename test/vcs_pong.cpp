//! @file vcs_pong.cpp
//! @brief CPU/TIA-input oracle for the public two-paddle Pong example.

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
constexpr uint16_t kEnam0=0x001d, kEnam1=0x001e;
constexpr uint16_t kInpt0=0x0038, kInpt1=0x0039;
constexpr uint16_t kSwcha=0x0280, kSwchb=0x0282;
constexpr uint16_t kIntim=0x0284, kTimint=0x0285;
constexpr uint16_t kTim1t=0x0294, kTim8t=0x0295, kTim64t=0x0296, kT1024t=0x0297;

[[noreturn]] void fail(const char *fmt,...) {
   std::fprintf(stderr,"vcs_pong: ");
   va_list ap; va_start(ap,fmt); std::vfprintf(stderr,fmt,ap); va_end(ap);
   std::fputc('\n',stderr); std::exit(1);
}

uint16_t parse_addr(const char *text) {
   char *end=nullptr; const unsigned long value=std::strtoul(text,&end,0);
   if(!text[0] || !end || *end || value>0xffff) fail("bad address '%s'",text);
   return static_cast<uint16_t>(value);
}

struct Snapshot {
   uint8_t p0=0,p1=0,valid=0,b0=0,b1=0;
   uint8_t left_y=0,right_y=0,ball_x=0,ball_y=0,waiting=0;
   uint16_t left_score=0,right_score=0;
};

class Machine {
public:
   Machine(const char *rom_path,const std::map<std::string,uint16_t>& a,
           int fixed_t0=-1,int fixed_t1=-1)
      : cpu_(read_thunk,write_thunk,clock_thunk), a_(a),
        fixed_t0_(fixed_t0), fixed_t1_(fixed_t1) {
      active_=this; std::memset(memory_,0,sizeof(memory_));
      std::ifstream rom(rom_path,std::ios::binary);
      if(!rom) fail("could not open ROM");
      rom.read(reinterpret_cast<char*>(memory_+kRomBase),kRomSize);
      if(rom.gcount()!=static_cast<std::streamsize>(kRomSize)) fail("ROM is not 4096 bytes");
      cpu_.Reset();
   }

   void run() {
      constexpr int kFrames=210;
      constexpr uint64_t kInstructionLimit=150000000;
      for(uint64_t instructions=0; instructions<kInstructionLimit && frame_<kFrames; ++instructions) {
         pending_.clear(); const uint64_t before=cpu_cycles_;
         cpu_.Run(1,cpu_cycles_,mos6502::INST_COUNT);
         virtual_cycles_ += cpu_cycles_-before;
         apply_pending();
      }
      if(frame_<kFrames) fail("instruction limit before %d frames",kFrames);

      for(size_t i=4;i<starts_.size();++i) {
         const uint64_t delta=starts_[i]-starts_[i-1];
         const uint64_t lines=delta/kCyclesPerLine;
         if(lines!=kRawFrameLines) fail("frame %zu is %llu raw lines + %llu cycles, expected %llu lines",
            i,static_cast<unsigned long long>(lines),
            static_cast<unsigned long long>(delta%kCyclesPerLine),
            static_cast<unsigned long long>(kRawFrameLines));
      }

      bool saw_valid=false,saw_long=false,saw_independent=false;
      bool saw_left_top=false,saw_right_top=false,saw_left_bottom=false,saw_right_bottom=false;
      bool saw_serve=false,saw_left_score=false,saw_reset=false;
      for(size_t i=0;i<snapshots_.size();++i) {
         const auto&s=snapshots_[i];
         if(s.valid) saw_valid=true;
         if(s.valid && (s.p0>120 || s.p1>120)) saw_long=true;
         if(s.valid && (s.p0>s.p1+20 || s.p1>s.p0+20)) saw_independent=true;
         if(s.left_y==9) saw_left_top=true;
         if(s.right_y==9) saw_right_top=true;
         if(s.left_y==159) saw_left_bottom=true;
         if(s.right_y==159) saw_right_bottom=true;
         if(s.left_y<9 || s.left_y>159 || !(s.left_y&1))
            fail("left paddle escaped legal odd Y range at frame %zu: %u",i,s.left_y);
         if(s.right_y<9 || s.right_y>159 || !(s.right_y&1))
            fail("right paddle escaped legal odd Y range at frame %zu: %u",i,s.right_y);
         // Once a completed endpoint measurement is visible in the public raw
         // position, the game must already be displaying that endpoint. This
         // rejects the former 2-scanline/frame slew that left seconds of queued
         // motion after the physical paddle stopped.
         if(s.valid && s.p0<=12 && s.left_y!=9)
            fail("left paddle lags completed top measurement at frame %zu: raw %u Y %u",i,s.p0,s.left_y);
         if(s.valid && s.p1<=12 && s.right_y!=9)
            fail("right paddle lags completed top measurement at frame %zu: raw %u Y %u",i,s.p1,s.right_y);
         if(s.valid && s.p0>=162 && s.left_y!=159)
            fail("left paddle lags completed bottom measurement at frame %zu: raw %u Y %u",i,s.p0,s.left_y);
         if(s.valid && s.p1>=162 && s.right_y!=159)
            fail("right paddle lags completed bottom measurement at frame %zu: raw %u Y %u",i,s.p1,s.right_y);
         if(i>10 && !s.waiting) saw_serve=true;
         if(!s.waiting && (s.ball_x<4 || s.ball_x>163))
            fail("Ball X wrapped outside stable visible range at frame %zu: %u",i,s.ball_x);
         if(!s.waiting && (s.ball_y<8 || s.ball_y>172))
            fail("Ball Y escaped drawable wall-bounce range at frame %zu: %u",i,s.ball_y);
         if(s.left_score!=0) saw_left_score=true;
         if(i>194 && saw_left_score && s.left_score==0 && s.right_score==0 && s.waiting) saw_reset=true;
      }
      bool saw_equal_phase=false,saw_left_full_height=false,saw_right_full_height=false;
      const size_t nframes=m0_on_.size();
      for(size_t i=0;i<nframes && i<snapshots_.size();++i) {
         if(snapshots_[i].left_y==snapshots_[i].right_y &&
            m0_on_[i]>=0 && m1_on_[i]>=0 && m0_off_[i]>=0 && m1_off_[i]>=0) {
            if(m0_on_[i]!=m1_on_[i] || m0_off_[i]!=m1_off_[i])
               fail("equal-Y paddles used different raster lines at frame %zu: M0 %d..%d M1 %d..%d",
                  i,m0_on_[i],m0_off_[i],m1_on_[i],m1_off_[i]);
            saw_equal_phase=true;
         }
         if(snapshots_[i].left_y==159 && m0_on_[i]>=0 && m0_off_[i]-m0_on_[i]==16)
            saw_left_full_height=true;
         if(snapshots_[i].right_y==159 && m1_on_[i]>=0 && m1_off_[i]-m1_on_[i]==16)
            saw_right_full_height=true;
      }
      if(!saw_equal_phase) fail("no frame proved common M0/M1 vertical raster phase");
      if(!saw_left_full_height || !saw_right_full_height)
         fail("both bottom-edge paddles did not disable after exactly 16 scanlines");

      if(!saw_valid) fail("paddle measurement never became valid");
      if(!saw_long) fail("long paddle measurement did not survive across frames");
      if(!saw_independent) fail("two paddle channels did not resolve independently");
      if(!saw_left_top || !saw_right_top) fail("both paddles did not reach symmetric top limit Y=9");
      if(!saw_left_bottom || !saw_right_bottom) fail("both paddles did not reach symmetric bottom limit Y=159");
      if(!saw_serve) fail("left paddle button never served the ball");
      if(!saw_left_score) fail("right-side miss never incremented left score");
      if(!saw_reset) fail("console Reset did not clear scores and return to serve");
   }

   void run_timing_only() {
      constexpr int kFrames=90;
      constexpr uint64_t kInstructionLimit=100000000;
      for(uint64_t instructions=0; instructions<kInstructionLimit && frame_<kFrames; ++instructions) {
         pending_.clear(); const uint64_t before=cpu_cycles_;
         cpu_.Run(1,cpu_cycles_,mos6502::INST_COUNT);
         virtual_cycles_ += cpu_cycles_-before;
         apply_pending();
      }
      if(frame_<kFrames) fail("instruction limit before timing probe completed");
      for(size_t i=4;i<starts_.size();++i) {
         const uint64_t delta=starts_[i]-starts_[i-1];
         const uint64_t lines=delta/kCyclesPerLine;
         if(lines!=kRawFrameLines || delta%kCyclesPerLine)
            fail("timing probe %d/%d frame %zu is %llu raw lines + %llu cycles, expected %llu lines",
               fixed_t0_,fixed_t1_,i,static_cast<unsigned long long>(lines),
               static_cast<unsigned long long>(delta%kCyclesPerLine),
               static_cast<unsigned long long>(kRawFrameLines));
      }
   }

private:
   struct Pending { uint16_t address; uint8_t value; };
   static Machine *active_;
   uint8_t memory_[65536]{}; mos6502 cpu_; std::map<std::string,uint16_t> a_;
   uint64_t cpu_cycles_=0,virtual_cycles_=0;
   std::vector<Pending> pending_; std::vector<uint64_t> starts_; std::vector<Snapshot> snapshots_;
   std::vector<int> m0_on_,m0_off_,m1_on_,m1_off_;
   bool vsync_=false,vblank_=true,pot_dump_=true,timer_active_=false;
   uint64_t pot_release_=0,timer_start_=0; uint16_t timer_divisor_=1; uint8_t timer_loaded_=0;
   int frame_=-1;
   int fixed_t0_=-1,fixed_t1_=-1;

   static uint8_t read_thunk(uint16_t a){ return active_->read(a); }
   static void write_thunk(uint16_t a,uint8_t v){ active_->write(a,v); }
   static void clock_thunk(mos6502*){}
   uint16_t word(uint16_t a) const { return static_cast<uint16_t>(memory_[a] | (memory_[a+1]<<8)); }
   uint8_t byte(const char*n) const { return memory_[a_.at(n)]; }
   uint16_t word_named(const char*n) const { return word(a_.at(n)); }

   bool timer_underflowed() const { return timer_active_ && (virtual_cycles_-timer_start_)/timer_divisor_>timer_loaded_; }
   uint8_t timer_value() const {
      if(!timer_active_) return memory_[kIntim];
      const uint64_t ticks=(virtual_cycles_-timer_start_)/timer_divisor_;
      if(ticks<=timer_loaded_) return static_cast<uint8_t>(timer_loaded_-ticks);
      return static_cast<uint8_t>(255-((ticks-timer_loaded_-1)&255));
   }
   uint8_t pot(uint64_t threshold_lines) const {
      if(pot_dump_) return 0;
      return virtual_cycles_-pot_release_ >= threshold_lines*kCyclesPerLine ? 0x80 : 0;
   }
   uint8_t read(uint16_t a) {
      if(a==kInpt0) return pot(fixed_t0_>=0 ? static_cast<uint64_t>(fixed_t0_) :
                                   static_cast<uint64_t>(frame_<105 ? 360 : 12));
      if(a==kInpt1) return pot(fixed_t1_>=0 ? static_cast<uint64_t>(fixed_t1_) :
                                   static_cast<uint64_t>(frame_<105 ? 12 : 360));
      if(a==kSwcha) {
         uint8_t v=0xff;
         if(frame_>=8 && frame_<=10) v&=0x7f; // left paddle fire serves
         return v;
      }
      if(a==kSwchb) return (frame_>=190 && frame_<=192) ? 0xfe : 0xff;
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
      s.p0=byte("p0"); s.p1=byte("p1"); s.valid=byte("valid");
      s.b0=byte("b0"); s.b1=byte("b1"); s.left_y=byte("left_y"); s.right_y=byte("right_y");
      s.ball_x=byte("ball_x"); s.ball_y=byte("ball_y");
      s.waiting=byte("waiting"); s.left_score=word_named("left_score"); s.right_score=word_named("right_score");
      snapshots_.push_back(s);
   }
   void begin_frame() {
      ++frame_; starts_.push_back(virtual_cycles_); snapshot();
      m0_on_.push_back(-1); m0_off_.push_back(-1);
      m1_on_.push_back(-1); m1_off_.push_back(-1);
   }
   void apply_pending() {
      for(const auto&w:pending_) {
         if((w.address==kEnam0 || w.address==kEnam1) && frame_>=0 && !starts_.empty()) {
            const int line=static_cast<int>(virtual_cycles_/kCyclesPerLine);
            auto& on=(w.address==kEnam0)?m0_on_.back():m1_on_.back();
            auto& off=(w.address==kEnam0)?m0_off_.back():m1_off_.back();
            if((w.value&2)!=0) {
               if(on<0) on=line;
            }
            else if(on>=0 && off<0) off=line;
         }
         if(w.address==kWsync) {
            const uint64_t within=virtual_cycles_%kCyclesPerLine;
            virtual_cycles_ += within ? kCyclesPerLine-within : kCyclesPerLine;
         }
         else if(w.address==kVsync) {
            const bool next=(w.value&2)!=0;
            if(next&&!vsync_) begin_frame();
            vsync_=next;
         }
         else if(w.address==kVblank) {
            vblank_=(w.value&2)!=0;
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
} // namespace

int main(int argc,char **argv) {
   if(argc!=14) return 2;
   const char* names[]={"p0","p1","valid","b0","b1","left_y","right_y","ball_x","ball_y","waiting","left_score","right_score"};
   std::map<std::string,uint16_t> addresses;
   for(int i=0;i<12;++i) addresses[names[i]]=parse_addr(argv[i+2]);
   // These two midrange combinations reproduce the two historical
   // paddle-dependent frame-length bugs: simultaneous threshold completion on
   // one scanline, and a channel-1 completion sharing a line with paddle
   // transition/bookkeeping. Both must remain at the scheduler's calibrated
   // 264 raw intervals (Stella: 262 displayed scanlines).
   Machine simultaneous(argv[1],addresses,200,200); simultaneous.run_timing_only();
   Machine asymmetric(argv[1],addresses,200,160); asymmetric.run_timing_only();

   Machine m(argv[1],addresses); m.run();
   std::puts("vcs_pong ok: stable frames, two-paddle RC span/buttons, serve, score, reset");
   return 0;
}
