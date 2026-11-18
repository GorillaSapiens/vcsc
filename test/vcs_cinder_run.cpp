// Behavioral CPU oracle; TIA geometry is independently checked by pixel tests.
#include <array>
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
[[noreturn]] void fail(const char*s) { std::fprintf(stderr,"cinder_run: %s\n",s); std::exit(1); }
uint16_t next(uint16_t s) { return (s>>1)^((s&1)?0xb400:0); }
uint16_t prev(uint16_t s) { return static_cast<uint16_t>(((s&0x8000)?(s^0xb400):s)<<1)|((s>>15)&1); }
class Machine {
   static Machine* active;
   uint8_t mem[65536]{},rom[16384]{};
   unsigned bank=3,mode;
   mos6502 cpu;
   std::map<std::string,unsigned> symbols;
   std::vector<std::pair<uint16_t,uint8_t>> writes;
   uint64_t cycles=0,clock=0,timer_start=0,last_start=0;
   unsigned divisor=1,loaded=0;
   int frame=-1;
   bool timer=false,sync=false,m0=false,m1=false,forward=false,backward=false,returned=false;
   bool jump=false,duck=false,killed=false,damaged=false,restarted=false,reset=false;
   uint16_t seed=0xace1;
   unsigned phase=0,camera=0,aim_mask=0;
   unsigned dot_moves=0;
   std::array<uint8_t,18> initial{};
   std::map<uint32_t,std::array<uint8_t,18>> visited;
   std::map<std::array<uint8_t,8>,bool> monsters;
   bool treasure_returned=false,treasure_other=false;
   int jump_tone=-1,catch_tone=-1;
   static uint8_t rd(uint16_t a) { return active->read(a); }
   static void wr(uint16_t a,uint8_t v) { active->write(a,v); }
   static void tick(mos6502*) {}
   unsigned addr(const char*s) { auto i=symbols.find(s); if(i==symbols.end()) fail(s); return i->second; }
   uint8_t val(const char*s) { return mem[addr(s)]; }
   void put(const char*s,uint8_t v) { mem[addr(s)]=v; }
   uint8_t keys() const {
      if(mode==1) return frame%640<320 ? 0x7f : 0xbf;
      if(mode==3) return frame<320?0x7f:frame<640?0xbf:0xff;
      if(mode==4) return 0xff;
      if(mode==2&&frame>=110&&frame<=113) return 0xef;
      if(mode==2 && frame>=20 && frame<100 && (frame-20)%10<3) {
         static const uint8_t aim[]={0x7f,0x6f,0xef,0xaf,0xbf,0x9f,0xdf,0x5f};
         return aim[(frame-20)/10];
      }
      if(mode==2) return frame==100?0xbf:0xff;
      if(frame>=10&&frame<50) return 0xef;
      if(frame>=60&&frame<70) return 0xdf;
      return 0xff;
   }
   uint8_t fire() const {
      if(frame==5 || (mode==0&&((frame>=100&&frame<=110)||frame==450)) || (mode==2&&frame==104)) return 0;
      if(mode==2 && frame>=20&&frame<100 && (frame-20)%10<3) return 0;
      if(mode==2&&frame>=109&&frame<=113) return 0;
      return 0x80;
   }
   uint8_t read(uint16_t a) {
      if(a>=0x180&&a<=0x1ff) return mem[a&255];
      if((a&0x1fff)>=0x1000) {
         if((a&0xfff)>=0x80&&(a&0xfff)<0x100) return mem[0xf080+(a&0x7f)];
         if((a&0xfff)>=0xff6&&(a&0xfff)<=0xff9) bank=(a&0xfff)-0xff6;
         return rom[bank*4096+(a&0xfff)];
      }
      if(a==0x280) return keys();
      if(a==0x282) return mode==0&&frame==510 ? 0xfe : 0xff;
      if(a==0x3c) return fire();
      if(a==0x37) return mode==0&&((frame>=150&&frame<=155)||frame==250||frame==350) ? 0x80 : 0;
      if(a==0x30) return mode==0&&frame==104 ? 0x80 : 0;
      if(a==0x31) return (mode==0&&frame==95)||(mode==3&&(frame==20||frame==100||frame==600)) ? 0x80 : 0;
      if(a==0x284||a==0x285) {
         auto t=timer?(clock-timer_start)/divisor:0;
         if(a==0x285) return t>loaded?0x80:0;
         return t<=loaded?static_cast<uint8_t>(loaded-t):static_cast<uint8_t>(255-((clock-timer_start-loaded*divisor-divisor)&255));
      }
      return mem[a];
   }
   void write(uint16_t a,uint8_t v) {
      if((a&0x1fff)>=0x1000) {
         if((a&0xfff)<0x80) mem[0xf080+(a&0x7f)]=v;
         if((a&0xfff)>=0xff6&&(a&0xfff)<=0xff9) bank=(a&0xfff)-0xff6;
         return;
      }
      if(a>=0x100&&a<=0x1ff) { mem[a&255]=v; mem[a]=v; }
      else mem[a]=v;
      if(a==0x2b) for(unsigned i=0x20;i<=0x24;++i) mem[i]=0;
      writes.emplace_back(a,v);
   }
   std::array<uint8_t,18> terrain() {
      std::array<uint8_t,18> a{};
      for(unsigned i=0;i<18;++i) a[i]=mem[addr("game_playfield")+i];
      return a;
   }
   void check_world() {
      auto c=val("world_camera"); int delta=static_cast<int8_t>(c-camera);
      if(delta==4) { forward=true; if(++phase==4) { seed=next(seed); phase=0; } }
      else if(delta==-4) { backward=true; if(!phase) { seed=prev(seed); phase=4; } --phase; }
      else if(delta) fail("camera skipped a terrain column");
      camera=c;
      uint16_t actual=val("world_seed")|(mem[addr("world_seed")+1]<<8);
      if(actual!=seed || val("world_phase")!=phase) fail("LFSR forward/inverse phase");
      auto end=seed; for(unsigned i=0;i<10;++i) end=next(end);
      if((val("world_end")|(mem[addr("world_end")+1]<<8))!=end) fail("LFSR window endpoint");
      std::array<uint8_t,18> expected{}; auto s=seed; auto p=phase;
      for(unsigned x=0;x<40;++x) {
         unsigned b=x<4?0:x<12?1:x<20?2:x<28?3:x<36?4:5;
         unsigned bit=x<4?x+4:x<12?11-x:x<20?x-12:x<28?27-x:x<36?x-28:43-x;
         for(unsigned t=0;t<3;++t) if(s&(1<<t)) expected[t*6+b]|=1<<bit;
         if(++p==4) { s=next(s);p=0; }
      }
      if(terrain()!=expected) fail("terrain differs from independent LFSR decoder");
      if(forward&&backward&&seed==0xace1&&phase==0&&terrain()==initial) returned=true;
      uint32_t key=(static_cast<uint32_t>(seed)<<2)|phase;
      auto old=visited.find(key);
      if(delta && old!=visited.end() && forward&&backward) {
         if(old->second!=terrain()) fail("revisited terrain changed");
         returned=true;
      }
      visited[key]=terrain();
   }
   void check_music() {
      // Independent score and 25-frame eighth-note clock: six eighths/bar,
      // eight bars, then an exact 1,200-frame loop. No gameplay SFX in mode 1.
      static const uint8_t score[]={
         0x91,0,11,14,15,17,0x93,17,14,0,15,14,
         0x8c,14,17,11,0,15,0x8e,17,19,17,0,11,
         0x91,15,14,11,12,14,0x8f,0,19,14,17,12,
         0x8b,12,14,15,17,19,0x8e,15,0,19,17,17
      };
      if(frame<7) {if(mem[0x1a]) fail("music played before starting");return;}
      unsigned index=((frame-7)/25)%48,age=(frame-7)%25;
      uint8_t note=score[index];
      unsigned volume=!note||age>=22?0:age<4?((note&0x80)?4:3):2;
      if(mem[0x16]!=12||mem[0x18]!=(note&31)) fail("music voice/pitch sequence");
      if(mem[0x1a]!=volume) fail("music volume envelope");
      if(val("music_step")!=(index+1)%48||val("music_clock")!=24-age) fail("music tempo or loop length");
   }
   void snapshot() {
      if(frame==2) initial=terrain();
      if(mode==1) { check_world(); check_music(); return; }
      if(mode==3) {
         if(frame>21) {
            if(!(mem[addr("treasure_taken")]&1)) fail("collected treasure flag was forgotten");
            if(!val("treasure_id")&&val("treasure_visible")) fail("collected treasure respawned");
            if(val("treasure_id")==1&&val("treasure_visible")) treasure_other=true;
            if(frame>550&&!val("treasure_id")&&!val("treasure_visible")) treasure_returned=true;
         }
         if((frame==102||frame==602)&&val("run_sound")==0x25) fail("repeated treasure paid again");
         return;
      }
      if(mode==4) {
         if(frame==10) {put("game_object_x",80);mem[addr("game_object_x")+1]=82;put("game_player1_y",25);put("monster_direction",255);}
         if(frame==30&&mem[addr("game_object_x")+1]>=78) fail("monster stopped or turned above player");
         if(frame>=40&&frame<=110&&(frame-40)%10==0) put("run_wave",1+(frame-40)/10);
         if(frame>=41&&frame<=111&&(frame-41)%10==0) {
            static const uint8_t colors[]={0x24,0x36,0x66,0x86,0xaa,0x0c,0x1a,0xca};
            if(val("game_monster_color")!=colors[(frame-41)/10]) fail("monster type did not select its tint");
            std::array<uint8_t,8> pixels{};
            for(unsigned i=0;i<8;++i) pixels[i]=mem[addr("monster_pixels")+i];
            monsters[pixels]=true;
         }
         if(frame==200&&val("run_wave")<=8) fail("monster did not leave screen and respawn");
         return;
      }
      if(mode==2) {
         if(frame>=23&&frame<=93&&(frame-23)%10==0) {
            static const int dx[]={4,4,0,-4,-4,-4,0,4},dy[]={0,-2,-2,-2,0,2,2,2};
            unsigned i=(frame-23)/10;
            if(!val("run_shot_active") || static_cast<int8_t>(val("run_shot_dx"))!=dx[i] ||
               static_cast<int8_t>(val("run_shot_dy"))!=dy[i]) fail("eight-direction aiming");
            if(val("game_object_x")!=80 || val("run_feet")!=73) fail("aiming also moved or jumped");
            aim_mask|=1<<i;
         }
         if(frame>=24&&frame<100&&(frame-24)%10==0) put("run_shot_active",0);
         if(frame==107&&(!val("run_shot_active")||static_cast<int8_t>(val("run_shot_dx"))!=-4||val("run_shot_dy"))) fail("neutral Fire ignored last facing");
         if(frame==108) put("run_shot_active",0);
         if(frame==112&&(!val("run_shot_active")||val("run_shot_dx")||static_cast<int8_t>(val("run_shot_dy"))!=-2||val("run_feet")!=73)) fail("buffered straight-up aiming");
         return;
      }
      if(frame==9) { for(unsigned i=0;i<18;++i) mem[addr("game_playfield")+i]=0; }
      if(frame==15 && val("run_feet")<73) jump=true;
      if(frame==55 && !val("run_grounded")) fail("held Up jumped again");
      if(frame==65 && val("run_duck")&&val("game_player0_height")==3) duck=true;
      if(frame==15&&mem[0x19]) jump_tone=mem[0x17];
      if(frame==98&&mem[0x19]) catch_tone=mem[0x17];
      if((frame==15||frame==98)&&mem[0x1a]!=1) fail("music did not duck under sound effects");
      if(frame==103&&!val("run_shot_active")) fail("Fire did not shoot");
      if(frame==105) { if(val("run_shot_active")) fail("M0 kill did not remove shot"); killed=true; }
      if(frame==110&&val("run_shot_active")) fail("held Fire spawned another shot");
      if(frame==152&&val("run_lives")==2&&val("run_immunity")) damaged=true;
      if(frame==158&&val("run_lives")!=2) fail("immunity did not suppress repeated damage");
      if(frame==352&&(val("run_mode")!=2||val("run_lives"))) fail("game over");
      if((frame==352||frame==512)&&mem[0x1a]) fail("music did not stop on game over/Reset");
      if(frame==452&&(mem[0x18]!=17||mem[0x1a]!=4)) fail("music did not restart from its first note");
      if(frame==452&&val("run_mode")==1&&val("run_lives")==3) restarted=true;
      if(frame==512&&!val("run_mode")&&!val("score_score")) reset=true;
      // Swept landings at every tier and a solid four-scanline underside.
      for(unsigned t=0;t<3;++t) {
         unsigned f=270+t*4;
         if(frame==static_cast<int>(f)) {
            for(unsigned i=0;i<18;++i) mem[addr("game_playfield")+i]=i/6==t?255:0;
            put("run_feet",23+t*16); put("run_velocity",3); put("run_grounded",0);
            put("run_jump",0);
         }
         if(frame==static_cast<int>(f+1)&&(val("run_feet")!=25+t*16||!val("run_grounded"))) fail("swept platform landing");
      }
      if(frame==284) { put("run_feet",67);put("run_velocity",static_cast<uint8_t>(-3));put("run_grounded",0);put("run_jump",0); }
      if(frame==285&&(val("run_feet")!=67||val("run_velocity"))) fail("solid underside");
      if(frame==286) for(unsigned i=0;i<18;++i) mem[addr("game_playfield")+i]=0;
      if(frame==300&&(val("run_feet")!=73||!val("run_grounded"))) fail("walking off a ledge");
   }
public:
   Machine(const char*r,const char*m,unsigned n):mode(n),cpu(rd,wr,tick) {
      active=this; std::ifstream f(r,std::ios::binary);f.read(reinterpret_cast<char*>(rom),sizeof rom);
      if(f.gcount()!=sizeof rom) fail("16K F6 ROM size");
      std::ifstream map(m); std::string l; std::regex re("^\\s*\\$([0-9a-fA-F]{4})\\s+(\\S+)");
      while(std::getline(map,l)) {std::smatch a;if(std::regex_search(l,a,re)) symbols[a[2]]=std::stoul(a[1],nullptr,16);}
      if(addr("courier")<0xf100||addr("invisible")<0xf100) fail("near sprite artwork is not in the raster bank");
      cpu.Reset();cpu.SetPC(read(0xfffc)|(read(0xfffd)<<8));
   }
   void run() {
      int deadline=mode==1?7200:mode==2?124:mode==3?720:mode==4?210:530;
      for(unsigned long i=0;i<90000000&&frame<deadline;++i) {
         writes.clear();auto before=cycles;cpu.Run(1,cycles,mos6502::INST_COUNT);clock+=cycles-before;
         for(auto w:writes) {
            if(w.first==0x2a&&!(mem[1]&2)&&clock%76==8) {
               if(val("game_aux_index")!=3||mem[0x20]||mem[0x21]||mem[0x22]) fail("dot HMOVE disturbed another object");
               if((mem[0x23]&0xf0)!=(dot_moves?0xf0:0x10)) fail("dot HMOVE is not minus/plus one pixel");
               ++dot_moves;
            }
            if(w.first==0x1d&&(w.second&2)) m0=true;
            if(w.first==0x1e&&(w.second&2)) m1=true;
            if(w.first==0x1f&&(w.second&2)) fail("Ball was enabled");
            if((w.first==0x1d||w.first==0x1e)&&(w.second&2)&&!(mem[1]&2)&&clock%76>22) fail("late missile enable");
            if(w.first==2) clock+=76-clock%76;
            if(w.first==0) {bool n=w.second&2;if(n&&!sync) {++frame;
               if(dot_moves&&dot_moves!=2) fail("unpaired dot HMOVE");
               dot_moves=0;
               if(frame>4&&clock-last_start!=264*76) { std::fprintf(stderr,"frame %d: %llu cycles\n",frame,static_cast<unsigned long long>(clock-last_start));fail("unstable frame period"); }
               last_start=clock;snapshot();}sync=n;}
            if(w.first>=0x294&&w.first<=0x297) {static const unsigned d[]={1,8,64,1024};timer=true;timer_start=clock;loaded=w.second;divisor=d[w.first-0x294];}
         }
      }
      if(frame<deadline) fail("instruction deadline");
      if(mode==1) {if(!forward||!backward||!returned) fail("reversible world traversal coverage");}
      else if(mode==2) {if(aim_mask!=255) fail("aim coverage");}
      else if(mode==3) {if(!treasure_other||!treasure_returned) fail("treasure departure/return coverage");}
      else if(mode==4) {if(monsters.size()!=8) fail("eight distinct monster designs");}
      else if(!jump||!duck||!killed||!damaged||!restarted||!reset||!m0||!m1||jump_tone<0||catch_tone<0||jump_tone==catch_tone) fail("gameplay/audio coverage");
   }
};
Machine*Machine::active=nullptr;
}
int main(int argc,char**argv) {
   if(argc!=3&&argc!=4) return 2;
   unsigned first=argc==4?static_cast<unsigned>(std::strtoul(argv[3],nullptr,10)):0;
   if(first>=5) return 2;
   unsigned last=argc==4?first+1:5;
   for(unsigned i=first;i<last;++i) {Machine m(argv[1],argv[2],i);m.run();}
   std::puts("cinder_run CPU ok");
}
