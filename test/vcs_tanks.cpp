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
constexpr size_t kRomSize=4096;
constexpr uint64_t kCyclesPerLine=76;
constexpr uint64_t kRawFrameLines=264;
constexpr uint16_t kVsync=0x0000, kWsync=0x0002, kCxclr=0x002c;
constexpr uint16_t kRefp0=0x000b, kRefp1=0x000c, kPf0=0x000d;
constexpr uint16_t kResp0=0x0010, kResp1=0x0011, kHmp0=0x0020, kHmp1=0x0021;
constexpr uint16_t kAudc0=0x0015, kAudc1=0x0016, kAudf0=0x0017, kAudf1=0x0018, kAudv0=0x0019, kAudv1=0x001a;
constexpr uint16_t kGrp0=0x001b, kGrp1=0x001c, kEnam0=0x001d, kEnam1=0x001e;
constexpr uint16_t kCxm0p=0x0030, kCxm1p=0x0031, kCxp0fb=0x0032, kCxp1fb=0x0033;
constexpr uint16_t kCxm0fb=0x0034, kCxm1fb=0x0035, kCxppmm=0x0037;
constexpr uint16_t kInpt4=0x003c, kInpt5=0x003d;
constexpr uint16_t kSwcha=0x0280, kSwchb=0x0282;
constexpr uint16_t kIntim=0x0284, kTimint=0x0285;
constexpr uint16_t kTim1t=0x0294, kTim8t=0x0295, kTim64t=0x0296, kT1024t=0x0297;

constexpr uint8_t kStartX0=24, kStartX1=128, kStartY=45;
constexpr uint8_t kDirNne=1, kDirNe=2, kDirEne=3, kDirE=4, kDirSw=10, kDirW=12;
constexpr uint8_t kSoundFire=1, kSoundHit=2;

enum class Scenario { Neutral, Turn, Move, Move16, Missile45, MissileDirections, MissileBounds, HeadingSweep, PositionSweep, FireWall, HitP1, HitP0, HitBarrier, HitWallWrap, PlayerWall, PlayerPlayer, Reset, ExtremeTiming };

constexpr std::array<uint8_t,16> kPositionSweepX={
   4,5,14,15,16,29,30,44,59,74,89,104,119,134,147,148
};

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
   uint8_t px0=0,px1=0,py0=0,py1=0,spin0=0,spin1=0;
   uint8_t m0x=0,m1x=0,m0y=0,m1y=0,m0d=0,m1d=0,m0a=0,m1a=0;
   uint16_t score0=0,score1=0;
   uint8_t move_phase=0,rng=0,sound_frames=0,sound_kind=0;
   uint8_t audc0=0,audf0=0,audv0=0,audc1=0,audf1=0,audv1=0;
   std::array<uint8_t,86> barrier_pf2{};
};

class Machine {
public:
   Machine(const char *rom_path,const std::map<std::string,uint16_t>& a,Scenario scenario)
      : cpu_(read_thunk,write_thunk,clock_thunk), a_(a), scenario_(scenario) {
      active_=this;
      memory_.fill(0);
      std::ifstream rom(rom_path,std::ios::binary);
      if(!rom) fail("could not open ROM");
      rom_.assign(std::istreambuf_iterator<char>(rom),std::istreambuf_iterator<char>());
      if(rom_.size()!=kRomSize) fail("ROM is not 4096-byte 4K");
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
   uint8_t arena_refp0(int frame) const { return arena_refp0_[static_cast<size_t>(frame)]; }
   uint8_t arena_refp1(int frame) const { return arena_refp1_[static_cast<size_t>(frame)]; }
   uint8_t arena_xor0(int frame) const { return arena_xor0_[static_cast<size_t>(frame)]; }
   uint8_t arena_xor1(int frame) const { return arena_xor1_[static_cast<size_t>(frame)]; }
   uint8_t arena_hmp0(int frame) const { return arena_hmp0_[static_cast<size_t>(frame)]; }
   uint8_t arena_hmp1(int frame) const { return arena_hmp1_[static_cast<size_t>(frame)]; }
   uint8_t resp0_cycle(int frame) const { return resp0_cycle_[static_cast<size_t>(frame)]; }
   uint8_t resp1_cycle(int frame) const { return resp1_cycle_[static_cast<size_t>(frame)]; }

private:
   struct Pending { uint16_t address; uint8_t value; };
   static Machine *active_;
   std::array<uint8_t,65536> memory_{};
   std::vector<uint8_t> rom_;
   mos6502 cpu_;
   std::map<std::string,uint16_t> a_;
   Scenario scenario_=Scenario::Neutral;
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
   std::array<uint8_t,320> arena_refp0_{},arena_refp1_{},arena_xor0_{},arena_xor1_{};
   std::array<uint8_t,320> arena_hmp0_{},arena_hmp1_{},resp0_cycle_{},resp1_cycle_{};

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
      if(a<0x1000) return memory_[a];
      const size_t off=static_cast<size_t>(a-0x1000);
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
      } else if(scenario_==Scenario::Move16) {
         if(frame_>=1 && frame_<=20) v=static_cast<uint8_t>(v & ~0x10u & ~0x01u); // both forward
      } else if(scenario_==Scenario::HitP1) {
         if(frame_==1) v=static_cast<uint8_t>(v & ~0x01u); // move P1 west before hit
      } else if(scenario_==Scenario::HitP0) {
         if(frame_==1) v=static_cast<uint8_t>(v & ~0x10u); // move P0 east before hit
      } else if(scenario_==Scenario::HitBarrier) {
         if(frame_==27) v=static_cast<uint8_t>(v & ~0x01u); // drive P1 east out of the barrier after spin
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
      if(scenario_==Scenario::Missile45) return frame_==1;
      if(scenario_==Scenario::FireWall) return frame_==1 || frame_==2;
      if(scenario_==Scenario::HitP1 || scenario_==Scenario::HitBarrier || scenario_==Scenario::HitWallWrap) return side==0 && frame_==1;
      if(scenario_==Scenario::HitP0) return side==1 && frame_==1;
      if(scenario_==Scenario::Reset) return frame_==1;
      return false;
   }

   uint8_t collision(uint16_t a) const {
      if(scenario_==Scenario::FireWall && frame_==4 && (a==kCxm0fb || a==kCxm1fb)) return 0x80;
      if((scenario_==Scenario::HitP1 || scenario_==Scenario::HitBarrier || scenario_==Scenario::HitWallWrap) && frame_==3 && a==kCxm0p) return 0x80;
      if(scenario_==Scenario::HitBarrier && frame_>=4 && frame_<=28 && a==kCxp1fb) return 0x80;
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


   uint8_t read(uint16_t address) {
      const uint16_t a=canonical(address);
      if(a==kSwcha) return swcha();
      if(a==kSwchb) return (scenario_==Scenario::Reset && frame_==2)?0xfe:0xff;
      if(a==kInpt4) return fire_pressed(0)?0x00:0x80;
      if(a==kInpt5) return fire_pressed(1)?0x00:0x80;
      if(a==kCxm0p || a==kCxm1p || a==kCxp0fb || a==kCxp1fb || a==kCxm0fb || a==kCxm1fb || a==kCxppmm) return collision(a);
      if(a==kIntim) return timer_value();
      if(a==kTimint) return timer_underflowed()?0x80:0;
      if(a>=0x1000) {
         const size_t off=static_cast<size_t>(a-0x1000);
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


   void inject_move16_state() {
      if(scenario_!=Scenario::Move16 || frame_!=1) return;
      set_byte("tank0_x",80); set_byte("tank1_x",120);
      set_byte("tank0_y",60); set_byte("tank1_y",60);
      set_byte("tank0_prev_x",80); set_byte("tank1_prev_x",120);
      set_byte("tank0_prev_y",60); set_byte("tank1_prev_y",60);
      set_byte("tank0_direction",kDirNne); set_byte("tank1_direction",kDirEne);
      set_byte("tanks_move_phase",0);
   }

   void inject_missile45_state() {
      if(scenario_!=Scenario::Missile45 || frame_!=1) return;
      set_byte("tank0_x",60); set_byte("tank1_x",100);
      set_byte("tank0_y",60); set_byte("tank1_y",60);
      set_byte("tank0_prev_x",60); set_byte("tank1_prev_x",100);
      set_byte("tank0_prev_y",60); set_byte("tank1_prev_y",60);
      set_byte("tank0_direction",kDirNe); set_byte("tank1_direction",kDirSw);
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

   void inject_hit_barrier_state() {
      if(scenario_!=Scenario::HitBarrier) return;
      if(frame_==1) {
         // P1's preferred eastward 32-pixel destination is x=52,y=45. The
         // deterministic initial barrier schedule has PF2 bit 1 at rows 41..54,
         // covering x=52..55, so that first candidate must be rejected.
         set_byte("tank0_x",4); set_byte("tank1_x",20);
         set_byte("tank0_y",kStartY); set_byte("tank1_y",kStartY);
         set_byte("tank0_prev_x",4); set_byte("tank1_prev_x",20);
         set_byte("tank0_prev_y",kStartY); set_byte("tank1_prev_y",kStartY);
         set_byte("tank0_direction",kDirE); set_byte("tank1_direction",kDirW);
      }
      // The hit path advances 0x10 to 0x08, selecting knockback offset index 0
      // so straight-away east is selected. Keep CXP1FB asserted throughout the
      // hit spin, then drive east while it remains asserted for two more frames.
      // A tank that landed inside the barrier must make progress out of it.
      if(frame_==3) set_byte("tanks_rng",0x10);
      if(frame_==27) {
         set_byte("tank1_direction",kDirE);
         set_byte("tanks_move_phase",0);
      }
   }

   void inject_hit_wall_wrap_state() {
      if(scenario_!=Scenario::HitWallWrap) return;
      if(frame_==1) {
         // Put P1 hard against the right wall and shoot eastward from its left.
         // A straight 32-pixel hit displacement must pass through the wall and
         // wrap into the opposite side of the legal tank coordinate range.
         set_byte("tank0_x",100); set_byte("tank1_x",148);
         set_byte("tank0_y",kStartY); set_byte("tank1_y",kStartY);
         set_byte("tank0_prev_x",100); set_byte("tank1_prev_x",148);
         set_byte("tank0_prev_y",kStartY); set_byte("tank1_prev_y",kStartY);
         set_byte("tank0_direction",kDirE); set_byte("tank1_direction",kDirW);
      }
      if(frame_==3) set_byte("tanks_rng",0x10);
   }

   void inject_extreme_state() {
      if(scenario_!=Scenario::ExtremeTiming || frame_<1) return;
      const bool odd=(frame_&1)!=0;
      set_byte("tank0_x",odd?4:148); set_byte("tank1_x",odd?148:4);
      set_byte("tank0_y",odd?4:78); set_byte("tank1_y",odd?4:78);
      set_byte("missile0_x",odd?2:157); set_byte("missile1_x",odd?157:2);
      set_byte("missile0_y",odd?4:78); set_byte("missile1_y",odd?4:78);
      set_byte("tank0_spin_frames",odd?24:0); set_byte("tank1_spin_frames",odd?24:0);
      set_byte("tanks_sound_frames",odd?24:4); set_byte("tanks_sound_kind",odd?kSoundHit:kSoundFire);
   }

   void inject_heading_sweep_state() {
      if(scenario_!=Scenario::HeadingSweep || frame_<1 || frame_>16) return;
      const uint8_t direction=static_cast<uint8_t>(frame_-1);
      set_byte("tank0_direction",direction);
      set_byte("tank1_direction",direction);
   }

   void inject_position_sweep_state() {
      if(scenario_!=Scenario::PositionSweep || frame_<1 || frame_>16) return;
      const uint8_t x=kPositionSweepX[static_cast<size_t>(frame_-1)];
      set_byte("tank0_x",x); set_byte("tank1_x",x);
      set_byte("tank0_prev_x",x); set_byte("tank1_prev_x",x);
      set_byte("tank0_direction",kDirE); set_byte("tank1_direction",kDirE);
   }

   void inject_missile_directions_state() {
      if(scenario_!=Scenario::MissileDirections || frame_<1) return;
      const int offset=frame_-1;
      if(offset%17) return;
      const int direction=offset/17;
      if(direction<0 || direction>15) return;
      set_byte("missile0_x",80); set_byte("missile0_y",45);
      set_byte("missile0_direction",static_cast<uint8_t>(direction));
      memory_[static_cast<uint16_t>(addr("tanks_move_phase")+5)]=1;
   }

   void inject_missile_bounds_state() {
      if(scenario_!=Scenario::MissileBounds) return;
      if(frame_==1) {
         set_byte("missile0_x",159); set_byte("missile0_y",45); set_byte("missile0_direction",kDirE);
         set_byte("missile1_x",0); set_byte("missile1_y",45); set_byte("missile1_direction",kDirW);
         memory_[static_cast<uint16_t>(addr("tanks_move_phase")+5)]=1;
         memory_[static_cast<uint16_t>(addr("tanks_move_phase")+6)]=1;
      } else if(frame_==3) {
         set_byte("missile0_x",80); set_byte("missile0_y",85); set_byte("missile0_direction",8);
         set_byte("missile1_x",80); set_byte("missile1_y",0); set_byte("missile1_direction",0);
         memory_[static_cast<uint16_t>(addr("tanks_move_phase")+5)]=1;
         memory_[static_cast<uint16_t>(addr("tanks_move_phase")+6)]=1;
      }
   }

   void snapshot() {
      Snapshot s;
      s.x0=byte("tank0_x"); s.x1=byte("tank1_x"); s.y0=byte("tank0_y"); s.y1=byte("tank1_y");
      s.d0=byte("tank0_direction"); s.d1=byte("tank1_direction");
      s.px0=byte("tank0_prev_x"); s.px1=byte("tank1_prev_x"); s.py0=byte("tank0_prev_y"); s.py1=byte("tank1_prev_y");
      s.spin0=byte("tank0_spin_frames"); s.spin1=byte("tank1_spin_frames");
      s.m0x=byte("missile0_x"); s.m1x=byte("missile1_x"); s.m0y=byte("missile0_y"); s.m1y=byte("missile1_y");
      s.m0d=byte("missile0_direction"); s.m1d=byte("missile1_direction");
      s.m0a=memory_[static_cast<uint16_t>(addr("tanks_move_phase")+5)];
      s.m1a=memory_[static_cast<uint16_t>(addr("tanks_move_phase")+6)];
      s.score0=word("score_left_score"); s.score1=word("score_right_score");
      s.move_phase=byte("tanks_move_phase"); s.rng=byte("tanks_rng"); s.sound_frames=byte("tanks_sound_frames"); s.sound_kind=byte("tanks_sound_kind");
      s.audc0=memory_[kAudc0]; s.audf0=memory_[kAudf0]; s.audv0=memory_[kAudv0];
      s.audc1=memory_[kAudc1]; s.audf1=memory_[kAudf1]; s.audv1=memory_[kAudv1];
      const uint16_t rb=addr("tanks_barrier_event_row"), pb=addr("tanks_barrier_event_pf2");
      uint8_t pf=0; size_t ev=0;
      for(size_t i=0;i<s.barrier_pf2.size();++i) {
         while(ev<6 && memory_[static_cast<uint16_t>(rb+ev)]==i) { pf=memory_[static_cast<uint16_t>(pb+ev)]; ++ev; }
         s.barrier_pf2[i]=pf;
      }
      snapshots_.push_back(s);
   }

   void begin_frame() {
      ++frame_;
      arena_started_=false;
      inject_move16_state();
      inject_missile45_state();
      inject_player_player_state();
      inject_hit_barrier_state();
      inject_hit_wall_wrap_state();
      inject_extreme_state();
      inject_heading_sweep_state();
      inject_position_sweep_state();
      inject_missile_directions_state();
      inject_missile_bounds_state();
      if((scenario_==Scenario::PlayerWall || scenario_==Scenario::PlayerPlayer) && frame_==3) set_byte("tanks_move_phase",0);
      starts_.push_back(virtual_cycles_);
      snapshot();
   }

   void apply_pending() {
      for(const auto&w:pending_) {
         const uint16_t a=canonical(w.address);
         if(a<0x1000) memory_[a]=w.value;
         if(arena_started_) {
            const uint64_t phase=virtual_cycles_%kCyclesPerLine;
            if(a==kGrp0 && w.value && phase>max_nonzero_grp0_cycle_) max_nonzero_grp0_cycle_=phase;
            if(a==kGrp1 && w.value && phase>max_nonzero_grp1_cycle_) max_nonzero_grp1_cycle_=phase;
            if(a==kPf0 && w.value==0xff && phase>max_full_pf0_cycle_) max_full_pf0_cycle_=phase;
            if(a==kPf0 && w.value==0x10 && phase>max_side_pf0_cycle_) max_side_pf0_cycle_=phase;
         }
         if(a==kResp0) resp0_cycle_[static_cast<size_t>(frame_)]=static_cast<uint8_t>(virtual_cycles_%kCyclesPerLine);
         if(a==kResp1) resp1_cycle_[static_cast<size_t>(frame_)]=static_cast<uint8_t>(virtual_cycles_%kCyclesPerLine);
         if(a==kCxclr) {
            arena_started_=true;
            const size_t f=static_cast<size_t>(frame_);
            arena_refp0_[f]=memory_[kRefp0]; arena_refp1_[f]=memory_[kRefp1];
            arena_hmp0_[f]=memory_[kHmp0]; arena_hmp1_[f]=memory_[kHmp1];
            const uint16_t xb=addr("tanks_graphics_index_xor");
            arena_xor0_[f]=memory_[xb]; arena_xor1_[f]=memory_[static_cast<uint16_t>(xb+1)];
         }
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
   struct Zone { int lo,hi; } zones[]={{12,14},{36,38},{60,62}};
   std::array<bool,88> claimed{};
   std::array<int,3> starts{};
   size_t zone_index=0;
   for(const auto&z:zones) {
      int first=-1;
      for(int i=z.lo;i<=z.hi;++i) if(s.barrier_pf2[static_cast<size_t>(i)]) { first=i; break; }
      if(first<0) fail("vertical barrier missing from balanced zone");
      starts[zone_index++]=first;
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

   if(starts[1]-starts[0]!=24 || starts[2]-starts[1]!=24)
      fail("barriers no longer share one vertical offset");
   const int clear_pairs[]={
      starts[0]-2,
      starts[1]-(starts[0]+14),
      starts[2]-(starts[1]+14),
      86-(starts[2]+14)
   };
   for(const int gap:clear_pairs)
      if(gap<10)
         fail("barrier layout leaves less than the required 20-scanline passage");
}

size_t first_moved(const std::vector<Snapshot>& s,size_t first,uint8_t x,uint8_t y,bool player1) {
   for(size_t i=first;i<s.size();++i) {
      const uint8_t sx=player1?s[i].x1:s[i].x0;
      const uint8_t sy=player1?s[i].y1:s[i].y0;
      if(sx!=x || sy!=y) return i;
   }
   fail("hit spin never produced knockback translation");
}

void require_knockback_distance_and_geometry(const Snapshot& before,const Snapshot& after,bool player1,bool away_east) {
   const int bx=player1?before.x1:before.x0;
   const int by=player1?before.y1:before.y0;
   const int ax=player1?after.x1:after.x0;
   const int ay=player1?after.y1:after.y0;
   int dx=ax-bx, dy=ay-by;
   // Hit displacement wraps through the legal top-left arena ranges. Normalize
   // a wrapped coordinate delta back to the equivalent physical displacement.
   if(dx>72) dx-=145;
   else if(dx<-72) dx+=145;
   if(dy>37) dy-=75;
   else if(dy<-37) dy+=75;
   const int adx=dx<0?-dx:dx, ady=dy<0?-dy:dy;
   // Arena Y is doubled on screen, so 16 logical Y rows are 32 visible pixels.
   // Diagonal 23 X + 11 doubled Y rows is sqrt(23^2 + 22^2) ~= 31.8 pixels.
   const bool cardinal=(adx==32 && ady==0) || (adx==0 && ady==16);
   const bool diagonal=adx==23 && ady==11;
   if(!cardinal && !diagonal)
      fail("knockback displacement is not the requested ~32 visible pixels (dx=%d dy=%d)",dx,dy);
   if((away_east && dx<0) || (!away_east && dx>0))
      fail("knockback translated toward the shooter instead of into the away half-plane");
}

void require_graphics_base(const Machine& m,const Snapshot&,uint16_t base,uint16_t descriptor_base) {
   static constexpr uint8_t expected_graphics[40]={
      0x00,0x10,0x10,0xd6,0xfe,0xfe,0xc6,0xc6,
      0x24,0x64,0x79,0xff,0xff,0x4e,0x0e,0x04,
      0x19,0x3a,0x7c,0xff,0xdf,0x0e,0x1c,0x18,
      0x1c,0x78,0xfb,0x7c,0x1c,0x1f,0x3e,0x18,
      0xf8,0xf8,0x30,0x3e,0x30,0xf8,0xf8,0x00
   };
   static constexpr uint8_t expected_descriptor[16]={
      0x00,0x08,0x10,0x18,0x20,0x1f,0x17,0x0f,
      0x07,0x8f,0x97,0x9f,0xa0,0x98,0x90,0x88
   };
   for(size_t i=0;i<sizeof(expected_graphics);++i)
      if(m.image_byte(static_cast<uint16_t>(base+i))!=expected_graphics[i])
         fail("canonical five-sprite graphics byte %zu changed",i);
   for(size_t i=0;i<sizeof(expected_descriptor);++i)
      if(m.image_byte(static_cast<uint16_t>(descriptor_base+i))!=expected_descriptor[i])
         fail("16-way sprite transform descriptor byte %zu changed",i);
}

void require_turn(const std::vector<Snapshot>& s) {
   if(s.size()<30) fail("too few turn snapshots");
   if(s[1].d0!=3 || s[1].d1!=13) fail("initial left/right rotation did not change both headings");
   if(s[24].d0!=3 || s[24].d1!=13) fail("held rotation repeated faster than the quarter-rate cadence");
   if(s[25].d0!=2 || s[25].d1!=14) fail("held rotation did not repeat after 24 frames");
   if(s[27].d0!=3 || s[27].d1!=13) fail("opposite rotation after release is wrong");
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
   for(size_t i=1;i<=8;++i)
      if(s[i].audc1!=14 || s[i].audf1!=10 || s[i].audv1!=2)
         fail("movement did not sustain the low-volume engine growl on audio channel 1");
   if(s[9].audv1!=0) fail("engine growl did not stop when both tanks stopped moving");
}

void require_move16(const std::vector<Snapshot>& s) {
   if(s.size()<20) fail("too few 16-way movement snapshots");
   if(s[0].x0!=80 || s[0].y0!=60 || s[0].d0!=kDirNne ||
      s[0].x1!=120 || s[0].y1!=60 || s[0].d1!=kDirEne)
      fail("16-way movement setup failed");
   // Five quarter-rate movement ticks.  NNE/ENE use the same 7/16
   // minor-axis cadence on opposite axes and must remain distinct from NE.
   if(s[17].x0!=82 || s[17].y0!=55)
      fail("NNE did not follow the 16-way logical-grid cadence");
   if(s[17].x1!=125 || s[17].y1!=57)
      fail("ENE did not follow the 16-way logical-grid cadence");
}


void require_missile45(const std::vector<Snapshot>& s) {
   if(s.size()<7) fail("too few diagonal-missile snapshots");
   if(!s[1].m0a || !s[1].m1a || s[1].m0d!=kDirNe || s[1].m1d!=kDirSw)
      fail("diagonal fire did not inherit the two tank headings");
   // Four missile moves after the centered launch frame. A true NE/SW
   // projectile changes X and logical Y together on every step, matching
   // the 45-degree tank glyph rather than the old half-Y trajectory.
   if(s[5].m0x!=static_cast<uint8_t>(s[1].m0x+4) ||
      s[5].m0y!=static_cast<uint8_t>(s[1].m0y-4))
      fail("NE missile trajectory does not match the NE tank heading");
   if(s[5].m1x!=static_cast<uint8_t>(s[1].m1x-4) ||
      s[5].m1y!=static_cast<uint8_t>(s[1].m1y+4))
      fail("SW missile trajectory does not match the SW tank heading");
}


void require_heading_sweep(const Machine& m) {
   static constexpr uint8_t descriptor[16]={
      0x00,0x08,0x10,0x18,0x20,0x1f,0x17,0x0f,
      0x07,0x8f,0x97,0x9f,0xa0,0x98,0x90,0x88
   };
   for(int direction=0;direction<16;++direction) {
      const int frame=direction+1;
      const uint8_t expected_xor=static_cast<uint8_t>(descriptor[direction]&0x3f);
      const uint8_t expected_reflect=(descriptor[direction]&0x80)?8:0;
      if(m.arena_xor0(frame)!=expected_xor || m.arena_xor1(frame)!=expected_xor)
         fail("heading %d selected the wrong canonical sprite rows",direction);
      if(m.arena_refp0(frame)!=expected_reflect || m.arena_refp1(frame)!=expected_reflect)
         fail("heading %d lost its post-score REFP reflection",direction);
   }
}

void require_position_sweep(const Machine& m) {
   for(int frame=1;frame<=16;++frame) {
      if(m.resp0_cycle(frame)!=m.resp1_cycle(frame))
         fail("equal public X=%u reaches RESP0/RESP1 at different beam phases (%u/%u)",
              kPositionSweepX[static_cast<size_t>(frame-1)],m.resp0_cycle(frame),m.resp1_cycle(frame));
      if(m.arena_hmp0(frame)!=m.arena_hmp1(frame))
         fail("equal public X=%u produces different HMP0/HMP1 fine motion",
              kPositionSweepX[static_cast<size_t>(frame-1)]);
   }
}

void require_missile_directions(const std::vector<Snapshot>& s) {
   static constexpr int dx[16]={0,7,16,16,16,16,16,7,0,-7,-16,-16,-16,-16,-16,-7};
   static constexpr int dy[16]={-16,-16,-16,-7,0,7,16,16,16,16,16,7,0,-7,-16,-16};
   if(s.size()<272) fail("too few all-heading missile snapshots");
   for(int direction=0;direction<16;++direction) {
      const size_t first=static_cast<size_t>(17*direction);
      const size_t last=first+16;
      if(!s[first].m0a || s[first].m0x!=80 || s[first].m0y!=45 || s[first].m0d!=direction)
         fail("missile heading %d setup failed",direction);
      if(!s[last].m0a || static_cast<int>(s[last].m0x)!=80+dx[direction] || static_cast<int>(s[last].m0y)!=45+dy[direction])
         fail("missile heading %d trajectory is wrong: got (%u,%u), expected (%d,%d)",
              direction,s[last].m0x,s[last].m0y,80+dx[direction],45+dy[direction]);
   }
}

void require_missile_bounds(const std::vector<Snapshot>& s) {
   if(s.size()<4) fail("too few missile-bound snapshots");
   if(!s[0].m0a || !s[0].m1a || s[0].m0x!=159 || s[0].m1x!=0)
      fail("horizontal missile-bound setup failed");
   if(s[1].m0a || s[1].m1a || s[1].m0x || s[1].m1x || s[1].m0y || s[1].m1y)
      fail("horizontal missile escape survived into the next VBLANK");
   if(!s[2].m0a || !s[2].m1a || s[2].m0y!=85 || s[2].m1y!=0)
      fail("vertical missile-bound setup failed");
   if(s[3].m0a || s[3].m1a || s[3].m0x || s[3].m1x || s[3].m0y || s[3].m1y)
      fail("vertical missile escape survived into the next VBLANK");
}

void require_fire_wall(const Machine& m,const std::vector<Snapshot>& s) {
   if(s.size()<7) fail("too few fire snapshots");
   if(!s[1].m0a || !s[1].m1a || s[1].m0d!=kDirE || s[1].m1d!=kDirW)
      fail("fire did not launch both missiles with tank headings");
   // A two-pixel missile is centered on the eight-pixel tank at public X+3.
   if(s[1].m0x!=static_cast<uint8_t>(s[1].x0+3) ||
      s[1].m1x!=static_cast<uint8_t>(s[1].x1+3))
      fail("new missile did not use the centered public-coordinate launch point");
   if(s[1].sound_kind!=kSoundFire || s[1].sound_frames!=4 || s[1].audc0!=8 || s[1].audf0!=4 || s[1].audv0!=8)
      fail("firing did not start the short noise effect");
   if(!m.missile_enabled(0,2) || !m.missile_enabled(1,2))
      fail("launched missile state never reached ENAM0/ENAM1 in the visible arena");
   if(s[2].m0x!=static_cast<uint8_t>(s[1].m0x+1) || s[2].m1x!=static_cast<uint8_t>(s[1].m1x-1))
      fail("missile did not begin travelling after its centered launch frame");
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
   const size_t moved=first_moved(s,4,s[2].x1,s[2].y1,true);
   require_knockback_distance_and_geometry(s[2],s[moved],true,true);
   if(!s[moved].spin1) fail("P1 knockback was not completed during the visible hit spin");
   if(s[moved].px1!=s[moved].x1 || s[moved].py1!=s[moved].y1)
      fail("P1 knockback did not establish the translated position as the new legal rollback point");
   if(s[26].spin1!=0 || s[26].d1>15) fail("P1 spin did not finish on a valid pseudo-random heading");
   if(s[27].sound_kind!=0 || s[27].sound_frames!=0 || s[27].audv0!=0) fail("hit noise did not terminate cleanly");
}

void require_hit_p0(const std::vector<Snapshot>& s) {
   if(s.size()<30) fail("too few P0-hit snapshots");
   if(s[1].x0!=25 || !s[1].m1a) fail("P0 pre-hit setup failed");
   if(s[3].score1!=1 || s[3].score0!=0 || s[3].m1a || s[3].spin0!=23)
      fail("CXM1P hit did not score, stop M1, and start P0 spin");
   if(s[4].d0==s[3].d0 || s[5].d0==s[4].d0) fail("P0 is not spinning rapidly after the hit");
   const size_t moved=first_moved(s,4,s[2].x0,s[2].y0,false);
   require_knockback_distance_and_geometry(s[2],s[moved],false,false);
   if(!s[moved].spin0) fail("P0 knockback was not completed during the visible hit spin");
   if(s[moved].px0!=s[moved].x0 || s[moved].py0!=s[moved].y0)
      fail("P0 knockback did not establish the translated position as the new legal rollback point");
   if(s[26].spin0!=0 || s[26].d0>15) fail("P0 spin did not finish on a valid pseudo-random heading");
}

void require_hit_barrier(const std::vector<Snapshot>& s) {
   if(s.size()<30) fail("too few barrier-knockback snapshots");
   if(s[0].x0!=4 || s[0].x1!=20 || s[0].y1!=kStartY) fail("barrier-knockback setup failed");
   if(s[3].score0!=1 || s[3].spin1!=23) fail("barrier-knockback hit did not enter hit state");
   // Straight east lands at x=52,y=45, directly in the deterministic PF2
   // bit-1 barrier. Hit knockback deliberately ignores that geometry now.
   const size_t moved=first_moved(s,4,20,kStartY,true);
   require_knockback_distance_and_geometry(s[2],s[moved],true,true);
   if(s[moved].x1!=52 || s[moved].y1!=kStartY)
      fail("knockback did not pass straight through the known PF2 barrier");
   if(s[28].x1!=53 || s[29].x1!=53)
      fail("tank knocked into a barrier could not drive out while CXP1FB remained asserted");
}

void require_hit_wall_wrap(const std::vector<Snapshot>& s) {
   if(s.size()<8) fail("too few wall-wrap knockback snapshots");
   if(s[0].x0!=100 || s[0].x1!=148 || s[0].y1!=kStartY)
      fail("wall-wrap knockback setup failed");
   if(s[3].score0!=1 || s[3].spin1!=23)
      fail("wall-wrap hit did not enter hit state");
   const size_t moved=first_moved(s,4,148,kStartY,true);
   // Legal tank X positions are 4..148 inclusive (145 positions). Moving
   // east by 32 from 148 therefore wraps to 35.
   if(s[moved].x1!=35 || s[moved].y1!=kStartY)
      fail("east knockback at the right wall did not wrap to the opposite side");
   if(s[moved].px1!=35 || s[moved].py1!=kStartY)
      fail("wrapped knockback did not become the new rollback position");
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
      "tank0_prev_x","tank1_prev_x","tank0_prev_y","tank1_prev_y","tank0_spin_frames","tank1_spin_frames",
      "missile0_x","missile1_x","missile0_y","missile1_y","missile0_direction","missile1_direction",
      "score_left_score","score_right_score","tanks_move_phase","tanks_rng","tanks_sound_frames","tanks_sound_kind",
      "tanks_barrier_event_row","tanks_barrier_event_pf2","tanks_graphics","tanks_graphics_descriptor","tanks_graphics_index_xor"
   };
   constexpr int kSymbolCount=static_cast<int>(sizeof(names)/sizeof(names[0]));
   if(argc!=2+kSymbolCount) return 2;
   std::map<std::string,uint16_t> a;
   for(int i=0;i<kSymbolCount;++i) a[names[i]]=parse_addr(argv[i+2]);
   const uint16_t graphics_base=a["tanks_graphics"];

   for(const auto scenario : {Scenario::Neutral,Scenario::Turn,Scenario::Move,Scenario::Move16,Scenario::Missile45,
                              Scenario::MissileDirections,Scenario::MissileBounds,Scenario::HeadingSweep,Scenario::PositionSweep,Scenario::FireWall,
                              Scenario::HitP1,Scenario::HitP0,Scenario::HitBarrier,Scenario::HitWallWrap,Scenario::PlayerWall,Scenario::PlayerPlayer,Scenario::Reset,
                              Scenario::ExtremeTiming}) {
      Machine m(argv[1],a,scenario);
      const int frames=scenario==Scenario::MissileDirections?272:
                       ((scenario==Scenario::HeadingSweep || scenario==Scenario::PositionSweep)?17:
                        ((scenario==Scenario::HitP1 || scenario==Scenario::HitP0 || scenario==Scenario::HitBarrier || scenario==Scenario::Turn)?30:
                         (scenario==Scenario::Move16?24:16)));
      m.run(frames);
      require_barriers(m.snapshots()[0]);
      require_raster_write_deadlines(m);
      if(scenario==Scenario::Neutral) require_graphics_base(m,m.snapshots()[0],graphics_base,a["tanks_graphics_descriptor"]);
      else if(scenario==Scenario::Turn) require_turn(m.snapshots());
      else if(scenario==Scenario::Move) require_move(m.snapshots());
      else if(scenario==Scenario::Move16) require_move16(m.snapshots());
      else if(scenario==Scenario::Missile45) require_missile45(m.snapshots());
      else if(scenario==Scenario::MissileDirections) require_missile_directions(m.snapshots());
      else if(scenario==Scenario::MissileBounds) require_missile_bounds(m.snapshots());
      else if(scenario==Scenario::HeadingSweep) require_heading_sweep(m);
      else if(scenario==Scenario::PositionSweep) require_position_sweep(m);
      else if(scenario==Scenario::FireWall) require_fire_wall(m,m.snapshots());
      else if(scenario==Scenario::HitP1) require_hit_p1(m.snapshots());
      else if(scenario==Scenario::HitP0) require_hit_p0(m.snapshots());
      else if(scenario==Scenario::HitBarrier) require_hit_barrier(m.snapshots());
      else if(scenario==Scenario::HitWallWrap) require_hit_wall_wrap(m.snapshots());
      else if(scenario==Scenario::PlayerWall) require_player_wall(m.snapshots());
      else if(scenario==Scenario::PlayerPlayer) require_player_player(m.snapshots());
      else if(scenario==Scenario::Reset) require_reset(m.snapshots());
   }
   std::puts("vcs_tanks ok: stable early raster writes, visible missiles, 16-way tanks, 3+3 score, engine/fire/hit audio, wall-wrapping knockback, barriers, spin, TIA collisions");
   return 0;
}
