//! @file vcs_keypad.cpp
//! @brief CPU/RIOT/TIA-input oracle for Atari 12-key keypad scanning.

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
constexpr uint64_t kMinSettleCycles = 480; // > 400 us at the NTSC 6507 clock
constexpr uint16_t kVsync=0x0000, kVblank=0x0001, kWsync=0x0002;
constexpr uint16_t kInpt0=0x0038, kInpt1=0x0039, kInpt2=0x003a,
                   kInpt3=0x003b, kInpt4=0x003c, kInpt5=0x003d;
constexpr uint16_t kSwcha=0x0280, kSwacnt=0x0281, kSwchb=0x0282;
constexpr uint16_t kIntim=0x0284, kTimint=0x0285;
constexpr uint16_t kTim1t=0x0294, kTim8t=0x0295, kTim64t=0x0296, kT1024t=0x0297;

[[noreturn]] void fail(const char *fmt, ...) {
   std::fprintf(stderr, "vcs_keypad: ");
   va_list ap; va_start(ap,fmt); std::vfprintf(stderr,fmt,ap); va_end(ap);
   std::fputc('\n',stderr); std::exit(1);
}

uint16_t parse_addr(const char *text) {
   char *end=nullptr; const unsigned long value=std::strtoul(text,&end,0);
   if(!text[0] || !end || *end || value>0xffff) fail("bad address '%s'",text);
   return static_cast<uint16_t>(value);
}

struct Snapshot {
   uint16_t keys=0, pressed=0, released=0;
   uint8_t key=0;
   uint8_t swacnt=0, swcha=0;
};

class Machine {
public:
   Machine(const char *rom_path, const std::map<std::string,uint16_t>& a,
           int active_side, int key_index, bool example=false,
           int second_key_index=-1)
      : cpu_(read_thunk,write_thunk,clock_thunk), a_(a),
        active_side_(active_side), key_index_(key_index), example_(example),
        second_key_index_(second_key_index) {
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

   void run(int frames=40) {
      constexpr uint64_t kInstructionLimit=80000000;
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
      if(min_settle_==UINT64_MAX || min_settle_<kMinSettleCycles)
         fail("minimum keypad row settle was %llu cycles, expected at least %llu",
              static_cast<unsigned long long>(min_settle_),
              static_cast<unsigned long long>(kMinSettleCycles));
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
   int active_side_=-1, key_index_=-1; bool example_=false; int second_key_index_=-1;
   uint64_t cpu_cycles_=0, virtual_cycles_=0;
   int frame_=0; bool vsync_=false;
   std::vector<uint64_t> starts_;
   std::vector<Snapshot> snapshots_;
   std::vector<Pending> pending_;
   uint8_t swcha_latch_=0xff, swacnt_=0;
   std::array<int,2> selected_row_{{-1,-1}};
   std::array<uint64_t,2> row_selected_at_{{0,0}};
   uint64_t min_settle_=UINT64_MAX;
   bool timer_active_=false; uint64_t timer_start_=0,timer_divisor_=1; uint8_t timer_loaded_=0;

   static uint8_t read_thunk(uint16_t a) { return active_->read(a); }
   static void write_thunk(uint16_t a,uint8_t v) { active_->write(a,v); }
   static void clock_thunk(mos6502*) {}

   uint8_t byte(const char *name) const {
      const auto it=a_.find(name); if(it==a_.end()) return 0;
      return memory_[it->second];
   }
   uint16_t word(const char *name) const {
      const auto it=a_.find(name); if(it==a_.end()) return 0;
      return static_cast<uint16_t>(memory_[it->second] | (memory_[static_cast<uint16_t>(it->second+1)]<<8));
   }

   int key_for_side(int side) const {
      // Hold the requested key long enough to cover several complete four-row scans.
      if(frame_>=8 && frame_<24) {
         if(example_) return side==active_side_?key_index_:(side==(1-active_side_)?second_key_index_:-1);
         return side==active_side_?key_index_:-1;
      }
      return -1;
   }

   int selected_row(int side) const {
      const int shift=side==0?4:0;
      const uint8_t ddr=static_cast<uint8_t>((swacnt_>>shift)&0x0f);
      if(ddr!=0x0f) return -1;
      const uint8_t rows=static_cast<uint8_t>((swcha_latch_>>shift)&0x0f);
      for(int row=0;row<4;++row)
         if(rows==static_cast<uint8_t>(0x0f & ~(1u<<row))) return row;
      return -1;
   }

   void update_selected_rows() {
      for(int side=0;side<2;++side) {
         const int next=selected_row(side);
         if(next!=selected_row_[side]) {
            selected_row_[side]=next;
            if(next>=0) row_selected_at_[side]=virtual_cycles_;
         }
      }
   }

   bool keypad_pressed(int side,int col) {
      const int row=selected_row_[side];
      if(row>=0) {
         const uint64_t settled=virtual_cycles_-row_selected_at_[side];
         if(settled<min_settle_) min_settle_=settled;
         if(settled<kMinSettleCycles)
            fail("side %d row %d read after only %llu cycles",side,row,
                 static_cast<unsigned long long>(settled));
      }
      const int key=key_for_side(side);
      return key>=0 && row==key/3 && col==key%3;
   }

   uint8_t keypad_matrix_column(int side,int col) {
      // The keypad is a switch matrix. Once the selected row has settled, a
      // pressed switch pulls its column LOW; an open switch reads HIGH. The
      // oracle intentionally exposes only that software-visible boolean
      // contract instead of duplicating Stella's internal electrical model.
      return keypad_pressed(side,col) ? 0x00 : 0x80;
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
      if(a==kSwcha) return static_cast<uint8_t>((swcha_latch_&swacnt_) | (0xff&~swacnt_));
      if(a==kSwacnt) return swacnt_;
      if(a==kSwchb) return 0xff;
      if(a==kInpt0) return (memory_[kVblank]&0x80)?0:keypad_matrix_column(0,0);
      if(a==kInpt1) return (memory_[kVblank]&0x80)?0:keypad_matrix_column(0,1);
      if(a==kInpt2) return (memory_[kVblank]&0x80)?0:keypad_matrix_column(1,0);
      if(a==kInpt3) return (memory_[kVblank]&0x80)?0:keypad_matrix_column(1,1);
      if(a==kInpt4) return keypad_matrix_column(0,2);
      if(a==kInpt5) return keypad_matrix_column(1,2);
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
         const char *prefix=active_side_==0?"left_keypad_":"right_keypad_";
         s.keys=word((std::string(prefix)+"keys").c_str());
         s.pressed=word((std::string(prefix)+"pressed").c_str());
         s.released=word((std::string(prefix)+"released").c_str());
         s.key=byte((std::string(prefix)+"key").c_str());
      } else {
         s.keys=word("keys"); s.pressed=word("pressed");
         s.released=word("released"); s.key=byte("key");
      }
      s.swacnt=swacnt_; s.swcha=swcha_latch_;
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
            swacnt_=w.value; update_selected_rows();
         } else if(w.address==kSwcha) {
            swcha_latch_=w.value; update_selected_rows();
         } else if(w.address>=kTim1t && w.address<=kT1024t) {
            load_timer(w.address,w.value);
         }
      }
      pending_.clear();
   }
};
Machine *Machine::active_=nullptr;

void require_key_sequence(const std::vector<Snapshot>& s,int key_index) {
   const uint16_t mask=static_cast<uint16_t>(1u<<key_index);
   const uint8_t code=static_cast<uint8_t>(key_index+1);
   bool saw_press=false,saw_held=false,saw_release=false,saw_idle=false;
   for(const auto&v:s) {
      if(v.keys==0 && v.key==0) saw_idle=true;
      if(v.keys==mask && v.key==code && v.pressed==mask) saw_press=true;
      if(v.keys==mask && v.key==code && v.pressed==0) saw_held=true;
      if(v.keys==0 && v.key==0 && v.released==mask) saw_release=true;
   }
   if(!saw_idle || !saw_press || !saw_held || !saw_release)
      fail("key index %d did not produce stable press/hold/release semantics",key_index);
}

} // namespace

int main(int argc,char **argv) {
   if(argc<8) return 2;
   const char *mode=argv[1];
   const char *rom=argv[2];
   std::map<std::string,uint16_t> a;
   if(std::strcmp(mode,"fixture")==0) {
      if(argc!=8) return 2;
      a["keys"]=parse_addr(argv[3]); a["pressed"]=parse_addr(argv[4]);
      a["released"]=parse_addr(argv[5]); a["key"]=parse_addr(argv[6]);
      const int side=std::atoi(argv[7]);
      for(int key=0;key<12;++key) {
         Machine m(rom,a,side,key,false); m.run(40); require_key_sequence(m.snapshots(),key);
         if(side==0) {
            if((m.swacnt()&0x0f)!=0x0f || (m.swcha_latch()&0x0f)!=0x05)
               fail("left-port scanner disturbed right-port output nibble");
         } else {
            if((m.swacnt()&0xf0)!=0xf0 || (m.swcha_latch()&0xf0)!=0x50)
               fail("right-port scanner disturbed left-port output nibble");
         }
      }
   } else if(std::strcmp(mode,"example")==0) {
      if(argc!=11) return 2;
      a["left_keypad_keys"]=parse_addr(argv[3]); a["left_keypad_pressed"]=parse_addr(argv[4]);
      a["left_keypad_released"]=parse_addr(argv[5]); a["left_keypad_key"]=parse_addr(argv[6]);
      a["right_keypad_keys"]=parse_addr(argv[7]); a["right_keypad_pressed"]=parse_addr(argv[8]);
      a["right_keypad_released"]=parse_addr(argv[9]); a["right_keypad_key"]=parse_addr(argv[10]);
      for(int side=0;side<2;++side) for(int key=0;key<12;++key) {
         Machine m(rom,a,side,key,true,-1); m.run(40); require_key_sequence(m.snapshots(),key);
      }
      // One combined run proves the two port matrices can be active independently.
      Machine both(rom,a,0,4,true,11); both.run(40); require_key_sequence(both.snapshots(),4);
   } else return 2;
   std::puts("vcs_keypad ok: both ports, all 12 keys, stable edges and >=400us row settling");
   return 0;
}
