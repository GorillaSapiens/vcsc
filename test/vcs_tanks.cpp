//! @file vcs_tanks.cpp
//! @brief CPU/TIA-input oracle for the public two-joystick Tanks example.

#include <array>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "mos6502.h"

namespace {
constexpr size_t kRomSize=8192;
constexpr uint64_t kCyclesPerLine=76;
constexpr uint64_t kRawFrameLines=264;
constexpr uint16_t kVsync=0x0000, kWsync=0x0002, kCxclr=0x002c;
constexpr uint16_t kPf0=0x000d;
constexpr uint16_t kAudc0=0x0015, kAudf0=0x0017, kAudv0=0x0019;
constexpr uint16_t kGrp0=0x001b, kGrp1=0x001c, kEnam0=0x001d, kEnam1=0x001e;
constexpr uint16_t kCxm0p=0x0030, kCxm1p=0x0031, kCxp0fb=0x0032, kCxp1fb=0x0033;
constexpr uint16_t kCxm0fb=0x0034, kCxm1fb=0x0035, kCxppmm=0x0037;
constexpr uint16_t kInpt4=0x003c, kInpt5=0x003d;
constexpr uint16_t kSwcha=0x0280, kSwchb=0x0282;
constexpr uint16_t kIntim=0x0284, kTimint=0x0285;
constexpr uint16_t kTim1t=0x0294, kTim8t=0x0295, kTim64t=0x0296, kT1024t=0x0297;
constexpr uint16_t kF8Hotspot0=0x1ff8, kF8Hotspot1=0x1ff9;
constexpr uint16_t kScWrite=0x1000, kScRead=0x1080;

constexpr uint8_t kStartX0=24, kStartX1=128, kStartY=45, kDirE=2, kDirW=6;
constexpr uint8_t kSoundFire=1, kSoundHit=2;

enum class Scenario { Neutral, Turn, Move, FireWall, HitP1, HitP0, PlayerWall, PlayerPlayer, Reset, ExtremeTiming };

[[noreturn]] void fail(const char *fmt,...) {
   std::fprintf(stderr,"vcs_tanks: ");
   va_list ap; va_start(ap,fmt); std::vfprintf(stderr,fmt,ap); va_end(ap);
   std::fputc('\n',stderr); std::exit(1);
}

uint16_t parse_addr(const char *text) {
   char *end=nullptr; const unsigned long value=std::strtoul(text,&end,0);
   if(!text[0] || !end || *end || value>0xffff) fail("bad address '%s'",text);
   return static_cast<uint16_t>(value);
}

uint16_t canonical(uint16_t address) { return static_cast<uint16_t>(address & 0x1fffu); }

struct Snapshot {
   uint8_t x0=0,x1=0,y0=0,y1=0,d0=0,d1=0;
   uint16_t g0=0,g1=0;
   uint8_t px0=0,px1=0,py0=0,py1=0,spin0=0,spin1=0;
   uint8_t m0x=0,m1x=0,m0y=0,m1y=0,m0d=0,m1d=0,m0a=0,m1a=0;
   uint16_t score0=0,score1=0;
   uint8_t move_phase=0,rng=0,sound_frames=0,sound_kind=0;
   uint8_t audc0=0,audf0=0,audv0=0;
   std::array<uint8_t,86> barrier_pf2{};
};

class Machine {
public:
   Machine(const char *rom_path,const std::map<std::string,uint16_t>& a,Scenario scenario)
      : cpu_(read_thunk,write_thunk,clock_thunk), a_(a), scenario_(scenario) {
      active_=this;
      memory_.fill(0); superchip_.fill(0xa7);
      std::ifstream rom(rom_path,std::ios::binary);
      if(!rom) fail("could not open ROM");
      rom_.assign(std::istreambuf_iterator<char>(rom),std::istreambuf_iterator<char>());
      if(rom_.size()!=kRomSize) fail("ROM is not 8192-byte F8SC");
      selected_file_bank_=1; // VCSC bank0/startup is the second physical F8 bank.
      cpu_.Reset();
   }

   void run(int frames=16) {
      constexpr uint64_t kInstructionLimit=120000000;
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
   bool missile_enabled(int side,int frame) const {
      if(frame<0 || frame>=static_cast<int>(beam_m0_.size())) return false;
      return side==0 ? beam_m0_[static_cast<size_t>(frame)] : beam_m1_[static_cast<size_t>(frame)];
   }
   uint8_t image_byte(uint16_t address) const { return inspect(address); }
   uint64_t max_nonzero_grp0_cycle() const { return max_nonzero_grp0_cycle_; }
   uint64_t max_nonzero_grp1_cycle() const { return max_nonzero_grp1_cycle_; }
   uint64_t max_full_pf0_cycle() const { return max_full_pf0_cycle_; }
   uint64_t max_side_pf0_cycle() const { return max_side_pf0_cycle_; }

private:
   struct Pending { uint16_t address; uint8_t value; };
   static Machine *active_;
   std::array<uint8_t,65536> memory_{};
   std::array<uint8_t,128> superchip_{};
   std::vector<uint8_t> rom_;
   mos6502 cpu_;
   std::map<std::string,uint16_t> a_;
   Scenario scenario_=Scenario::Neutral;
   int selected_file_bank_=1;
   uint64_t cpu_cycles_=0, virtual_cycles_=0;
   int frame_=0; bool vsync_=false;
   std::vector<uint64_t> starts_;
   std::vector<Snapshot> snapshots_;
   std::vector<Pending> pending_;
   std::array<bool,64> beam_m0_{};
   std::array<bool,64> beam_m1_{};
   bool timer_active_=false; uint64_t timer_start_=0,timer_divisor_=1; uint8_t timer_loaded_=0;
   bool arena_started_=false;
   uint64_t max_nonzero_grp0_cycle_=0, max_nonzero_grp1_cycle_=0;
   uint64_t max_full_pf0_cycle_=0, max_side_pf0_cycle_=0;

   static uint8_t read_thunk(uint16_t a) { return active_->read(a); }
   static void write_thunk(uint16_t a,uint8_t v) { active_->write(a,v); }
   static void clock_thunk(mos6502*) {}

   uint16_t addr(const char *name) const {
      const auto it=a_.find(name); if(it==a_.end()) fail("missing symbol %s",name);
      return it->second;
   }
   uint8_t byte(const char *name) const { return memory_[addr(name)]; }
   uint16_t word(const char *name) const {
      const uint16_t a=addr(name);
      return static_cast<uint16_t>(memory_[a] | (static_cast<uint16_t>(memory_[static_cast<uint16_t>(a+1)])<<8));
   }
   uint8_t inspect(uint16_t address) const {
      const uint16_t a=canonical(address);
      if(a>=kScRead && a<kScRead+128) return superchip_[static_cast<size_t>(a-kScRead)];
      if(a<0x1000) return memory_[a];
      const size_t off=static_cast<size_t>(selected_file_bank_)*4096u+static_cast<size_t>(a-0x1000);
      if(off>=rom_.size()) fail("inspect ROM outside image");
      return rom_[off];
   }

   void set_byte(const char *name,uint8_t v) { memory_[addr(name)]=v; }

   uint8_t swcha() const {
      uint8_t v=0xff;
      if(scenario_==Scenario::Turn) {
         if(frame_>=1 && frame_<=25) v=static_cast<uint8_t>(v & ~0x40u & ~0x08u); // P0 left, P1 right, held
         if(frame_==27) v=static_cast<uint8_t>(v & ~0x80u & ~0x04u); // opposite directions after release
      } else if(scenario_==Scenario::Move) {
         if(frame_>=1 && frame_<=4) v=static_cast<uint8_t>(v & ~0x10u & ~0x02u); // P0 forward, P1 reverse
         if(frame_>=5 && frame_<=8) v=static_cast<uint8_t>(v & ~0x20u & ~0x01u); // P0 reverse, P1 forward
      } else if(scenario_==Scenario::HitP1) {
         if(frame_==1) v=static_cast<uint8_t>(v & ~0x01u); // move P1 west before hit
      } else if(scenario_==Scenario::HitP0) {
         if(frame_==1) v=static_cast<uint8_t>(v & ~0x10u); // move P0 east before hit
      } else if(scenario_==Scenario::PlayerWall) {
         if(frame_==1) v=static_cast<uint8_t>(v & ~0x10u & ~0x02u);
         if(frame_==3) v=static_cast<uint8_t>(v & ~0x20u & ~0x01u); // back away after rollback
      } else if(scenario_==Scenario::PlayerPlayer) {
         if(frame_==1) v=static_cast<uint8_t>(v & ~0x10u & ~0x01u); // drive toward each other
         if(frame_==3) v=static_cast<uint8_t>(v & ~0x20u & ~0x02u); // back away after rollback
      } else if(scenario_==Scenario::Reset) {
         if(frame_==1) v=static_cast<uint8_t>(v & ~0x10u & ~0x80u);
      }
      return v;
   }

   bool fire_pressed(int side) const {
      if(scenario_==Scenario::FireWall) return frame_==1 || frame_==2;
      if(scenario_==Scenario::HitP1) return side==0 && frame_==1;
      if(scenario_==Scenario::HitP0) return side==1 && frame_==1;
      if(scenario_==Scenario::Reset) return frame_==1;
      return false;
   }

   uint8_t collision(uint16_t a) const {
      if(scenario_==Scenario::FireWall && frame_==4 && (a==kCxm0fb || a==kCxm1fb)) return 0x80;
      if(scenario_==Scenario::HitP1 && frame_==3 && a==kCxm0p) return 0x80;
      if(scenario_==Scenario::HitP0 && frame_==3 && a==kCxm1p) return 0x80;
      if(scenario_==Scenario::PlayerWall && frame_==2 && arena_started_ && (a==kCxp0fb || a==kCxp1fb)) return 0x80;
      if(scenario_==Scenario::PlayerPlayer && frame_==2 && arena_started_ && a==kCxppmm) return 0x80;
      if(scenario_==Scenario::ExtremeTiming && (frame_&1) && (a==kCxm0p || a==kCxm1p)) return 0x80;
      return 0;
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

   void select_hotspot(uint16_t address) {
      const uint16_t a=canonical(address);
      if(a==kF8Hotspot0) selected_file_bank_=0;
      else if(a==kF8Hotspot1) selected_file_bank_=1;
   }

   uint8_t read(uint16_t address) {
      select_hotspot(address);
      const uint16_t a=canonical(address);
      if(a==kSwcha) return swcha();
      if(a==kSwchb) return (scenario_==Scenario::Reset && frame_==2)?0xfe:0xff;
      if(a==kInpt4) return fire_pressed(0)?0x00:0x80;
      if(a==kInpt5) return fire_pressed(1)?0x00:0x80;
      if(a==kCxm0p || a==kCxm1p || a==kCxp0fb || a==kCxp1fb || a==kCxm0fb || a==kCxm1fb || a==kCxppmm) return collision(a);
      if(a==kIntim) return timer_value();
      if(a==kTimint) return timer_underflowed()?0x80:0;
      if(a>=kScRead && a<kScRead+128) return superchip_[static_cast<size_t>(a-kScRead)];
      if(a>=0x1000) {
         const size_t off=static_cast<size_t>(selected_file_bank_)*4096u+static_cast<size_t>(a-0x1000);
         if(off>=rom_.size()) fail("ROM read outside image");
         return rom_[off];
      }
      return memory_[a];
   }

   void write(uint16_t a,uint8_t v) { pending_.push_back({a,v}); }

   void load_timer(uint16_t a,uint8_t v) {
      timer_active_=true; timer_start_=virtual_cycles_; timer_loaded_=v;
      timer_divisor_=a==kTim1t?1:a==kTim8t?8:a==kTim64t?64:1024;
   }

   void inject_player_player_state() {
      if(scenario_!=Scenario::PlayerPlayer || frame_!=1) return;
      set_byte("tank0_x",70); set_byte("tank1_x",78);
      set_byte("tank0_y",kStartY); set_byte("tank1_y",kStartY);
      set_byte("tank0_prev_x",70); set_byte("tank1_prev_x",78);
      set_byte("tank0_prev_y",kStartY); set_byte("tank1_prev_y",kStartY);
      set_byte("tank0_direction",kDirE); set_byte("tank1_direction",kDirW);
      set_byte("tanks_move_phase",0);
   }

   void inject_extreme_state() {
      if(scenario_!=Scenario::ExtremeTiming || frame_<1) return;
      const bool odd=(frame_&1)!=0;
      set_byte("tank0_x",odd?4:148); set_byte("tank1_x",odd?148:4);
      set_byte("tank0_y",odd?4:78); set_byte("tank1_y",odd?4:78);
      set_byte("missile0_x",odd?2:157); set_byte("missile1_x",odd?157:2);
      set_byte("missile0_y",odd?4:78); set_byte("missile1_y",odd?4:78);
      set_byte("missile0_active",1); set_byte("missile1_active",1);
      set_byte("tank0_spin_frames",odd?24:0); set_byte("tank1_spin_frames",odd?24:0);
      set_byte("tanks_sound_frames",odd?24:4); set_byte("tanks_sound_kind",odd?kSoundHit:kSoundFire);
   }

   void snapshot() {
      Snapshot s;
      s.x0=byte("tank0_x"); s.x1=byte("tank1_x"); s.y0=byte("tank0_y"); s.y1=byte("tank1_y");
      s.d0=byte("tank0_direction"); s.d1=byte("tank1_direction");
      s.g0=word("tank0_graphics"); s.g1=word("tank1_graphics");
      s.px0=byte("tank0_prev_x"); s.px1=byte("tank1_prev_x"); s.py0=byte("tank0_prev_y"); s.py1=byte("tank1_prev_y");
      s.spin0=byte("tank0_spin_frames"); s.spin1=byte("tank1_spin_frames");
      s.m0x=byte("missile0_x"); s.m1x=byte("missile1_x"); s.m0y=byte("missile0_y"); s.m1y=byte("missile1_y");
      s.m0d=byte("missile0_direction"); s.m1d=byte("missile1_direction"); s.m0a=byte("missile0_active"); s.m1a=byte("missile1_active");
      s.score0=word("score_left_score"); s.score1=word("score_right_score");
      s.move_phase=byte("tanks_move_phase"); s.rng=byte("tanks_rng"); s.sound_frames=byte("tanks_sound_frames"); s.sound_kind=byte("tanks_sound_kind");
      s.audc0=memory_[kAudc0]; s.audf0=memory_[kAudf0]; s.audv0=memory_[kAudv0];
      const uint16_t base=addr("tanks_barrier_pf2");
      for(size_t i=0;i<s.barrier_pf2.size();++i) s.barrier_pf2[i]=inspect(static_cast<uint16_t>(base+i));
      snapshots_.push_back(s);
   }

   void begin_frame() {
      ++frame_;
      arena_started_=false;
      if(selected_file_bank_!=1) fail("VSYNC began without restoring the startup F8 bank");
      inject_player_player_state();
      inject_extreme_state();
      if((scenario_==Scenario::PlayerWall || scenario_==Scenario::PlayerPlayer) && frame_==3) set_byte("tanks_move_phase",0);
      starts_.push_back(virtual_cycles_);
      snapshot();
   }

   void apply_pending() {
      for(const auto&w:pending_) {
         const uint16_t a=canonical(w.address);
         if(a==kF8Hotspot0 || a==kF8Hotspot1) {
            select_hotspot(w.address);
            continue;
         }
         if(a>=kScWrite && a<kScWrite+128) {
            superchip_[static_cast<size_t>(a-kScWrite)]=w.value;
            continue;
         }
         if(a<0x1000) memory_[a]=w.value;
         if(arena_started_) {
            const uint64_t phase=virtual_cycles_%kCyclesPerLine;
            if(a==kGrp0 && w.value && phase>max_nonzero_grp0_cycle_) max_nonzero_grp0_cycle_=phase;
            if(a==kGrp1 && w.value && phase>max_nonzero_grp1_cycle_) max_nonzero_grp1_cycle_=phase;
            if(a==kPf0 && w.value==0xff && phase>max_full_pf0_cycle_) max_full_pf0_cycle_=phase;
            if(a==kPf0 && w.value==0x10 && phase>max_side_pf0_cycle_) max_side_pf0_cycle_=phase;
         }
         if(a==kCxclr) arena_started_=true;
         if(frame_>=0 && frame_<static_cast<int>(beam_m0_.size())) {
            if(a==kEnam0 && (w.value&2)) beam_m0_[static_cast<size_t>(frame_)]=true;
            if(a==kEnam1 && (w.value&2)) beam_m1_[static_cast<size_t>(frame_)]=true;
         }
         if(a==kWsync) {
            const uint64_t within=virtual_cycles_%kCyclesPerLine;
            virtual_cycles_ += within ? kCyclesPerLine-within : kCyclesPerLine;
         } else if(a==kVsync) {
            const bool next=(w.value&2)!=0;
            if(next&&!vsync_) begin_frame();
            vsync_=next;
         } else if(a>=kTim1t && a<=kT1024t) {
            load_timer(a,w.value);
         }
      }
      pending_.clear();
   }
};
Machine *Machine::active_=nullptr;

bool one_bit(uint8_t v) { return v && (v & static_cast<uint8_t>(v-1))==0; }


void require_raster_write_deadlines(const Machine& m) {
   if(m.max_nonzero_grp0_cycle()>8 || m.max_nonzero_grp1_cycle()>8)
      fail("player graphics are published too late in the scanline (GRP0=%llu GRP1=%llu cycles)",
           static_cast<unsigned long long>(m.max_nonzero_grp0_cycle()),
           static_cast<unsigned long long>(m.max_nonzero_grp1_cycle()));
   if(m.max_side_pf0_cycle()>18)
      fail("side-wall PF0 transition is too late in the scanline (%llu cycles)",
           static_cast<unsigned long long>(m.max_side_pf0_cycle()));
   if(m.max_full_pf0_cycle()>12)
      fail("full-wall PF0 transition is too late in the scanline (%llu cycles)",
           static_cast<unsigned long long>(m.max_full_pf0_cycle()));
}

void require_barriers(const Snapshot& s) {
   if(s.barrier_pf2[0]!=0xff || s.barrier_pf2[1]!=0xff)
      fail("top PF2 wall schedule is wrong");
   struct Zone { int lo,hi; } zones[]={{10,17},{36,43},{62,69}};
   std::array<bool,88> claimed{};
   for(const auto&z:zones) {
      int first=-1;
      for(int i=z.lo;i<=z.hi;++i) if(s.barrier_pf2[static_cast<size_t>(i)]) { first=i; break; }
      if(first<0) fail("vertical barrier missing from safe zone");
      const uint8_t mask=s.barrier_pf2[static_cast<size_t>(first)];
      if(!one_bit(mask)) fail("barrier mask is not one four-pixel PF2 column");
      for(int i=0;i<14;++i) {
         const int row=first+i;
         if(row>=86 || s.barrier_pf2[static_cast<size_t>(row)]!=mask) fail("barrier is not 28 scanlines tall");
         claimed[static_cast<size_t>(row)]=true;
      }
   }
   for(int i=2;i<86;++i)
      if(!claimed[static_cast<size_t>(i)] && s.barrier_pf2[static_cast<size_t>(i)]!=0)
         fail("unexpected horizontal playfield debris outside vertical barriers");
}

void require_graphics_base(const Machine& m,const Snapshot& s,uint16_t base) {
   if(s.g0!=static_cast<uint16_t>(base+s.d0*8u) || s.g1!=static_cast<uint16_t>(base+s.d1*8u))
      fail("tank graphics pointer does not include the actual table base");
   // With REFP0/REFP1 clear, bit 7 is the leftmost player pixel. The SE barrel
   // must therefore end in the low bits, while SW must end in the high bits.
   if(m.image_byte(static_cast<uint16_t>(base+3u*8u+6u))!=0x06 ||
      m.image_byte(static_cast<uint16_t>(base+3u*8u+7u))!=0x03 ||
      m.image_byte(static_cast<uint16_t>(base+5u*8u+6u))!=0x60 ||
      m.image_byte(static_cast<uint16_t>(base+5u*8u+7u))!=0xc0)
      fail("SE/SW tank graphics are swapped");
}

void require_turn(const std::vector<Snapshot>& s) {
   if(s.size()<30) fail("too few turn snapshots");
   if(s[1].d0!=1 || s[1].d1!=7) fail("initial left/right rotation did not change both headings");
   if(s[24].d0!=1 || s[24].d1!=7) fail("held rotation repeated faster than the quarter-rate cadence");
   if(s[25].d0!=0 || s[25].d1!=0) fail("held rotation did not repeat after 24 frames");
   if(s[27].d0!=1 || s[27].d1!=7) fail("opposite rotation after release is wrong");
}

void require_move(const std::vector<Snapshot>& s) {
   if(s.size()<10) fail("too few move snapshots");
   if(s[1].x0!=25 || s[1].y0!=kStartY || s[1].x1!=129 || s[1].y1!=kStartY)
      fail("forward/reverse movement from E/W headings is wrong");
   if(s[2].x0!=25 || s[3].x0!=25 || s[4].x0!=25 || s[2].x1!=129 || s[3].x1!=129 || s[4].x1!=129)
      fail("translation repeated before the four-frame cadence elapsed");
   if(s[5].x0!=24 || s[5].x1!=128) fail("reverse/forward return movement is wrong");
   if(s[6].x0!=24 || s[7].x0!=24 || s[8].x0!=24 || s[6].x1!=128 || s[7].x1!=128 || s[8].x1!=128)
      fail("return movement repeated before the four-frame cadence elapsed");
}

void require_fire_wall(const Machine& m,const std::vector<Snapshot>& s) {
   if(s.size()<7) fail("too few fire snapshots");
   if(!s[1].m0a || !s[1].m1a || s[1].m0d!=kDirE || s[1].m1d!=kDirW)
      fail("fire did not launch both missiles with tank headings");
   if(s[1].sound_kind!=kSoundFire || s[1].sound_frames!=4 || s[1].audc0!=8 || s[1].audf0!=4 || s[1].audv0!=8)
      fail("firing did not start the short noise effect");
   if(!m.missile_enabled(0,2) || !m.missile_enabled(1,2))
      fail("launched missile state never reached ENAM0/ENAM1 in the visible arena");
   if(s[2].m0x!=static_cast<uint8_t>(s[1].m0x+1) || s[2].m1x!=static_cast<uint8_t>(s[1].m1x-1))
      fail("held fire relaunched a missile instead of letting it travel");
   if(s[4].m0a || s[4].m1a) fail("missile-playfield collision did not stop both missiles");
}

void require_hit_p1(const std::vector<Snapshot>& s) {
   if(s.size()<30) fail("too few P1-hit snapshots");
   if(s[1].x1!=127 || !s[1].m0a) fail("P1 pre-hit setup failed");
   if(s[3].score0!=1 || s[3].score1!=0 || s[3].m0a || s[3].spin1!=23)
      fail("CXM0P hit did not score, stop M0, and start P1 spin");
   if(s[3].sound_kind!=kSoundHit || s[3].sound_frames!=24 || s[3].audc0!=8 || s[3].audf0!=20 || s[3].audv0!=15)
      fail("P1 hit did not start the longer hit noise");
   if(s[4].d1==s[3].d1 || s[5].d1==s[4].d1) fail("P1 is not spinning rapidly after the hit");
   if(s[26].spin1!=0 || s[26].d1>7) fail("P1 spin did not finish on a valid pseudo-random heading");
   if(s[27].sound_kind!=0 || s[27].sound_frames!=0 || s[27].audv0!=0) fail("hit noise did not terminate cleanly");
}

void require_hit_p0(const std::vector<Snapshot>& s) {
   if(s.size()<30) fail("too few P0-hit snapshots");
   if(s[1].x0!=25 || !s[1].m1a) fail("P0 pre-hit setup failed");
   if(s[3].score1!=1 || s[3].score0!=0 || s[3].m1a || s[3].spin0!=23)
      fail("CXM1P hit did not score, stop M1, and start P0 spin");
   if(s[4].d0==s[3].d0 || s[5].d0==s[4].d0) fail("P0 is not spinning rapidly after the hit");
   if(s[26].spin0!=0 || s[26].d0>7) fail("P0 spin did not finish on a valid pseudo-random heading");
}

void require_player_wall(const std::vector<Snapshot>& s) {
   if(s.size()<6) fail("too few player-wall snapshots");
   if(s[1].x0!=25 || s[1].x1!=129) fail("player-wall setup movement failed");
   if(s[2].x0!=24 || s[2].x1!=128 || s[2].y0!=kStartY || s[2].y1!=kStartY)
      fail("CXP0FB/CXP1FB did not immediately undo the movement that hit playfield geometry");
   if(s[2].px0!=24 || s[2].px1!=128 || s[2].py0!=kStartY || s[2].py1!=kStartY)
      fail("player-wall rollback left the saved legal position embedded in the playfield");
   if(s[3].x0!=23 || s[3].x1!=127)
      fail("tank could not immediately back away after player-playfield rollback");
}

void require_player_player(const std::vector<Snapshot>& s) {
   if(s.size()<6) fail("too few player-player snapshots");
   if(s[0].x0!=70 || s[0].x1!=78) fail("player-player setup did not start at adjacent legal positions");
   if(s[1].x0!=71 || s[1].x1!=77) fail("player-player setup movement did not overlap the tanks");
   if(s[2].x0!=70 || s[2].x1!=78 || s[2].y0!=kStartY || s[2].y1!=kStartY)
      fail("CXPPMM did not roll both tanks back to their last legal positions");
   if(s[2].px0!=70 || s[2].px1!=78 || s[2].py0!=kStartY || s[2].py1!=kStartY)
      fail("player-player rollback corrupted the saved legal positions");
   if(s[3].x0!=69 || s[3].x1!=79)
      fail("tanks could not immediately back away after player-player rollback");
}

void require_reset(const std::vector<Snapshot>& s) {
   if(s.size()<5) fail("too few reset snapshots");
   if(s[1].x0==kStartX0 && s[1].d0==kDirE) fail("reset setup did not disturb P0");
   if(s[2].x0!=kStartX0 || s[2].x1!=kStartX1 || s[2].y0!=kStartY || s[2].y1!=kStartY ||
      s[2].d0!=kDirE || s[2].d1!=kDirW || s[2].m0a || s[2].m1a || s[2].spin0 || s[2].spin1 ||
      s[2].score0 || s[2].score1 || s[2].sound_kind || s[2].sound_frames)
      fail("console Reset did not restore game state");
   require_barriers(s[2]);
   if(s[2].barrier_pf2==s[0].barrier_pf2) fail("Reset did not select a new pseudo-random barrier layout");
}

} // namespace

int main(int argc,char **argv) {
   const char *names[]={
      "tank0_x","tank1_x","tank0_y","tank1_y","tank0_direction","tank1_direction",
      "tank0_graphics","tank1_graphics",
      "tank0_prev_x","tank1_prev_x","tank0_prev_y","tank1_prev_y","tank0_spin_frames","tank1_spin_frames",
      "missile0_x","missile1_x","missile0_y","missile1_y","missile0_direction","missile1_direction","missile0_active","missile1_active",
      "score_left_score","score_right_score","tanks_move_phase","tanks_rng","tanks_sound_frames","tanks_sound_kind",
      "tanks_barrier_pf2","tanks_graphics"
   };
   constexpr int kSymbolCount=static_cast<int>(sizeof(names)/sizeof(names[0]));
   if(argc!=2+kSymbolCount) return 2;
   std::map<std::string,uint16_t> a;
   for(int i=0;i<kSymbolCount;++i) a[names[i]]=parse_addr(argv[i+2]);
   const uint16_t graphics_base=a["tanks_graphics"];

   for(const auto scenario : {Scenario::Neutral,Scenario::Turn,Scenario::Move,Scenario::FireWall,
                              Scenario::HitP1,Scenario::HitP0,Scenario::PlayerWall,Scenario::PlayerPlayer,Scenario::Reset,
                              Scenario::ExtremeTiming}) {
      Machine m(argv[1],a,scenario);
      const int frames=(scenario==Scenario::HitP1 || scenario==Scenario::HitP0 || scenario==Scenario::Turn)?30:16;
      m.run(frames);
      require_barriers(m.snapshots()[0]);
      require_raster_write_deadlines(m);
      if(scenario==Scenario::Neutral) require_graphics_base(m,m.snapshots()[0],graphics_base);
      else if(scenario==Scenario::Turn) require_turn(m.snapshots());
      else if(scenario==Scenario::Move) require_move(m.snapshots());
      else if(scenario==Scenario::FireWall) require_fire_wall(m,m.snapshots());
      else if(scenario==Scenario::HitP1) require_hit_p1(m.snapshots());
      else if(scenario==Scenario::HitP0) require_hit_p0(m.snapshots());
      else if(scenario==Scenario::PlayerWall) require_player_wall(m.snapshots());
      else if(scenario==Scenario::PlayerPlayer) require_player_player(m.snapshots());
      else if(scenario==Scenario::Reset) require_reset(m.snapshots());
   }
   std::puts("vcs_tanks ok: stable early raster writes, visible missiles, oriented tanks, 3+3 score, barriers, audio/spin, TIA collisions");
   return 0;
}
