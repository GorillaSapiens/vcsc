//! @file vcs_score_matrix_raster.cpp
//! @brief Exact score-region raster oracle for the public 181+11 matrix.

#include <array>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase=0xF000;
constexpr size_t kRomSize=4096;
constexpr uint64_t kCyclesPerLine=76;
constexpr uint64_t kFrameLines=262;
constexpr uint16_t kVsync=0x0000,kVblank=0x0001,kWsync=0x0002;
constexpr uint16_t kNusiz0=0x0004,kNusiz1=0x0005,kColup0=0x0006,kColup1=0x0007,kColubk=0x0009;
constexpr uint16_t kRefp0=0x000B,kRefp1=0x000C,kResp0=0x0010,kResp1=0x0011;
constexpr uint16_t kGrp0=0x001B,kGrp1=0x001C,kHmp0=0x0020,kHmp1=0x0021;
constexpr uint16_t kHmm0=0x0022,kHmm1=0x0023,kHmbl=0x0024,kVdelp0=0x0025,kVdelp1=0x0026;
constexpr uint16_t kHmove=0x002A,kHmclr=0x002B;
constexpr uint16_t kIntim=0x0284,kTimint=0x0285,kTim1t=0x0294,kTim8t=0x0295,kTim64t=0x0296,kT1024t=0x0297;

constexpr std::array<std::array<uint8_t,8>,10> kSixFont{{
   {{0x3c,0x66,0x66,0x66,0x66,0x66,0x66,0x3c}},
   {{0x08,0x18,0x38,0x18,0x18,0x18,0x18,0x7e}},
   {{0x3c,0x46,0x06,0x06,0x3c,0x60,0x60,0x7e}},
   {{0x3c,0x46,0x06,0x1c,0x06,0x06,0x46,0x3c}},
   {{0x0c,0x1c,0x2c,0x4c,0x4c,0x7e,0x0c,0x0c}},
   {{0x7e,0x60,0x60,0x3c,0x06,0x06,0x46,0x3c}},
   {{0x3c,0x62,0x60,0x7c,0x66,0x66,0x66,0x3c}},
   {{0x3e,0x42,0x06,0x0c,0x18,0x30,0x30,0x30}},
   {{0x3c,0x66,0x66,0x3c,0x66,0x66,0x66,0x3c}},
   {{0x3c,0x66,0x66,0x66,0x3e,0x06,0x46,0x3c}}
}};
constexpr std::array<std::array<uint8_t,8>,10> kPairFont{{
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

struct PendingWrite{uint16_t address;uint8_t value;};
struct TimedWrite{
   uint64_t raw_line,raw_cycle,physical_line,beam_cycle;
   uint16_t address;uint8_t value;
};
struct FrameTrace{uint64_t start=0;std::vector<TimedWrite>writes;};

[[noreturn]] void fail(const char *fmt,...){
   std::fprintf(stderr,"vcs_score_matrix_raster: ");
   va_list ap;va_start(ap,fmt);std::vfprintf(stderr,fmt,ap);va_end(ap);
   std::fputc('\n',stderr);std::exit(1);
}

class Machine{
public:
   explicit Machine(const char *path):cpu_(read_thunk,write_thunk,clock_thunk){
      active_=this;std::memset(memory_,0,sizeof(memory_));
      std::ifstream rom(path,std::ios::binary);if(!rom)fail("could not open ROM");
      rom.read(reinterpret_cast<char*>(memory_+kRomBase),kRomSize);
      if(rom.gcount()!=static_cast<std::streamsize>(kRomSize))fail("ROM is not exactly 4K");
      cpu_.Reset();
   }
   std::vector<FrameTrace> run(){
      constexpr uint64_t limit=100000000;
      for(uint64_t i=0;i<limit&&frame_<7;++i){
         pending_.clear();const uint64_t before=cpu_cycles_;
         cpu_.Run(1,cpu_cycles_,mos6502::INST_COUNT);
         virtual_cycles_+=cpu_cycles_-before;apply_pending();
      }
      if(frame_<7)fail("instruction limit reached before enough frames");
      return frames_;
   }
private:
   static Machine *active_;uint8_t memory_[65536]{};mos6502 cpu_;
   uint64_t cpu_cycles_=0,virtual_cycles_=0,frame_start_=0,timer_start_=0;
   uint16_t timer_divisor_=1;uint8_t timer_loaded_=0;
   bool vsync_=false,timer_active_=false;int frame_=-1;
   std::vector<PendingWrite>pending_;std::vector<FrameTrace>frames_;
   static uint8_t read_thunk(uint16_t a){return active_->read(a);} static void write_thunk(uint16_t a,uint8_t v){active_->write(a,v);} static void clock_thunk(mos6502*){}
   bool timer_underflowed()const{return timer_active_&&(virtual_cycles_-timer_start_)/timer_divisor_>timer_loaded_;}
   uint8_t timer_value()const{if(!timer_active_)return memory_[kIntim];const uint64_t t=(virtual_cycles_-timer_start_)/timer_divisor_;if(t<=timer_loaded_)return static_cast<uint8_t>(timer_loaded_-t);return static_cast<uint8_t>(255-((t-timer_loaded_-1)&255));}
   uint8_t read(uint16_t a){if(a==kIntim)return timer_value();if(a==kTimint)return timer_underflowed()?0x80:0;return memory_[a];}
   void write(uint16_t a,uint8_t v){if(a<kRomBase)memory_[a]=v;pending_.push_back({a,v});}
   void load_timer(uint16_t a,uint8_t v){timer_active_=true;timer_start_=virtual_cycles_;timer_loaded_=v;timer_divisor_=a==kTim1t?1:a==kTim8t?8:a==kTim64t?64:1024;}
   void begin_frame(){++frame_;frame_start_=virtual_cycles_;FrameTrace f;f.start=frame_start_;frames_.push_back(f);}
   void record(const PendingWrite&w){if(frame_<0||static_cast<size_t>(frame_)>=frames_.size())return;const uint64_t rel=virtual_cycles_-frame_start_;const uint64_t physical=virtual_cycles_/kCyclesPerLine-frame_start_/kCyclesPerLine;frames_.back().writes.push_back({rel/kCyclesPerLine,rel%kCyclesPerLine,physical,virtual_cycles_%kCyclesPerLine,w.address,w.value});}
   void apply_pending(){for(const auto&w:pending_){if(w.address!=kWsync&&w.address!=kVsync)record(w);if(w.address==kWsync){const uint64_t within=virtual_cycles_%kCyclesPerLine;virtual_cycles_+=within?kCyclesPerLine-within:kCyclesPerLine;}else if(w.address==kVsync){const bool next=(w.value&2)!=0;if(next&&!vsync_)begin_frame();vsync_=next;}else if(w.address>=kTim1t&&w.address<=kT1024t)load_timer(w.address,w.value);}pending_.clear();}
};
Machine *Machine::active_=nullptr;

const TimedWrite&require_write(const FrameTrace&f,uint64_t line,uint64_t cycle,uint16_t address,uint8_t value,const char*name){
   for(const auto&w:f.writes)if(w.raw_line==line&&w.raw_cycle==cycle&&w.address==address){if(w.value!=value)fail("%s at %llu:%02llu is %02x, expected %02x",name,(unsigned long long)line,(unsigned long long)cycle,w.value,value);return w;}
   fail("missing %s at %llu:%02llu address %02x",name,(unsigned long long)line,(unsigned long long)cycle,address);
}
uint8_t packed_position(uint8_t x){const int rem=x%15;const int steps=x/15+1+(rem>=13?1:0);const int motion=15*steps-11-x;return static_cast<uint8_t>(((motion&15)<<4)|steps);}
int resp_cycle(uint8_t x){const int rem=x%15;const int steps=x/15+1+(rem>=13?1:0);return 9+5*steps;}

struct TiaState{
   uint8_t grp0_new=0,grp0_display=0,grp1_new=0,grp1_display=0;
   uint8_t nusiz0=0,nusiz1=0,refp0=0,refp1=0,colup0=0,colup1=0,colubk=0;
   bool vdelp0=false,vdelp1=false;
};
void apply_tia(TiaState&s,const TimedWrite&w){switch(w.address){
   case kGrp0:s.grp0_new=w.value;if(!s.vdelp0)s.grp0_display=w.value;s.grp1_display=s.grp1_new;break;
   case kGrp1:s.grp1_new=w.value;if(!s.vdelp1)s.grp1_display=w.value;s.grp0_display=s.grp0_new;break;
   case kNusiz0:s.nusiz0=w.value;break;case kNusiz1:s.nusiz1=w.value;break;
   case kColup0:s.colup0=w.value;break;case kColup1:s.colup1=w.value;break;case kColubk:s.colubk=w.value;break;
   case kRefp0:s.refp0=w.value;break;case kRefp1:s.refp1=w.value;break;
   case kVdelp0:s.vdelp0=(w.value&1)!=0;break;case kVdelp1:s.vdelp1=(w.value&1)!=0;break;
   default:break;
}}
bool glyph_pixel(uint8_t graphics,uint8_t refp,unsigned origin,unsigned scale,unsigned pixel){if(pixel<origin||pixel>=origin+8*scale)return false;unsigned source=(pixel-origin)/scale;if((refp&8)==0)source=7-source;return (graphics&(1u<<source))!=0;}

struct CopyLatch{unsigned origin=0,scale=1;uint8_t graphics=0,refp=0,color=0;bool latched=false;};
bool latched_pixel(const CopyLatch&c,unsigned pixel){return c.latched&&glyph_pixel(c.graphics,c.refp,c.origin,c.scale,pixel);}

void verify_six_schedule(const FrameTrace&f,uint64_t e,const std::string&kind){
   require_write(f,e,0,kNusiz0,3,"NUSIZ0");require_write(f,e,3,kNusiz1,3,"NUSIZ1");
   if(kind=="center"){
      require_write(f,e,14,kHmclr,0x0e,"HMCLR");require_write(f,e,19,kHmp0,0x80,"HMP0");require_write(f,e,24,kHmp1,0x90,"HMP1");
      require_write(f,e,29,kResp0,0x90,"RESP0");require_write(f,e,32,kResp1,0x90,"RESP1");
      bool fixed_color=false;
      for(const auto&w:f.writes) {
         if(w.raw_line==e&&w.raw_cycle==8&&w.address==kColup0) {
            fixed_color=true;
            break;
         }
      }
      if(fixed_color) {
         require_write(f,e,8,kColup0,0x0e,"COLUP0");require_write(f,e,11,kColup1,0x0e,"COLUP1");
      } else {
         require_write(f,e,38,kColup0,0x0e,"COLUP0");require_write(f,e,41,kColup1,0x0e,"COLUP1");
      }
   }else if(kind=="left"){
      require_write(f,e,10,kResp0,3,"RESP0");require_write(f,e,13,kResp1,3,"RESP1");require_write(f,e,19,kColup0,0x0e,"COLUP0");require_write(f,e,22,kColup1,0x0e,"COLUP1");
      require_write(f,e,25,kHmclr,0x0e,"HMCLR");require_write(f,e,30,kHmp0,0x30,"HMP0");require_write(f,e,35,kHmp1,0xb0,"HMP1");
   }else{
      require_write(f,e,6,kHmclr,3,"HMCLR");require_write(f,e,19,kHmp0,0xc0,"HMP0");require_write(f,e,24,kHmp1,0xd0,"HMP1");
      require_write(f,e,49,kResp0,0xd0,"RESP0");require_write(f,e,52,kResp1,0xd0,"RESP1");require_write(f,e,58,kColup0,0x0e,"COLUP0");require_write(f,e,61,kColup1,0x0e,"COLUP1");
   }
   require_write(f,e,71,kHmove,kind=="left"?0xb0:kind=="right"?0x0e:0x90,"HMOVE");
   require_write(f,e+1,9,kRefp0,0,"REFP0");require_write(f,e+1,12,kRefp1,0,"REFP1");require_write(f,e+1,19,kVdelp0,1,"VDELP0");require_write(f,e+1,22,kVdelp1,1,"VDELP1");
}

void verify_two_schedule(const FrameTrace&f,uint64_t e){
   require_write(f,e,0,kGrp0,0,"setup GRP0");require_write(f,e,3,kGrp1,0,"setup GRP1");require_write(f,e,6,kGrp0,0,"setup GRP0 delayed");
   require_write(f,e,9,kVdelp0,0,"VDELP0");require_write(f,e,12,kVdelp1,0,"VDELP1");require_write(f,e,15,kRefp0,0,"REFP0");require_write(f,e,18,kRefp1,0,"REFP1");
   require_write(f,e,21,kHmm0,0,"HMM0");require_write(f,e,24,kHmm1,0,"HMM1");require_write(f,e,27,kHmbl,0,"HMBL");
   require_write(f,e,32,kNusiz0,5,"NUSIZ0");require_write(f,e,35,kNusiz1,5,"NUSIZ1");require_write(f,e,41,kColup0,0x0e,"left color");require_write(f,e,47,kColup1,0x2e,"right color");
   const uint8_t lx=16,rx=104;require_write(f,e,74,kHmp0,packed_position(lx),"left packed HMP");require_write(f,e+1,resp_cycle(lx),kResp0,packed_position(lx)&15,"left RESP0");
   require_write(f,e+1,74,kHmp1,packed_position(rx),"right packed HMP");require_write(f,e+2,resp_cycle(rx),kResp1,packed_position(rx)&15,"right RESP1");require_write(f,e+2,71,kHmove,packed_position(rx)&15,"HMOVE");
}

void verify_poison_schedule(const FrameTrace&f,uint64_t e){
   require_write(f,e,0,kColubk,0x44,"red background");require_write(f,e,5,kColup0,0xac,"cyan P0");require_write(f,e,10,kColup1,0x1c,"yellow P1");
   require_write(f,e,15,kNusiz0,0x37,"NUSIZ0");require_write(f,e,20,kNusiz1,0x17,"NUSIZ1");require_write(f,e,25,kRefp0,8,"REFP0");require_write(f,e,28,kRefp1,8,"REFP1");
   require_write(f,e,33,kVdelp0,1,"VDELP0");require_write(f,e,36,kVdelp1,1,"VDELP1");require_write(f,e,41,kGrp0,0xaa,"GRP0");require_write(f,e,46,kGrp1,0x55,"GRP1");
   require_write(f,e,73,kHmp0,0x70,"HMP0");require_write(f,e+1,2,kHmp1,0x80,"HMP1");require_write(f,e+1,7,kHmm0,0,"HMM0");require_write(f,e+1,10,kHmm1,0,"HMM1");require_write(f,e+1,13,kHmbl,0,"HMBL");
   require_write(f,e+1,18,kResp0,0xff,"RESP0");require_write(f,e+1,21,kResp1,0xff,"RESP1");require_write(f,e+1,24,kHmove,0xff,"HMOVE");
   require_write(f,e+9,73,kGrp0,0,"cleanup GRP0");require_write(f,e+10,0,kGrp1,0,"cleanup GRP1");require_write(f,e+10,3,kGrp0,0,"cleanup delayed GRP0");
   require_write(f,e+10,6,kVdelp0,0,"cleanup VDELP0");require_write(f,e+10,9,kVdelp1,0,"cleanup VDELP1");require_write(f,e+10,15,kColubk,0x84,"background restore");
}

uint8_t pair_row(uint8_t packed,unsigned row){return static_cast<uint8_t>((kPairFont[(packed>>4)&15][row]<<5)|(kPairFont[packed&15][row]<<1));}

void verify_pixels(const FrameTrace&f,uint64_t entry,const std::string&kind){
   TiaState state;size_t next=0;
   const uint64_t last=entry+10;
   for(uint64_t line=0;line<=last;++line){
      std::vector<const TimedWrite*>events;
      while(next<f.writes.size()&&f.writes[next].physical_line<line){apply_tia(state,f.writes[next]);++next;}
      while(next<f.writes.size()&&f.writes[next].physical_line==line){events.push_back(&f.writes[next]);++next;}
      size_t event=0;
      std::array<CopyLatch,3>p0{},p1{};
      if(kind=="center"||kind=="left"||kind=="right"){
         const unsigned o0=kind=="center"?57u:kind=="left"?0u:112u;const unsigned o1=o0+8;
         for(unsigned i=0;i<3;++i){p0[i].origin=o0+16*i;p1[i].origin=o1+16*i;}
      }else if(kind=="two-plus-two"){
         p0[0].origin=16;p0[0].scale=2;p1[0].origin=104;p1[0].scale=2;
      }else if(kind=="poison"){
         p0[0].origin=9;p0[0].scale=4;p1[0].origin=33;p1[0].scale=4;
      }
      for(unsigned pixel=0;pixel<160;++pixel){
         const uint64_t color_clock=68+pixel;
         while(event<events.size()&&events[event]->beam_cycle*3<=color_clock){apply_tia(state,*events[event]);++event;}
         for(auto&c:p0)if(!c.latched&&pixel==c.origin){c.graphics=state.grp0_display;c.refp=state.refp0;c.color=state.colup0;c.latched=true;}
         for(auto&c:p1)if(!c.latched&&pixel==c.origin){c.graphics=state.grp1_display;c.refp=state.refp1;c.color=state.colup1;c.latched=true;}
         if(kind=="center"||kind=="left"||kind=="right"){
            if(line>=entry+2&&line<=entry+9){
               const unsigned row=static_cast<unsigned>(line-(entry+2));
               for(unsigned i=0;i<3;++i){
                  const bool a0=latched_pixel(p0[i],pixel),a1=latched_pixel(p1[i],pixel);
                  const bool e0=glyph_pixel(kSixFont[1+2*i][row],0,p0[i].origin,1,pixel);
                  const bool e1=glyph_pixel(kSixFont[2+2*i][row],0,p1[i].origin,1,pixel);
                  if(a0!=e0||a1!=e1)fail("%s row %u x=%u copy %u pixel mismatch P0=%u/%u P1=%u/%u",kind.c_str(),row,pixel,i,a0,e0,a1,e1);
                  if(a0&&p0[i].color!=0x0e) {
                     fail("%s P0 color mismatch",kind.c_str());
                  }
                  if(a1&&p1[i].color!=0x0e) {
                     fail("%s P1 color mismatch",kind.c_str());
                  }
               }
            }
         }else if(kind=="two-plus-two"){
            if(line>=entry+3&&line<=entry+10){
               const unsigned row=static_cast<unsigned>(line-(entry+3));const bool a0=latched_pixel(p0[0],pixel),a1=latched_pixel(p1[0],pixel);
               const bool e0=glyph_pixel(pair_row(0x12,row),0,16,2,pixel),e1=glyph_pixel(pair_row(0x34,row),0,104,2,pixel);
               if(a0!=e0||a1!=e1)fail("two-plus-two row %u x=%u pixel mismatch P0=%u/%u P1=%u/%u",row,pixel,a0,e0,a1,e1);
               if(a0&&p0[0].color!=0x0e) {
                  fail("two-plus-two left color mismatch");
               }
               if(a1&&p1[0].color!=0x2e) {
                  fail("two-plus-two right color mismatch");
               }
            }
         }else{
            if(line>=entry&&line<=entry+9&&state.colubk!=0x44)fail("poison line %llu x=%u background is %02x",(unsigned long long)(line-entry),pixel,state.colubk);
            if(line>=entry+1&&line<=entry+9){const bool a0=latched_pixel(p0[0],pixel),e0=glyph_pixel(0xaa,8,9,4,pixel);if(a0!=e0)fail("poison line %llu x=%u P0 pixel mismatch %u/%u",(unsigned long long)(line-entry),pixel,a0,e0);const bool a1=latched_pixel(p1[0],pixel);if(a1)fail("poison line %llu x=%u unexpectedly displays P1",(unsigned long long)(line-entry),pixel);if(a0&&p0[0].color!=0xac)fail("poison P0 color mismatch");}
         }
      }
      while(event<events.size()){apply_tia(state,*events[event]);++event;}
   }
   if(state.grp0_new||state.grp0_display||state.grp1_new||state.grp1_display||state.vdelp0||state.vdelp1)fail("%s did not leave clean player graphics",kind.c_str());
}

uint64_t parse_line(const char*s){char*e=nullptr;const unsigned long v=std::strtoul(s,&e,0);if(!*s||!e||*e)fail("bad entry line '%s'",s);return v;}
}

int main(int argc,char**argv){
   if(argc!=4){std::fprintf(stderr,"usage: %s ROM center|left|right|two-plus-two|poison ENTRY_LINE\n",argv[0]);return 2;}
   const std::string kind=argv[2];if(kind!="center"&&kind!="left"&&kind!="right"&&kind!="two-plus-two"&&kind!="poison")fail("bad score kind");
   const uint64_t entry=parse_line(argv[3]);Machine machine(argv[1]);const auto frames=machine.run();
   if(frames.size()<7) {
      fail("missing frame captures");
   }
   for(size_t i=3;i+1<frames.size();++i) {
      if(frames[i+1].start-frames[i].start!=kFrameLines*kCyclesPerLine) {
         fail("frame %zu is not exactly 262 lines",i);
      }
   }
   const FrameTrace&frame=frames[4];if(kind=="center"||kind=="left"||kind=="right")verify_six_schedule(frame,entry,kind);else if(kind=="two-plus-two")verify_two_schedule(frame,entry);else verify_poison_schedule(frame,entry);
   verify_pixels(frame,entry,kind);
   std::printf("vcs_score_matrix_raster %s ok: exact score pixels, ownership schedule, and 262-line frames\n",kind.c_str());
   return 0;
}
