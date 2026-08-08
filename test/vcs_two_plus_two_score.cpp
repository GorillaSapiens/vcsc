//! @file vcs_two_plus_two_score.cpp
//! @brief Exact timing and pixel oracle for the left/right two-plus-two score.

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
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerLine = 76;
constexpr uint64_t kFrameLines = 264;
constexpr int kFramesToRun = 100;

constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kVblank = 0x0001;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kNusiz0 = 0x0004;
constexpr uint16_t kNusiz1 = 0x0005;
constexpr uint16_t kColup0 = 0x0006;
constexpr uint16_t kColup1 = 0x0007;
constexpr uint16_t kRefp0 = 0x000B;
constexpr uint16_t kRefp1 = 0x000C;
constexpr uint16_t kResp0 = 0x0010;
constexpr uint16_t kResp1 = 0x0011;
constexpr uint16_t kGrp0 = 0x001B;
constexpr uint16_t kGrp1 = 0x001C;
constexpr uint16_t kHmp0 = 0x0020;
constexpr uint16_t kHmp1 = 0x0021;
constexpr uint16_t kHmm0 = 0x0022;
constexpr uint16_t kHmm1 = 0x0023;
constexpr uint16_t kHmbl = 0x0024;
constexpr uint16_t kVdelp0 = 0x0025;
constexpr uint16_t kVdelp1 = 0x0026;
constexpr uint16_t kHmove = 0x002A;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTimint = 0x0285;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

constexpr std::array<std::array<uint8_t,8>,10> kFont{{
   {{0x7,0x5,0x5,0x5,0x5,0x5,0x5,0x7}},
   {{0x2,0x6,0x2,0x2,0x2,0x2,0x2,0x7}},
   {{0x7,0x1,0x1,0x7,0x4,0x4,0x4,0x7}},
   {{0x7,0x1,0x1,0x7,0x1,0x1,0x1,0x7}},
   {{0x5,0x5,0x5,0x7,0x1,0x1,0x1,0x1}},
   {{0x7,0x4,0x4,0x7,0x1,0x1,0x1,0x7}},
   {{0x7,0x4,0x4,0x7,0x5,0x5,0x5,0x7}},
   {{0x7,0x1,0x1,0x2,0x2,0x4,0x4,0x4}},
   {{0x7,0x5,0x5,0x7,0x5,0x5,0x5,0x7}},
   {{0x7,0x5,0x5,0x7,0x1,0x1,0x1,0x7}}
}};

struct PendingWrite { uint16_t address; uint8_t value; };
struct TimedWrite {
   uint64_t raw_line;
   uint64_t raw_cycle;
   uint64_t physical_line;
   uint64_t beam_cycle;
   uint16_t address;
   uint8_t value;
};
struct InstanceConfig {
   uint8_t left_score = 0;
   uint8_t right_score = 0;
   uint8_t left_color = 0;
   uint8_t right_color = 0;
   uint8_t left_x = 0;
   uint8_t right_x = 0;
};
struct FrameTrace {
   uint64_t start = 0;
   InstanceConfig top;
   InstanceConfig bottom;
   std::vector<TimedWrite> writes;
};
struct Addresses {
   std::array<uint8_t,6> top{};
   std::array<uint8_t,6> bottom{};
};

[[noreturn]] void fail(const char *fmt, ...) {
   std::fprintf(stderr,"vcs_two_plus_two_score: ");
   va_list ap;
   va_start(ap,fmt);
   std::vfprintf(stderr,fmt,ap);
   va_end(ap);
   std::fputc('\n',stderr);
   std::exit(1);
}

uint8_t parse_zp(const char *text) {
   char *end = nullptr;
   const unsigned long value = std::strtoul(text,&end,0);
   if (!text[0] || !end || *end || value > 0xff) fail("bad zero-page address '%s'",text);
   return static_cast<uint8_t>(value);
}

class Machine {
public:
   Machine(const char *rom_path,const Addresses &addresses)
      : cpu_(read_thunk,write_thunk,clock_thunk), addresses_(addresses) {
      active_ = this;
      std::memset(memory_,0,sizeof(memory_));
      std::ifstream rom(rom_path,std::ios::binary);
      if (!rom) fail("could not open ROM");
      rom.read(reinterpret_cast<char *>(memory_+kRomBase),kRomSize);
      if (rom.gcount()!=static_cast<std::streamsize>(kRomSize)) fail("ROM is not exactly 4096 bytes");
      cpu_.Reset();
   }

   std::vector<FrameTrace> run() {
      constexpr uint64_t kInstructionLimit = 200000000;
      for (uint64_t instructions=0;
           instructions<kInstructionLimit && frame_<kFramesToRun;
           ++instructions) {
         pending_.clear();
         const uint64_t before=cpu_cycles_;
         cpu_.Run(1,cpu_cycles_,mos6502::INST_COUNT);
         virtual_cycles_ += cpu_cycles_-before;
         apply_pending();
      }
      if (frame_<kFramesToRun) fail("instruction limit reached before %d frames",kFramesToRun);
      return frames_;
   }

private:
   static Machine *active_;
   uint8_t memory_[65536]{};
   mos6502 cpu_;
   Addresses addresses_;
   uint64_t cpu_cycles_ = 0;
   uint64_t virtual_cycles_ = 0;
   std::vector<PendingWrite> pending_;
   std::vector<FrameTrace> frames_;
   std::vector<uint64_t> frame_periods_;
   bool vsync_asserted_ = false;
   int frame_ = -1;
   uint64_t frame_start_ = 0;
   bool timer_active_ = false;
   uint64_t timer_start_ = 0;
   uint16_t timer_divisor_ = 1;
   uint8_t timer_loaded_ = 0;

   static uint8_t read_thunk(uint16_t address) { return active_->read(address); }
   static void write_thunk(uint16_t address,uint8_t value) { active_->write(address,value); }
   static void clock_thunk(mos6502 *) {}

   bool timer_underflowed() const {
      if (!timer_active_) return false;
      return (virtual_cycles_-timer_start_)/timer_divisor_ > timer_loaded_;
   }
   uint8_t timer_value() const {
      if (!timer_active_) return memory_[kIntim];
      const uint64_t ticks=(virtual_cycles_-timer_start_)/timer_divisor_;
      if (ticks<=timer_loaded_) return static_cast<uint8_t>(timer_loaded_-ticks);
      return static_cast<uint8_t>(255-((ticks-timer_loaded_-1)&255));
   }
   uint8_t read(uint16_t address) {
      if (address==kIntim) return timer_value();
      if (address==kTimint) return timer_underflowed() ? 0x80 : 0;
      return memory_[address];
   }
   void write(uint16_t address,uint8_t value) {
      if (address<kRomBase) memory_[address]=value;
      pending_.push_back({address,value});
   }
   InstanceConfig capture(const std::array<uint8_t,6> &a) const {
      return {memory_[a[0]],memory_[a[1]],memory_[a[2]],memory_[a[3]],memory_[a[4]],memory_[a[5]]};
   }
   void begin_frame() {
      if (frame_>=0) frame_periods_.push_back(virtual_cycles_-frame_start_);
      ++frame_;
      frame_start_=virtual_cycles_;
      FrameTrace trace;
      trace.start=frame_start_;
      trace.top=capture(addresses_.top);
      trace.bottom=capture(addresses_.bottom);
      frames_.push_back(trace);
   }
   void load_timer(uint16_t address,uint8_t value) {
      timer_active_=true;
      timer_start_=virtual_cycles_;
      timer_loaded_=value;
      timer_divisor_=address==kTim1t ? 1 : address==kTim8t ? 8 : address==kTim64t ? 64 : 1024;
   }
   void record(const PendingWrite &write) {
      if (frame_<0 || static_cast<size_t>(frame_)>=frames_.size()) return;
      const uint64_t relative=virtual_cycles_-frame_start_;
      const uint64_t physical=virtual_cycles_/kCyclesPerLine-frame_start_/kCyclesPerLine;
      frames_.back().writes.push_back({relative/kCyclesPerLine,relative%kCyclesPerLine,
                                      physical,virtual_cycles_%kCyclesPerLine,
                                      write.address,write.value});
   }
   void apply_pending() {
      for (const PendingWrite &write:pending_) {
         if (write.address!=kWsync && write.address!=kVsync) record(write);
         if (write.address==kWsync) {
            const uint64_t within=virtual_cycles_%kCyclesPerLine;
            virtual_cycles_ += within ? kCyclesPerLine-within : kCyclesPerLine;
         }
         else if (write.address==kVsync) {
            const bool next=(write.value&2)!=0;
            if (next && !vsync_asserted_) begin_frame();
            vsync_asserted_=next;
         }
         else if (write.address>=kTim1t && write.address<=kT1024t) {
            load_timer(write.address,write.value);
         }
      }
      pending_.clear();
   }
};
Machine *Machine::active_=nullptr;

const TimedWrite &require_write(const FrameTrace &frame,uint64_t raw_line,uint64_t raw_cycle,
                                uint16_t address,uint8_t value,const char *name) {
   for (const TimedWrite &write:frame.writes) {
      if (write.raw_line==raw_line && write.raw_cycle==raw_cycle && write.address==address) {
         if (write.value!=value)
            fail("%s at %llu:%02llu is %02x, expected %02x",name,
                 static_cast<unsigned long long>(raw_line),
                 static_cast<unsigned long long>(raw_cycle),write.value,value);
         return write;
      }
   }
   fail("missing %s at %llu:%02llu address %02x",name,
        static_cast<unsigned long long>(raw_line),
        static_cast<unsigned long long>(raw_cycle),address);
}

uint8_t packed_position(uint8_t x) {
   const int remainder=x%15;
   const int steps=x/15+1+(remainder>=13 ? 1 : 0);
   const int signed_motion=15*steps-11-x;
   return static_cast<uint8_t>(((signed_motion&15)<<4)|steps);
}
int resp_cycle(uint8_t x) {
   const int remainder=x%15;
   const int steps=x/15+1+(remainder>=13 ? 1 : 0);
   return 9+5*steps;
}
uint8_t packed_row(uint8_t score,unsigned row) {
   const unsigned tens=(score>>4)&15;
   const unsigned ones=score&15;
   if (tens>9 || ones>9) fail("fixture score %02x is not packed decimal",score);
   return static_cast<uint8_t>((kFont[tens][row]<<5)|(kFont[ones][row]<<1));
}

void verify_schedule(const FrameTrace &frame,uint64_t entry,const InstanceConfig &cfg,
                     const char *label) {
   bool shifted=false;
   for (const TimedWrite &write : frame.writes) {
      if (write.raw_line==entry-1 && write.raw_cycle==57 &&
          write.address==kGrp0 && write.value==0) {
         shifted=true;
         break;
      }
   }
   const auto phase=[&](uint64_t old_cycle) {
      return shifted && old_cycle<19
         ? std::pair<uint64_t,uint64_t>{entry-1,old_cycle+57}
         : std::pair<uint64_t,uint64_t>{entry,shifted?old_cycle-19:old_cycle};
   };
   const auto setup=[&](uint64_t old_cycle,uint16_t address,uint8_t value,const char *name) {
      const auto where=phase(old_cycle);
      require_write(frame,where.first,where.second,address,value,name);
   };

   setup(0,kGrp0,0,"setup GRP0 clear 1");
   setup(3,kGrp1,0,"setup GRP1 clear");
   setup(6,kGrp0,0,"setup GRP0 clear 2");
   setup(9,kVdelp0,0,"setup VDELP0");
   setup(12,kVdelp1,0,"setup VDELP1");
   setup(15,kRefp0,0,"setup REFP0");
   setup(18,kRefp1,0,"setup REFP1");
   setup(21,kHmm0,0,"setup HMM0");
   setup(24,kHmm1,0,"setup HMM1");
   setup(27,kHmbl,0,"setup HMBL");
   setup(32,kNusiz0,5,"setup NUSIZ0");
   setup(35,kNusiz1,5,"setup NUSIZ1");
   setup(41,kColup0,cfg.left_color,"setup left color");
   setup(47,kColup1,cfg.right_color,"setup right color");

   require_write(frame,entry,74,kHmp0,packed_position(cfg.left_x),"left packed HMP/control");
   require_write(frame,entry+1,static_cast<uint64_t>(resp_cycle(cfg.left_x)),
                 kResp0,static_cast<uint8_t>(packed_position(cfg.left_x)&15),"left RESP0");
   require_write(frame,entry+1,74,kHmp1,packed_position(cfg.right_x),"right packed HMP/control");
   require_write(frame,entry+2,static_cast<uint64_t>(resp_cycle(cfg.right_x)),
                 kResp1,static_cast<uint8_t>(packed_position(cfg.right_x)&15),"right RESP1");
   require_write(frame,entry+2,71,kHmove,static_cast<uint8_t>(packed_position(cfg.right_x)&15),
                 "score HMOVE");

   for (unsigned row=0;row<7;++row) {
      require_write(frame,entry+3+row,10,kGrp0,packed_row(cfg.left_score,row),"left glyph row");
      require_write(frame,entry+3+row,23,kGrp1,packed_row(cfg.right_score,row),"right glyph row");
   }
   require_write(frame,entry+10,9,kGrp0,packed_row(cfg.left_score,7),"left glyph final row");
   require_write(frame,entry+10,22,kGrp1,packed_row(cfg.right_score,7),"right glyph final row");
   require_write(frame,entry+10,45,kGrp0,0,"final left latch cleanup");
   require_write(frame,entry+10,63,kGrp1,0,"final right-edge latch cleanup");

   (void)label;
}

struct TiaState {
   uint8_t grp0_new=0,grp0_display=0,grp1_new=0,grp1_display=0;
   uint8_t nusiz0=0,nusiz1=0,refp0=0,refp1=0,colup0=0,colup1=0;
   uint8_t hmm0=0,hmm1=0,hmbl=0;
   bool vdelp0=false,vdelp1=false;
};
void apply_tia(TiaState &state,const TimedWrite &write) {
   switch (write.address) {
      case kGrp0:
         state.grp0_new=write.value;
         if (!state.vdelp0) state.grp0_display=write.value;
         state.grp1_display=state.grp1_new;
         break;
      case kGrp1:
         state.grp1_new=write.value;
         if (!state.vdelp1) state.grp1_display=write.value;
         state.grp0_display=state.grp0_new;
         break;
      case kNusiz0: state.nusiz0=write.value; break;
      case kNusiz1: state.nusiz1=write.value; break;
      case kColup0: state.colup0=write.value; break;
      case kColup1: state.colup1=write.value; break;
      case kRefp0: state.refp0=write.value; break;
      case kRefp1: state.refp1=write.value; break;
      case kVdelp0: state.vdelp0=(write.value&1)!=0; break;
      case kVdelp1: state.vdelp1=(write.value&1)!=0; break;
      case kHmm0: state.hmm0=write.value; break;
      case kHmm1: state.hmm1=write.value; break;
      case kHmbl: state.hmbl=write.value; break;
      default: break;
   }
}
bool player_pixel(uint8_t graphics,uint8_t refp,unsigned origin,unsigned pixel) {
   if (pixel<origin || pixel>=origin+16) return false;
   unsigned source=(pixel-origin)/2;
   if ((refp&8)==0) source=7-source;
   return (graphics&(1u<<source))!=0;
}

void verify_component_pixels(const FrameTrace &frame,uint64_t entry,
                             const InstanceConfig &cfg,TiaState &state,
                             size_t &next,const char *label) {
   while (next<frame.writes.size() && frame.writes[next].physical_line<entry) {
      apply_tia(state,frame.writes[next]);
      ++next;
   }

   if (entry==40) {
      if (state.grp0_new!=0xff || state.grp1_new!=0xff || !state.vdelp0 || !state.vdelp1 ||
          state.refp0!=8 || state.refp1!=8 || state.nusiz0!=7 || state.nusiz1!=7 ||
          state.colup0!=0x02 || state.colup1!=0x02 ||
          state.hmm0!=0x70 || state.hmm1!=0x80 || state.hmbl!=0x90)
         fail("%s did not actually enter from the hostile player/motion state",label);
   }

   for (uint64_t line=entry;line<entry+11;++line) {
      std::vector<const TimedWrite *> line_writes;
      while (next<frame.writes.size() && frame.writes[next].physical_line==line) {
         line_writes.push_back(&frame.writes[next]);
         ++next;
      }
      size_t event=0;
      bool latched0=false,latched1=false;
      uint8_t glyph0=0,glyph1=0,ref0=0,ref1=0;
      for (unsigned pixel=0;pixel<160;++pixel) {
         const uint64_t color_clock=68+pixel;
         while (event<line_writes.size() && line_writes[event]->beam_cycle*3<=color_clock) {
            apply_tia(state,*line_writes[event]);
            ++event;
         }

         if (line<entry+3) {
            if (state.grp0_display!=0 || state.grp1_display!=0)
               fail("%s leaked hostile player graphics on setup line %llu pixel %u",label,
                    static_cast<unsigned long long>(line-entry),pixel);
            continue;
         }

         const unsigned row=static_cast<unsigned>(line-(entry+3));
         if (!latched0 && pixel==cfg.left_x) {
            if ((state.nusiz0&7)!=5 || state.refp0!=0)
               fail("%s left player geometry was not owned at row %u",label,row);
            glyph0=state.grp0_display;
            ref0=state.refp0;
            latched0=true;
         }
         if (!latched1 && pixel==cfg.right_x) {
            if ((state.nusiz1&7)!=5 || state.refp1!=0)
               fail("%s right player geometry was not owned at row %u",label,row);
            glyph1=state.grp1_display;
            ref1=state.refp1;
            latched1=true;
         }

         const bool actual0=latched0 && player_pixel(glyph0,ref0,cfg.left_x,pixel);
         const bool actual1=latched1 && player_pixel(glyph1,ref1,cfg.right_x,pixel);
         const bool expected0=player_pixel(packed_row(cfg.left_score,row),0,cfg.left_x,pixel);
         const bool expected1=player_pixel(packed_row(cfg.right_score,row),0,cfg.right_x,pixel);
         if (actual0!=expected0 || actual1!=expected1)
            fail("%s exact pixel mismatch row %u x=%u P0=%u/%u P1=%u/%u",label,row,pixel,
                 actual0,expected0,actual1,expected1);
         if (actual0 && state.colup0!=cfg.left_color)
            fail("%s left color mismatch row %u x=%u",label,row,pixel);
         if (actual1 && state.colup1!=cfg.right_color)
            fail("%s right color mismatch row %u x=%u",label,row,pixel);
      }
      while (event<line_writes.size()) {
         apply_tia(state,*line_writes[event]);
         ++event;
      }
   }

   if (state.grp0_new || state.grp0_display || state.grp1_new || state.grp1_display ||
       state.vdelp0 || state.vdelp1 || state.refp0 || state.refp1 ||
       state.hmm0 || state.hmm1 || state.hmbl)
      fail("%s did not return with clean player latches and safe preserved-object motion",label);
}

void validate_config(const InstanceConfig &cfg,const InstanceConfig &expected,
                     const char *label) {
   if (cfg.left_score!=expected.left_score || cfg.right_score!=expected.right_score ||
       cfg.left_color!=expected.left_color || cfg.right_color!=expected.right_color ||
       cfg.left_x!=expected.left_x || cfg.right_x!=expected.right_x)
      fail("%s instance fields changed unexpectedly",label);
}

void verify_all(const std::vector<FrameTrace> &frames) {
   if (frames.size()<static_cast<size_t>(kFramesToRun+1)) fail("not enough frame captures");
   const InstanceConfig top_expected{0x12,0x34,0x3e,0xce,32,96};
   bool saw_left_low=false,saw_left_high=false,saw_right_low=false,saw_right_high=false;
   int previous_left=-1,previous_right=-1;

   TiaState persistent;
   for (size_t index=0;index<frames.size()-1;++index) {
      const FrameTrace &frame=frames[index];
      if (index>=3) {
         validate_config(frame.top,top_expected,"top");
         if (frame.bottom.left_score!=0x56 || frame.bottom.right_score!=0x78 ||
             frame.bottom.left_color!=0x6e || frame.bottom.right_color!=0xae)
            fail("bottom instance values or colors changed");
         if (frame.bottom.left_x<32 || frame.bottom.left_x>64 ||
             frame.bottom.right_x<80 || frame.bottom.right_x>144)
            fail("bottom instance moved outside its explicit score ranges");
         saw_left_low |= frame.bottom.left_x==32;
         saw_left_high |= frame.bottom.left_x==64;
         saw_right_low |= frame.bottom.right_x==80;
         saw_right_high |= frame.bottom.right_x==144;
         if (previous_left>=0 && std::abs(static_cast<int>(frame.bottom.left_x)-previous_left)!=1)
            fail("bottom left score position did not move exactly one pixel");
         if (previous_right>=0 && std::abs(static_cast<int>(frame.bottom.right_x)-previous_right)!=2)
            fail("bottom right score position did not move exactly two pixels");
         previous_left=frame.bottom.left_x;
         previous_right=frame.bottom.right_x;

         verify_schedule(frame,40,frame.top,"top");
         verify_schedule(frame,221,frame.bottom,"bottom");
      }

      // Maintain real TIA latch state across frames. On checked frames, stop at
      // each component to perform the physical-pixel comparison, then consume
      // the remaining writes in chronological order.
      if (index>=3) {
         size_t next=0;
         verify_component_pixels(frame,40,frame.top,persistent,next,"top");
         verify_component_pixels(frame,221,frame.bottom,persistent,next,"bottom");
         while (next<frame.writes.size()) {
            apply_tia(persistent,frame.writes[next]);
            ++next;
         }
      }
      else {
         for (const TimedWrite &write:frame.writes) apply_tia(persistent,write);
      }
   }
   if (!saw_left_low || !saw_left_high || !saw_right_low || !saw_right_high)
      fail("motion proof did not reach all four explicit score-position endpoints");
}

} // namespace

int main(int argc,char **argv) {
   if (argc!=14) {
      std::fprintf(stderr,
         "usage: %s ROM top_ls top_rs top_lc top_rc top_lx top_rx bottom_ls bottom_rs bottom_lc bottom_rc bottom_lx bottom_rx\n",
         argv[0]);
      return 2;
   }
   Addresses addresses;
   for (size_t i=0;i<6;++i) addresses.top[i]=parse_zp(argv[2+i]);
   for (size_t i=0;i<6;++i) addresses.bottom[i]=parse_zp(argv[8+i]);
   Machine machine(argv[1],addresses);
   const auto frames=machine.run();
   for (size_t i=3;i+1<frames.size();++i) {
      const uint64_t period=frames[i+1].start-frames[i].start;
      if (period!=kFrameLines*kCyclesPerLine)
         fail("frame %zu has %llu cycles instead of the 264-line raw-harness period calibrated to Stella's 262-line display",i,
              static_cast<unsigned long long>(period));
   }
   verify_all(frames);
   std::puts("vcs_two_plus_two_score ok: exact 2x2 digits, colors, independent motion, hostile-state ownership, and 262-line frames");
   return 0;
}
