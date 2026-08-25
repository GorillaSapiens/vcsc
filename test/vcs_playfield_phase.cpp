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
constexpr uint16_t kSwcha = 0x0280;
constexpr uint16_t kSwchb = 0x0282;
constexpr uint16_t kIntim = 0x0284;
constexpr uint16_t kTim1t = 0x0294;
constexpr uint16_t kTim8t = 0x0295;
constexpr uint16_t kTim64t = 0x0296;
constexpr uint16_t kT1024t = 0x0297;

struct WriteEvent { uint16_t address; uint8_t value; };
struct PfEvent { uint64_t line; uint64_t cycle; uint16_t address; uint8_t value; };

constexpr uint8_t kDiagonalPlayfield[11][4] = {
   {0x82, 0x10, 0x20, 0x41},
   {0x41, 0x20, 0x10, 0x82},
   {0x20, 0x41, 0x08, 0x04},
   {0x10, 0x82, 0x04, 0x08},
   {0x08, 0x04, 0x82, 0x10},
   {0x04, 0x08, 0x41, 0x20},
   {0x02, 0x10, 0x20, 0x41},
   {0x01, 0x20, 0x10, 0x82},
   {0x80, 0x41, 0x08, 0x04},
   {0x40, 0x82, 0x04, 0x08},
   {0x20, 0x04, 0x82, 0x10},
};

// The public player_color_192 interactive example's deliberately asymmetric
// playfield.  Unlike the old symmetric smoke fixture, every row transition can
// expose a left/right or old/new-byte timing mistake as a visible pixel error.
constexpr uint8_t kDiagonalPlayfield192[12][4] = {
   {0x80, 0x08, 0x01, 0x00},
   {0x40, 0x10, 0x00, 0x01},
   {0x20, 0x20, 0x00, 0x02},
   {0x10, 0x40, 0x00, 0x04},
   {0x08, 0x80, 0x00, 0x08},
   {0x04, 0x00, 0x80, 0x10},
   {0x02, 0x00, 0x40, 0x20},
   {0x01, 0x00, 0x20, 0x40},
   {0x00, 0x01, 0x10, 0x80},
   {0x00, 0x02, 0x08, 0x40},
   {0x00, 0x04, 0x04, 0x20},
   {0x00, 0x08, 0x02, 0x10},
};

constexpr uint8_t kGalleryPlayfield192[12][4] = {
   {0xff, 0xff, 0xff, 0xff},
   {0x55, 0xaa, 0x55, 0xaa},
   {0x00, 0x00, 0x00, 0x00},
   {0x00, 0x00, 0x00, 0x00},
   {0x00, 0x00, 0x00, 0x00},
   {0x00, 0x00, 0x00, 0x00},
   {0x00, 0x00, 0x00, 0x00},
   {0x00, 0x00, 0x00, 0x00},
   {0x00, 0x00, 0x00, 0x00},
   {0x00, 0x00, 0x00, 0x00},
   {0xaa, 0x55, 0xaa, 0x55},
   {0xff, 0xff, 0xff, 0xff},
};

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
         pf_events.push_back({virtual_cycles / kCyclesPerScanline -
                                 frame_start / kCyclesPerScanline,
                              virtual_cycles % kCyclesPerScanline,
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
   const bool all_five_phase_228_profile = argc == 6 &&
      std::strcmp(argv[5], "all-five-phase-228") == 0;
   const bool all_five_181_official_profile = argc == 6 &&
      std::strcmp(argv[5], "all-five-181-official") == 0;
   const bool player_diagonal_profile = argc == 6 &&
      std::strcmp(argv[5], "diagonal") == 0;
   const bool player_diagonal_192_profile = argc == 6 &&
      std::strcmp(argv[5], "diagonal-192") == 0;
   const bool player_gallery_192_profile = argc == 6 &&
      std::strcmp(argv[5], "gallery-192") == 0;
   const bool all_five_diagonal_profile = argc == 6 &&
      std::strcmp(argv[5], "all-five-diagonal") == 0;
   const bool diagonal_values_profile = player_diagonal_profile ||
                                        player_diagonal_192_profile ||
                                        player_gallery_192_profile ||
                                        all_five_diagonal_profile;
   const bool all_five_fixed_profile = all_five_192_profile ||
                                       all_five_phase_228_profile ||
                                       all_five_181_official_profile ||
                                       all_five_diagonal_profile;
   if (argc == 6 && !all_five_profile && !all_five_fixed_profile &&
       !player_diagonal_profile && !player_diagonal_192_profile &&
       !player_gallery_192_profile)
      fail("unknown timing profile");
   if (raster_rows != 0 && raster_rows != 10 && raster_rows != 11 &&
       raster_rows != 12 && raster_rows != 15)
      fail("checked raster row count must be 10, 11, 12, or 15");
   if (source_rows != raster_rows && !(raster_rows == 11 && source_rows == 12))
      fail("source row count must equal checked rows or be 12 when checking 11");
   std::memset(memory_image, 0, sizeof(memory_image));
   // No joystick direction or console switch is pressed by default.  Leaving
   // these RIOT input registers at zero holds Reset and makes visible timing
   // depend on startup/BSS clearing cost instead of the frame scheduler.
   memory_image[kSwcha] = 0xff;
   memory_image[kSwchb] = 0xff;
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
         const bool staged_left = first_cycle == 24 && found->second[1].cycle == 31;
         const bool early_left = first_cycle == 25 && found->second[1].cycle == 32;
         const bool steady_left = first_cycle == 27 && found->second[1].cycle == 34;
         if (!staged_left && !early_left && !steady_left) {
            std::fprintf(stderr,
               "vcs_playfield_phase: line %llu left writes are cycles %llu/%llu; "
               "expected 24/31, 25/32, or 27/34\n",
               static_cast<unsigned long long>(line),
               static_cast<unsigned long long>(found->second[0].cycle),
               static_cast<unsigned long long>(found->second[1].cycle));
            return 1;
         }
         const uint64_t expected_cycles[] = {
            first_cycle, found->second[1].cycle, 41, 48
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

   if (raster_rows && all_five_fixed_profile) {
      size_t steady_lines = 0;
      for (int row = 0; row < raster_rows; ++row) {
         const int row_lines = all_five_phase_228_profile && row == 0 ? 4 : 16;
         const uint64_t row_base = all_five_phase_228_profile
            ? first_row_line + (row == 0 ? 0 : 4 + (row - 1) * 16)
            : first_row_line + row * 16;
         for (int subline = 0; subline < row_lines; ++subline) {
            const uint64_t line = row_base + subline;
            const auto found = by_line.find(line);
            if (found == by_line.end() || found->second.size() != 4) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: all-five fixed row %d line %d has %zu PF writes; expected 4\n",
                  row, subline,
                  found == by_line.end() ? size_t{0} : found->second.size());
               return 1;
            }

            if (subline == row_lines - 1 && row + 1 < raster_rows) {
               const uint16_t addresses[] = {kPf1, kPf2, kPf1, kPf2};
               const uint64_t cycles[] = {22, 29, 45, 48};
               for (size_t i = 0; i < 4; ++i) {
                  if (found->second[i].address != addresses[i] ||
                      found->second[i].cycle != cycles[i]) {
                     std::fprintf(stderr,
                        "vcs_playfield_phase: all-five fixed boundary row %d write %zu is "
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
                     "vcs_playfield_phase: all-five fixed row %d line %d write %zu is "
                     "reg $%02x; expected reg $%02x\n",
                     row, subline, i, found->second[i].address, addresses[i]);
                  return 1;
               }
            }
            if (found->second[2].cycle != 48 || found->second[3].cycle != 55) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: all-five fixed row %d line %d reflected writes "
                  "are cycles %llu/%llu; expected 48/55\n",
                  row, subline,
                  static_cast<unsigned long long>(found->second[2].cycle),
                  static_cast<unsigned long long>(found->second[3].cycle));
               return 1;
            }
            if (found->second[0].cycle > 27 || found->second[1].cycle > 38) {
               std::fprintf(stderr,
                  "vcs_playfield_phase: all-five fixed row %d line %d left writes "
                  "are too late at cycles %llu/%llu\n",
                  row, subline,
                  static_cast<unsigned long long>(found->second[0].cycle),
                  static_cast<unsigned long long>(found->second[1].cycle));
               return 1;
            }

            const bool steady = (row == 0 && subline >= 1 && subline <= row_lines - 2) ||
                                (row > 0 && subline >= 3 && subline <= row_lines - 2);
            if (steady) {
               const bool p0_phase = found->second[0].cycle == 25 &&
                                     found->second[1].cycle == 32;
               const bool p1_phase = found->second[0].cycle == 26 &&
                                     found->second[1].cycle == 33;
               if (!p0_phase && !p1_phase) {
                  std::fprintf(stderr,
                     "vcs_playfield_phase: all-five fixed steady row %d line %d left "
                     "writes are cycles %llu/%llu; expected 25/32 or 26/33\n",
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
         fail("too few all-five fixed steady scanlines checked");
   }

   if (raster_rows && all_five_profile) {
      const uint16_t expected_addresses[] = {kPf1, kPf2, kPf2, kPf1};
      const uint64_t maximum_cycles[] = {27, 34, 53, 60};
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
               const uint64_t expected_cycles[] = {25, 32, 53, 60};
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

   if (all_five_phase_228_profile)
      std::printf("vcs_playfield_all_five_phase_228 ok: 228 lines (4 + 14x16) with proven PF phases\n");

   if (raster_rows && !all_five_phase_228_profile) {
      if (player_diagonal_192_profile || player_gallery_192_profile) {
         const uint8_t (*expected_playfield)[4] = player_diagonal_192_profile ?
            kDiagonalPlayfield192 : kGalleryPlayfield192;
         const char *profile_name = player_diagonal_192_profile ? "192 diagonal" : "192 gallery";
         const uint16_t addresses[] = {kPf1, kPf2, kPf2, kPf1};
         const uint64_t steady_cycles[] = {18, 25, 48, 55};
         const uint64_t transition_first_p1_cycles[] = {17, 24, 48, 55};
         const uint64_t terminal_cycles[] = {18, 25, 51, 58};
         for (int row = 0; row < raster_rows; ++row) {
            for (int subline = 0; subline < 16; ++subline) {
               const uint64_t line = first_row_line + row * 16 + subline;
               const auto found = by_line.find(line);
               if (found == by_line.end() || found->second.size() != 4) {
                  std::fprintf(stderr,
                     "vcs_playfield_phase: %s row %d line %d has %zu PF writes; expected 4\n",
                     profile_name, row, subline,
                     found == by_line.end() ? size_t{0} : found->second.size());
                  return 1;
               }
               for (size_t i = 0; i < 4; ++i) {
                  const PfEvent &event = found->second[i];
                  const uint64_t *expected_cycles =
                     row == raster_rows - 1 && subline == 15 ? terminal_cycles :
                     (row > 0 && subline == 1 ? transition_first_p1_cycles : steady_cycles);
                  if (event.address != addresses[i] ||
                      event.cycle != expected_cycles[i] ||
                      event.value != expected_playfield[row][i]) {
                     std::fprintf(stderr,
                        "vcs_playfield_phase: %s row %d line %d write %zu is "
                        "reg $%02x value $%02x cycle %llu; expected reg $%02x "
                        "value $%02x cycle %llu\n",
                        profile_name, row, subline, i, event.address, event.value,
                        static_cast<unsigned long long>(event.cycle), addresses[i],
                        expected_playfield[row][i],
                        static_cast<unsigned long long>(expected_cycles[i]));
                     return 1;
                  }
               }
            }
         }
      }
      if (player_diagonal_profile) {
         const uint16_t normal_addresses[] = {kPf1, kPf2, kPf2, kPf1};
         const uint16_t row_end_addresses[] = {kPf1, kPf2, kPf1, kPf2};
         const int normal_values[] = {0, 1, 2, 3};
         const int row_end_values[] = {0, 1, 3, 2};
         const uint64_t steady_cycles[] = {18, 25, 48, 55};
         const uint64_t transition_first_p1_cycles[] = {17, 24, 48, 55};
         // Keep the reflected writes in the proven safe window.  The earlier
         // 38/41 transition overwrote PF state while the TIA was still drawing
         // the left half and produced the same visible corruption in every
         // player-color 181 composition.
         const uint64_t row_end_cycles[] = {18, 25, 45, 48};
         const uint64_t terminal_cycles[] = {18, 25, 48, 55};
         for (int row = 0; row < raster_rows; ++row) {
            for (int subline = 0; subline < 16; ++subline) {
               const uint64_t line = first_row_line + row * 16 + subline;
               const auto found = by_line.find(line);
               if (found == by_line.end() || found->second.size() != 4) {
                  std::fprintf(stderr,
                     "vcs_playfield_phase: diagonal row %d line %d has %zu PF writes; expected 4\n",
                     row, subline,
                     found == by_line.end() ? size_t{0} : found->second.size());
                  return 1;
               }
               const bool row_end = subline == 15;
               const bool terminal = row_end && row == raster_rows - 1;
               const uint16_t *expected_addresses =
                  row_end && !terminal ? row_end_addresses : normal_addresses;
               const int *expected_values =
                  row_end && !terminal ? row_end_values : normal_values;
               const uint64_t *expected_cycles = terminal ? terminal_cycles :
                  (row_end ? row_end_cycles :
                   (row > 0 && subline == 1 ? transition_first_p1_cycles : steady_cycles));
               for (size_t i = 0; i < 4; ++i) {
                  const PfEvent &event = found->second[i];
                  const uint8_t expected_value = kDiagonalPlayfield[row][expected_values[i]];
                  if (event.address != expected_addresses[i] ||
                      event.cycle != expected_cycles[i] ||
                      event.value != expected_value) {
                     std::fprintf(stderr,
                        "vcs_playfield_phase: diagonal row %d line %d write %zu is "
                        "reg $%02x value $%02x cycle %llu; expected reg $%02x "
                        "value $%02x cycle %llu\n",
                        row, subline, i, event.address, event.value,
                        static_cast<unsigned long long>(event.cycle),
                        expected_addresses[i], expected_value,
                        static_cast<unsigned long long>(expected_cycles[i]));
                     return 1;
                  }
               }
            }
         }
      }
      auto expected_byte = [&](int row, int byte) -> uint8_t {
         if (player_diagonal_192_profile) return kDiagonalPlayfield192[row][byte];
         if (player_gallery_192_profile) return kGalleryPlayfield192[row][byte];
         if (diagonal_values_profile) return kDiagonalPlayfield[row][byte];
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
      if (!diagonal_values_profile && raster_rows == 11) {
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
      if (!diagonal_values_profile) for (int row = 0; row < raster_rows; ++row) {
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
      if (player_diagonal_192_profile)
         std::printf("vcs_playfield_diagonal_192 ok: %d asymmetric rows x 16 lines with proven PF phases\n",
                     raster_rows);
      else if (player_gallery_192_profile)
         std::printf("vcs_playfield_gallery_192 ok: %d gallery rows x 16 lines with proven PF phases\n",
                     raster_rows);
      else
         std::printf("vcs_playfield_raster ok: %d rows x 16 lines x 160 pixels\n",
                     raster_rows);
   } else if (!all_five_phase_228_profile) {
      std::printf("vcs_playfield_phase ok: %zu scanlines at cycles 24/31, 25/32, or 27/34,41,48\n", checked);
   }
   return 0;
}
