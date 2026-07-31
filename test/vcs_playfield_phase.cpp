//! @file vcs_playfield_phase.cpp
//! @brief Verify the normalized two-line renderer's cycle-stable PF writes.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <vector>

#include "mos6502.h"

namespace {
constexpr uint16_t kRomBase = 0xF000;
constexpr size_t kRomSize = 4096;
constexpr uint64_t kCyclesPerScanline = 76;
constexpr uint16_t kVsync = 0x0000;
constexpr uint16_t kWsync = 0x0002;
constexpr uint16_t kPf1 = 0x000E;
constexpr uint16_t kPf2 = 0x000F;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct WriteEvent { uint16_t address; uint8_t value; };
struct PfEvent { uint64_t line; uint64_t cycle; uint16_t address; uint8_t value; };

uint8_t memory_image[65536];
uint64_t virtual_cycles = 0;
uint64_t cpu_cycles = 0;
std::vector<WriteEvent> writes;
std::vector<PfEvent> pf_events;
bool vsync_asserted = false;
int frame = -1;
uint64_t frame_start = 0;
bool timer_active = false;
uint64_t timer_start = 0;
uint16_t timer_divisor = 1;
uint8_t timer_loaded = 0;

[[noreturn]] void fail(const char *message) {
   std::fprintf(stderr, "vcs_playfield_phase: %s\n", message);
   std::exit(1);
}

uint8_t timer_value() {
   if (!timer_active) return memory_image[kIntim];
   const uint64_t ticks = (virtual_cycles - timer_start) / timer_divisor;
   if (ticks <= timer_loaded) return static_cast<uint8_t>(timer_loaded - ticks);
   return static_cast<uint8_t>(255 - ((ticks - timer_loaded - 1) & 255));
}

uint8_t read_bus(uint16_t address) {
   return address == kIntim ? timer_value() : memory_image[address];
}

void write_bus(uint16_t address, uint8_t value) {
   if (address < kRomBase) memory_image[address] = value;
   writes.push_back({address, value});
}

void clock_cycle(mos6502 *) {}

void apply_writes() {
   for (const WriteEvent &event : writes) {
      if (event.address == kWsync) {
         const uint64_t within = virtual_cycles % kCyclesPerScanline;
         virtual_cycles += within ? kCyclesPerScanline - within : kCyclesPerScanline;
      }
      else if (event.address == kVsync) {
         const bool next = (event.value & 2) != 0;
         if (next && !vsync_asserted) {
            ++frame;
            frame_start = virtual_cycles;
         }
         vsync_asserted = next;
      }
      else if (event.address >= kTim1t && event.address <= kT1024t) {
         timer_active = true;
         timer_start = virtual_cycles;
         timer_loaded = event.value;
         timer_divisor = event.address == kTim1t ? 1 :
                         event.address == kTim8t ? 8 :
                         event.address == kTim64t ? 64 : 1024;
      }
      else if (frame == 2 && (event.address == kPf1 || event.address == kPf2)) {
         const uint64_t relative = virtual_cycles - frame_start;
         pf_events.push_back({relative / kCyclesPerScanline,
                              relative % kCyclesPerScanline,
                              event.address, event.value});
      }
   }
   writes.clear();
}
} // namespace

int main(int argc, char **argv) {
   if (argc < 2 || argc > 6) {
      std::fprintf(stderr,
         "usage: %s ROM.bin [checked_rows [source_rows [first_row_line [profile]]]]\n",
         argv[0]);
      return 2;
   }
   const int raster_rows = argc >= 3 ? std::atoi(argv[2]) : 0;
   const int source_rows = argc >= 4 ? std::atoi(argv[3]) : raster_rows;
   const uint64_t first_row_line = argc >= 5 ?
      static_cast<uint64_t>(std::strtoull(argv[4], nullptr, 0)) : 43;
   const bool all_five_profile = argc == 6 && std::strcmp(argv[5], "all-five") == 0;
   const bool all_five_192_profile = argc == 6 && std::strcmp(argv[5], "all-five-192") == 0;
   if (argc == 6 && !all_five_profile && !all_five_192_profile)
      fail("unknown timing profile");
   if (raster_rows != 0 && raster_rows != 11 && raster_rows != 12)
      fail("checked raster row count must be 11 or 12");
   if (source_rows != raster_rows && !(raster_rows == 11 && source_rows == 12))
      fail("source row count must equal checked rows or be 12 when checking 11");
   std::memset(memory_image, 0, sizeof(memory_image));
   std::ifstream rom(argv[1], std::ios::binary);
   if (!rom) fail("could not open ROM");
   rom.read(reinterpret_cast<char *>(memory_image + kRomBase), kRomSize);
   if (rom.gcount() != static_cast<std::streamsize>(kRomSize)) {
      fail("ROM is not exactly 4096 bytes");
   }

   mos6502 cpu(read_bus, write_bus, clock_cycle);
   cpu.Reset();
   constexpr uint64_t kInstructionLimit = 100000000;
   for (uint64_t instructions = 0;
        instructions < kInstructionLimit && frame < 3;
        ++instructions) {
      writes.clear();
      const uint64_t before = cpu_cycles;
      cpu.Run(1, cpu_cycles, mos6502::INST_COUNT);
      virtual_cycles += cpu_cycles - before;
      apply_writes();
   }
   if (frame < 3) fail("instruction limit reached before three frames");

   std::map<uint64_t, std::vector<PfEvent>> by_line;
   for (const PfEvent &event : pf_events) by_line[event.line].push_back(event);
   size_t checked = 0;
   if (!raster_rows) {
      const uint16_t expected_addresses[] = {kPf1, kPf2, kPf1, kPf2};
      for (uint64_t line = 38; line <= 213; ++line) {
         const auto found = by_line.find(line);
         if (found == by_line.end() || found->second.size() != 4) continue;
         const uint64_t first_cycle = found->second[0].cycle;
         const bool staged_left = first_cycle == 21 && found->second[1].cycle == 28;
         const bool early_left = first_cycle == 22 && found->second[1].cycle == 29;
         const bool steady_left = first_cycle == 24 && found->second[1].cycle == 31;
         if (!staged_left && !early_left && !steady_left) {
            std::fprintf(stderr,
               "vcs_playfield_phase: line %llu left writes are cycles %llu/%llu; "
               "expected 21/28, 22/29, or 24/31\n",
               static_cast<unsigned long long>(line),
               static_cast<unsigned long long>(found->second[0].cycle),
               static_cast<unsigned long long>(found->second[1].cycle));
            return 1;
         }
         const uint64_t expected_cycles[] = {
            first_cycle, found->second[1].cycle, 38, 45
         };
         for (size_t i = 0; i < 4; ++i) {
            if (found->second[i].cycle != expected_cycles[i] ||
                found->second[i].address != expected_addresses[i]) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: line %llu write %zu is reg $%02x cycle %llu; "
                  "expected reg $%02x cycle %llu\n",
                  static_cast<unsigned long long>(line), i,
                  found->second[i].address,
                  static_cast<unsigned long long>(found->second[i].cycle),
                  expected_addresses[i],
                  static_cast<unsigned long long>(expected_cycles[i]));
               return 1;
            }
         }
         ++checked;
      }
      if (checked < 150) fail("too few complete visible playfield scanlines checked");
   }

   if (raster_rows && all_five_192_profile) {
      size_t steady_lines = 0;
      for (int row = 0; row < raster_rows; ++row) {
         for (int subline = 0; subline < 16; ++subline) {
            const uint64_t line = first_row_line + row * 16 + subline;
            const auto found = by_line.find(line);
            if (found == by_line.end() || found->second.size() != 4) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: all-five-192 row %d line %d has %zu PF writes; expected 4\n",
                  row, subline,
                  found == by_line.end() ? size_t{0} : found->second.size());
               return 1;
            }

            if (subline == 15 && row + 1 < raster_rows) {
               const uint16_t addresses[] = {kPf1, kPf2, kPf1, kPf2};
               const uint64_t cycles[] = {14, 21, 37, 40};
               for (size_t i = 0; i < 4; ++i) {
                  if (found->second[i].address != addresses[i] ||
                      found->second[i].cycle != cycles[i]) {
                     std::fprintf(stderr,
                        "vcs_playfield_phase: all-five-192 boundary row %d write %zu is "
                        "reg $%02x cycle %llu; expected reg $%02x cycle %llu\n",
                        row, i, found->second[i].address,
                        static_cast<unsigned long long>(found->second[i].cycle),
                        addresses[i], static_cast<unsigned long long>(cycles[i]));
                     return 1;
                  }
               }
               continue;
            }

            const uint16_t addresses[] = {kPf1, kPf2, kPf2, kPf1};
            for (size_t i = 0; i < 4; ++i) {
               if (found->second[i].address != addresses[i]) {
                  std::fprintf(stderr,
                     "vcs_playfield_phase: all-five-192 row %d line %d write %zu is "
                     "reg $%02x; expected reg $%02x\n",
                     row, subline, i, found->second[i].address, addresses[i]);
                  return 1;
               }
            }
            if (found->second[2].cycle != 40 || found->second[3].cycle != 47) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: all-five-192 row %d line %d reflected writes "
                  "are cycles %llu/%llu; expected 40/47\n",
                  row, subline,
                  static_cast<unsigned long long>(found->second[2].cycle),
                  static_cast<unsigned long long>(found->second[3].cycle));
               return 1;
            }
            if (found->second[0].cycle > 18 || found->second[1].cycle > 25) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: all-five-192 row %d line %d left writes "
                  "are too late at cycles %llu/%llu\n",
                  row, subline,
                  static_cast<unsigned long long>(found->second[0].cycle),
                  static_cast<unsigned long long>(found->second[1].cycle));
               return 1;
            }

            const bool steady = (row == 0 && subline >= 1 && subline <= 14) ||
                                (row > 0 && subline >= 3 && subline <= 14);
            if (steady) {
               const bool p0_phase = found->second[0].cycle == 17 &&
                                     found->second[1].cycle == 24;
               const bool p1_phase = found->second[0].cycle == 18 &&
                                     found->second[1].cycle == 25;
               if (!p0_phase && !p1_phase) {
                  std::fprintf(stderr,
                     "vcs_playfield_phase: all-five-192 steady row %d line %d left "
                     "writes are cycles %llu/%llu; expected 17/24 or 18/25\n",
                     row, subline,
                     static_cast<unsigned long long>(found->second[0].cycle),
                     static_cast<unsigned long long>(found->second[1].cycle));
                  return 1;
               }
               ++steady_lines;
            }
         }
      }
      if (steady_lines < 100)
         fail("too few all-five-192 steady scanlines checked");
   }

   if (raster_rows && all_five_profile) {
      const uint16_t expected_addresses[] = {kPf1, kPf2, kPf2, kPf1};
      const uint64_t maximum_cycles[] = {19, 26, 45, 52};
      size_t steady_lines = 0;
      for (int row = 0; row < raster_rows; ++row) {
         for (int subline = 0; subline < 16; ++subline) {
            const uint64_t line = first_row_line + row * 16 + subline;
            const auto found = by_line.find(line);
            if (found == by_line.end() || found->second.size() != 4) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: all-five row %d line %d has %zu PF writes; expected 4\n",
                  row, subline,
                  found == by_line.end() ? size_t{0} : found->second.size());
               return 1;
            }
            for (size_t i = 0; i < 4; ++i) {
               const PfEvent &event = found->second[i];
               if (event.address != expected_addresses[i] ||
                   event.cycle > maximum_cycles[i]) {
                  std::fprintf(stderr,
                     "vcs_playfield_phase: all-five row %d line %d write %zu is "
                     "reg $%02x cycle %llu; expected reg $%02x no later than cycle %llu\n",
                     row, subline, i, event.address,
                     static_cast<unsigned long long>(event.cycle),
                     expected_addresses[i],
                     static_cast<unsigned long long>(maximum_cycles[i]));
                  return 1;
               }
            }

            // The row-transition prologue deliberately uses several balanced
            // schedules.  Away from that prologue, both P1 and P0 scanlines
            // must use one identical reflected-half phase.  The old all-five
            // loop alternated 47/54 on P1 lines with 45/52 on P0 lines, which
            // shredded the playfield even though the byte-level raster model
            // still happened to pass.
            const bool steady = (row == 0 && subline >= 1 && subline <= 14) ||
                                (row > 0 && subline >= 3 && subline <= 14);
            if (steady) {
               const uint64_t expected_cycles[] = {17, 24, 45, 52};
               for (size_t i = 0; i < 4; ++i) {
                  if (found->second[i].cycle != expected_cycles[i]) {
                     std::fprintf(stderr,
                        "vcs_playfield_phase: all-five steady row %d line %d "
                        "write %zu is cycle %llu; expected %llu\n",
                        row, subline, i,
                        static_cast<unsigned long long>(found->second[i].cycle),
                        static_cast<unsigned long long>(expected_cycles[i]));
                     return 1;
                  }
               }
               ++steady_lines;
            }
         }
      }
      if (steady_lines < 100) fail("too few all-five steady scanlines checked");
   }

   if (raster_rows) {
      auto expected_byte = [&](int row, int byte) -> uint8_t {
         if (row == 0 || row == source_rows - 1) return 0xff;
         if (byte == 0 || byte == 3) return 0x81;
         return (row & 1) ? 0x18 : 0x00;
      };
      auto register_at = [&](uint64_t line, uint64_t cycle, uint16_t address) {
         uint8_t value = 0;
         for (const PfEvent &event : pf_events) {
            if (event.address != address) continue;
            if (event.line < line || (event.line == line && event.cycle <= cycle))
               value = event.value;
         }
         return value;
      };
      auto bit = [](uint8_t value, unsigned index) {
         return ((value >> index) & 1u) != 0;
      };
      if (raster_rows == 11) {
         // The score-composable renderer spends one visible line staging its
         // object pipeline before the eleven complete playfield rows begin.
         // That line must remain background-only; priming just PF1/PF2 there
         // exposed a malformed partial copy of row zero in Stella.
         const uint64_t setup_line = first_row_line - 1;
         for (unsigned pixel = 16; pixel < 144; ++pixel) {
            const uint64_t cycle = (68 + pixel) / 3;
            const uint8_t pf1 = register_at(setup_line, cycle, kPf1);
            const uint8_t pf2 = register_at(setup_line, cycle, kPf2);
            bool active = false;
            if (pixel < 48) {
               const unsigned n = (pixel - 16) / 4;
               active = bit(pf1, 7 - n);
            } else if (pixel < 80) {
               const unsigned n = (pixel - 48) / 4;
               active = bit(pf2, n);
            } else if (pixel < 112) {
               const unsigned n = (pixel - 80) / 4;
               active = bit(pf2, 7 - n);
            } else {
               const unsigned n = (pixel - 112) / 4;
               active = bit(pf1, n);
            }
            if (active) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: 181-line setup scanline pixel %u is active; expected background\n",
                  pixel);
               return 1;
            }
         }
      }
      for (int row = 0; row < raster_rows; ++row) {
         for (int subline = 0; subline < 16; ++subline) {
            const uint64_t line = first_row_line + row * 16 + subline;
            for (unsigned pixel = 0; pixel < 160; ++pixel) {
               const uint64_t cycle = (68 + pixel) / 3;
               const uint8_t pf1 = register_at(line, cycle, kPf1);
               const uint8_t pf2 = register_at(line, cycle, kPf2);
               bool actual = false, want = false;
               if (pixel >= 16 && pixel < 48) {
                  const unsigned n=(pixel-16)/4;
                  actual=bit(pf1,7-n); want=bit(expected_byte(row,0),7-n);
               } else if (pixel >= 48 && pixel < 80) {
                  const unsigned n=(pixel-48)/4;
                  actual=bit(pf2,n); want=bit(expected_byte(row,1),n);
               } else if (pixel >= 80 && pixel < 112) {
                  const unsigned n=(pixel-80)/4;
                  actual=bit(pf2,7-n); want=bit(expected_byte(row,2),7-n);
               } else if (pixel >= 112 && pixel < 144) {
                  const unsigned n=(pixel-112)/4;
                  actual=bit(pf1,n); want=bit(expected_byte(row,3),n);
               }
               if (actual != want) {
                  std::fprintf(stderr,
                     "vcs_playfield_phase: row %d line %d pixel %u is %d, expected %d\n",
                     row, subline, pixel, actual ? 1 : 0, want ? 1 : 0);
                  return 1;
               }
            }
         }
      }
      std::printf("vcs_playfield_raster ok: %d rows x 16 lines x 160 pixels\n",
                  raster_rows);
   } else {
      std::printf("vcs_playfield_phase ok: %zu scanlines at cycles 21/28, 22/29, or 24/31,38,45\n", checked);
   }
   return 0;
}
