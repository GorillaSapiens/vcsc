// Behavioral CPU oracle; TIA geometry is independently checked by pixel tests.
#include <algorithm>
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
   unsigned reuse_moves=0;
   std::array<uint8_t,18> initial{};
   std::map<uint32_t,std::array<uint8_t,18>> visited;
   std::map<std::array<uint8_t,8>,bool> monsters;
   bool treasure_returned=false,treasure_other=false;
   int jump_tone=-1,catch_tone=-1;
   unsigned waiting_target=4,waiting_start=0,waiting_wave=0,waiting_delay=0;
   unsigned spawn_sides=0,cooldown_completed=0;
   unsigned terrain_jumps=0;
   unsigned life_rewards=0;
   bool terrain_grounded=true;
   uint8_t spawn_seed=0;
   bool spawn_left=false;
   std::map<unsigned,bool> cooldowns;
   static uint8_t rd(uint16_t a) { return active->read(a); }
   static void wr(uint16_t a,uint8_t v) { active->write(a,v); }
   static void tick(mos6502*) {}
   unsigned addr(const char*s) { auto i=symbols.find(s); if(i==symbols.end()) fail(s); return i->second; }
   uint8_t val(const char*s) { return mem[addr(s)]; }
   void put(const char*s,uint8_t v) { mem[addr(s)]=v; }
   uint8_t keys() const {
       if(mode==8) return 0xff;
       if(mode==7) {
          if(frame<32) return 0xff;
          unsigned phase=(frame-32)%52,round=(frame-32)/52;uint8_t input=0xff;
          if(phase<8) input&=0xef;
          if(round%3&&phase<40) input&=round%3==1?0xbf:0x7f;
          return input;
       }
       if(mode==6) return frame<140?0x7f:0xbf;
       if(mode==5) return 0xff;
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
       if(mode==7&&frame>=32&&(frame-32)%52>=44&&(frame-32)%52<48) return 0;
       if(frame==5 || (mode==0&&((frame>=100&&frame<=110)||frame==480)) || (mode==2&&frame==104)) return 0;
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
       if(a==0x37) return (mode==0&&((frame>=150&&frame<=155)||frame==250||frame==350||frame==450))||(mode==8&&frame==146) ? 0x80 : 0;
       if(a==0x30) return (mode==0&&frame==104)||(mode==5&&frame>=20&&frame<=500&&(frame-20)%160==0) ? 0x80 : 0;
       if(a==0x31) return (mode==0&&frame==95)||(mode==3&&(frame==20||frame==100||frame==600))||(mode==8&&((frame>=20&&frame<=140&&frame%10==0)||frame==146)) ? 0x80 : 0;
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
      // Independent score: alternating 7/8 and 5/8, two 6/8 bridge bars,
      // then a higher-register return. 48 eighths still loop in 1,200 frames.
      static const uint8_t score[]={
         0x91,11,14,0x8f,14,0x93,17, 0x8c,14,17,0x8b,0,
         0x8e,11,8,0x8c,15,0x93,17, 0x8b,12,14,0x8f,17,
         0xb3,0,0x2e,0xb1,0,0x2c, 0xae,0,0x28,0xaf,0x31,0,
         0x88,11,12,0x8e,15,0x93,17, 0x8e,15,0,0xb1,0x31
      };
      if(frame<7) {if(mem[0x1a]) fail("music played before starting");return;}
      unsigned index=((frame-7)/25)%48,age=(frame-7)%25;
      uint8_t note=score[index];
      unsigned volume=!note||(age>=22&&!(note&0x20))?0:age<4?((note&0x80)?4:3):2;
      if(mem[0x16]!=12||mem[0x18]!=(note&31)) fail("music voice/pitch sequence");
      if(mem[0x1a]!=volume) fail("music volume envelope");
      if(val("music_step")!=(index+1)%48||val("music_clock")!=24-age) fail("music tempo or loop length");
   }
   void snapshot() {
      if(frame==2) initial=terrain();
      if(mode==1) { check_world(); check_music(); return; }
      if(mode==7) {
         bool grounded=val("run_grounded")!=0;
         if(!grounded&&terrain_grounded) ++terrain_jumps;
         terrain_grounded=grounded;return;
      }
       if(mode==3) {
          if(frame>21) {
             if(val("run_lives")!=4) fail("revisited treasure awarded another life");
            if(!(mem[addr("treasure_taken")]&1)) fail("collected treasure flag was forgotten");
            if(!val("treasure_id")&&val("treasure_visible")) fail("collected treasure respawned");
            if(val("treasure_id")==1&&val("treasure_visible")) treasure_other=true;
            if(frame>550&&!val("treasure_id")&&!val("treasure_visible")) treasure_returned=true;
         }
          if((frame==102||frame==602)&&val("run_sound")==0x8b) fail("repeated treasure paid again");
          return;
       }
       if(mode==8) {
          if(frame==9) put("run_lives",1);
          if(frame>=19&&frame<=139&&(frame-19)%10==0) {
             put("world_sector",(frame-19)/10);put("world_camera",0);
          }
          if(frame>=22&&frame<=142&&(frame-22)%10==0) {
             ++life_rewards;unsigned expected=std::min(11u,life_rewards+1);
             if(val("run_lives")!=expected) fail("treasure life reward/cap at eleven");
             if(val("lives_score")!=expected) fail("lantern count differs from lives");
          }
          if(frame==145) {put("run_lives",1);put("run_immunity",0);put("world_sector",13);}
          if(frame==148&&(val("run_lives")!=1||val("run_mode")!=1||!(mem[addr("treasure_taken")+1]&32)))
             fail("simultaneous pickup/damage left inconsistent lives or game over");
          return;
       }
      if(mode==4) {
          if(frame==10) {put("game_object_x",80);put("enemy_x",82);put("enemy_direction",255);}
          if(frame==30&&val("enemy_x")>=78) fail("monster stopped or turned above player");
          if(frame>=40&&frame<=110&&(frame-40)%10==0) {put("enemy_kind",(frame-40)/10);put("enemy_art_cursor",0);}
          if(frame>=42&&frame<=112&&(frame-42)%10==0) {
             static const uint8_t colors[]={0x24,0x36,0x66,0x86,0xaa,0x0c,0x1a,0xca};
             if(val("game_monster_color")!=colors[(frame-42)/10]) fail("monster type did not select its tint");
            std::array<uint8_t,8> pixels{};
            for(unsigned i=0;i<8;++i) pixels[i]=mem[addr("monster_pixels")+i];
            monsters[pixels]=true;
         }
          if(frame==120) for(unsigned i=0;i<4;++i) {
             mem[addr("enemy_x")+i]=110;
             mem[addr("enemy_kind")+i]=i*2;
             mem[addr("enemy_direction")+i]=i&1?1:255;
          }
          if(frame==128) {
             static const uint8_t expected[]={106,112,102,112};
             for(unsigned i=0;i<4;++i) if(mem[addr("enemy_x")+i]!=expected[i]) fail("independent monster speed/direction");
          }
          if(frame==200&&val("run_wave")<=4) fail("monster did not leave screen and respawn");
          return;
      }
      if(mode==5) {
          if(frame>=19&&frame<=499&&(frame-19)%160==0) {
             unsigned target=(frame-19)/160;
             static const uint8_t seeds[]={0xa7,0x5b,0x86,0x35};
             auto random_next=[](uint8_t s) {return static_cast<uint8_t>((s>>1)^((s&1)?0xb8:0));};
             auto delay_seed=random_next(seeds[target]);
             waiting_target=target;waiting_start=frame+1;waiting_wave=val("run_wave");
             waiting_delay=48+(delay_seed&63);spawn_seed=random_next(delay_seed);spawn_left=delay_seed&1;
             cooldowns[waiting_delay]=true;
             for(unsigned i=0;i<4;++i) {
                mem[addr("enemy_x")+i]=110;
                mem[addr("enemy_kind")+i]=i*2;
                mem[addr("enemy_direction")+i]=255;
                mem[addr("enemy_delay")+i]=0;
             }
             put("enemy_random",seeds[target]);put("run_facing",target&1?255:1);
             put("run_shot_active",1);put("run_shot_y",21+target*16);
             put("run_shot_dx",0);put("run_shot_dy",0);
          }
          if(frame>=21&&frame<=501&&(frame-21)%160==0) {
             unsigned target=(frame-21)/160;
             static const uint8_t untouched_x[]={109,110,108,110};
             if(val("run_shot_active")||val("run_wave")!=waiting_wave) fail("targeted shot did not enter respawn delay");
             for(unsigned i=0;i<4;++i) {
                if((mem[addr("enemy_delay")+i]!=0)!=(i==target)) fail("shot reset wrong enemy slot");
                if(i!=target&&mem[addr("enemy_x")+i]!=untouched_x[i]) fail("shot disturbed another enemy's position");
             }
          }
          if(waiting_target<4&&frame>static_cast<int>(waiting_start)) {
             unsigned target=waiting_target;
             auto delay=mem[addr("enemy_delay")+target];
             unsigned elapsed=frame-waiting_start-(target>=2?1:0);
             if(elapsed<waiting_delay) {
                if(delay!=waiting_delay-elapsed) {
                   std::fprintf(stderr,"target%u frame%d delay%u expected%u rng%u\n",target,frame,delay,waiting_delay-elapsed,val("enemy_random"));
                   fail("random respawn delay countdown");
                }
                for(unsigned i=0;i<8;++i) if(mem[addr("monster_pixels")+target*8+i]) fail("defeated monster reappeared during delay");
             }
             else {
                if(delay||elapsed!=waiting_delay) fail("respawn did not happen at delay expiry");
                unsigned x=spawn_left?4:152,direction=spawn_left?1:255;
                if(mem[addr("enemy_x")+target]!=x||mem[addr("enemy_direction")+target]!=direction)
                   fail("random spawn side depends on facing or wrong RNG");
                if(val("run_wave")!=static_cast<uint8_t>(waiting_wave+1)||val("enemy_random")!=spawn_seed)
                   fail("replacement spawned more than once or consumed wrong RNG");
                spawn_sides|=spawn_left?1:2;cooldown_completed++;waiting_target=4;
             }
          }
          return;
      }
      if(mode==6) {
         int delta=static_cast<int8_t>(val("world_camera")-camera);
         if(delta>0) forward=true;
         if(delta<0) backward=true;
         camera=val("world_camera");
         if(frame==10) {
            for(unsigned i=0;i<4;++i) {
               mem[addr("enemy_delay")+i]=200;mem[addr("enemy_x")+i]=2;
            }
            for(unsigned i=0;i<32;++i) mem[addr("monster_pixels")+i]=0;
         }
         if(frame==140) for(unsigned i=0;i<4;++i) mem[addr("enemy_x")+i]=151;
         if(frame>10) {
            if(val("run_wave")!=4||val("enemy_random")!=0xa7) fail("camera respawned waiting enemy");
            for(unsigned i=0;i<4;++i) if(mem[addr("enemy_delay")+i]!=210-frame) fail("camera altered respawn countdown");
            for(unsigned i=0;i<32;++i) if(mem[addr("monster_pixels")+i]) fail("camera revealed waiting enemy");
         }
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
       if(frame==98&&(mem[0x15]!=12||mem[0x17]!=11||mem[0x19]!=4)) fail("treasure did not use its own chime voice");
       if(frame==103&&(mem[0x15]!=12||mem[0x17]!=8)) fail("treasure chime did not rise to its second note");
       if(frame==104&&(mem[0x15]!=4||mem[0x17]!=3)) fail("gunfire lost its distinct square pulse");
      if((frame==15||frame==98)&&mem[0x1a]!=1) fail("music did not duck under sound effects");
      if(frame==103&&!val("run_shot_active")) fail("Fire did not shoot");
      if(frame==105) { if(val("run_shot_active")) fail("M0 kill did not remove shot"); killed=true; }
      if(frame==110&&val("run_shot_active")) fail("held Fire spawned another shot");
       if(frame==98&&val("run_lives")!=4) fail("treasure did not add a life");
       if(frame==152&&val("run_lives")==3&&val("run_immunity")) damaged=true;
       if(frame==158&&val("run_lives")!=3) fail("immunity did not suppress repeated damage");
       if(frame==452&&(val("run_mode")!=2||val("run_lives"))) fail("game over");
       if(frame==452&&(mem[0x09]!=0||mem[0x08]!=4)) fail("game-over BK/PF palette");
       if((frame==452||frame==512)&&mem[0x1a]) fail("music did not stop on game over/Reset");
       if(frame==482&&(mem[0x18]!=17||mem[0x1a]!=4)) fail("music did not restart from its first note");
       if(frame==482&&val("run_mode")==1&&val("run_lives")==3) restarted=true;
       if(frame==482&&(mem[0x09]!=0x82||mem[0x08]!=0x26)) fail("restart did not restore BK/PF palette");
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
       int deadline=mode==1?7200:mode==2?124:mode==3?720:mode==4?210:mode==5||mode==7?650:mode==6?200:mode==8?150:530;
       for(unsigned long i=0;i<90000000&&frame<deadline;++i) {
          // The lightweight CPU omits bus dummy reads. Reject indexed ROM
          // reads whose speculative address would hit Superchip's write port;
          // real TIA captures otherwise see persistent RAM silently corrupted.
          auto pc=cpu.GetPC();auto op=read(pc);unsigned index=0;
          bool indexed=false;
          switch(op) {
             case 0xbd:case 0x1d:case 0x3d:case 0x5d:case 0x7d:case 0xdd:case 0xfd:case 0xbc:
                indexed=true;index=cpu.GetX();break;
             case 0xb9:case 0x19:case 0x39:case 0x59:case 0x79:case 0xd9:case 0xf9:case 0xbe:
                indexed=true;index=cpu.GetY();break;
             default:break;
          }
          if(indexed) {
             unsigned base=read(pc+1)|(read(pc+2)<<8),sum=base+index;
             unsigned dummy=((base&0xff00)|(sum&255))&0x1fff;
             if((base&0xff00)!=(sum&0xff00)&&dummy>=0x1000&&dummy<0x1080)
                fail("indexed dummy read hits Superchip write port");
          }
          writes.clear();auto before=cycles;cpu.Run(1,cycles,mos6502::INST_COUNT);clock+=cycles-before;
           for(auto w:writes) {
             if(w.first==0x2a&&!(mem[1]&2)&&clock%76==8) {
               if(val("game_aux_index")!=3||mem[0x20]||mem[0x21]||mem[0x22]) fail("dot HMOVE disturbed another object");
               if((mem[0x23]&0xf0)!=(dot_moves?0xf0:0x10)) fail("dot HMOVE is not minus/plus one pixel");
                ++dot_moves;
             }
             if(w.first==0x2a&&!(mem[1]&2)&&clock%76==74) {
                if(mem[0x20]!=0x80||mem[0x22]!=0x80||mem[0x23]!=0x80||mem[0x24]!=0x80)
                   fail("monster reuse moved another hardware object");
                if(val("game_band")!=reuse_moves+1) fail("monster reuse band order");
                ++reuse_moves;
             }
            if(w.first==0x1d&&(w.second&2)) m0=true;
            if(w.first==0x1e&&(w.second&2)) m1=true;
            if(w.first==0x1f&&(w.second&2)) fail("Ball was enabled");
            if((w.first==0x1d||w.first==0x1e)&&(w.second&2)&&!(mem[1]&2)&&clock%76>22) fail("late missile enable");
            if(w.first==2) clock+=76-clock%76;
            if(w.first==0) {bool n=w.second&2;if(n&&!sync) {++frame;
                if(dot_moves&&dot_moves!=2) fail("unpaired dot HMOVE");
                dot_moves=0;
                if(frame>1&&reuse_moves!=3) fail("not all four monster bands rendered");
                reuse_moves=0;
                if(frame>4&&clock-last_start!=264*76) { std::fprintf(stderr,"mode %u frame %d: %llu cycles\n",mode,frame,static_cast<unsigned long long>(clock-last_start));fail("unstable frame period"); }
               last_start=clock;snapshot();}sync=n;}
            if(w.first>=0x294&&w.first<=0x297) {static const unsigned d[]={1,8,64,1024};timer=true;timer_start=clock;loaded=w.second;divisor=d[w.first-0x294];}
         }
      }
      if(frame<deadline) fail("instruction deadline");
      if(mode==1) {if(!forward||!backward||!returned) fail("reversible world traversal coverage");}
      else if(mode==2) {if(aim_mask!=255) fail("aim coverage");}
      else if(mode==3) {if(!treasure_other||!treasure_returned) fail("treasure departure/return coverage");}
       else if(mode==4) {if(monsters.size()!=8) fail("eight distinct monster designs");}
       else if(mode==5) {if(cooldown_completed!=4||spawn_sides!=3||cooldowns.size()<3) fail("random delay/side coverage");}
       else if(mode==6) {if(!forward||!backward) fail("waiting enemy camera traversal coverage");}
        else if(mode==7) {if(terrain_jumps<8) fail("repeated terrain-jump coverage");}
        else if(mode==8) {if(life_rewards!=13) fail("life reward/cap coverage");}
       else if(mode==0&&(!jump||!duck||!killed||!damaged||!restarted||!reset||!m0||!m1||jump_tone<0||catch_tone<0||jump_tone==catch_tone)) fail("gameplay/audio coverage");
   }
};
Machine*Machine::active=nullptr;
}
int main(int argc,char**argv) {
   if(argc!=3&&argc!=4) return 2;
   unsigned first=argc==4?static_cast<unsigned>(std::strtoul(argv[3],nullptr,10)):0;
   if(first>=9) return 2;
   unsigned last=argc==4?first+1:9;
   for(unsigned i=first;i<last;++i) {Machine m(argv[1],argv[2],i);m.run();}
   std::puts("cinder_run CPU ok");
}
