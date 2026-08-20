#include "concrete_discovery.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>

#include "../simulator/mos6502/mos6502.h"

namespace {
constexpr unsigned kMaxInstructions = 250000;
constexpr unsigned kConvergenceInstructions = 16384;
constexpr uint64_t kCyclesPerLine = 76;
constexpr int kMap1K = VCSC_VIDEO_MAP_1K;
constexpr int kMap2K = VCSC_VIDEO_MAP_2K;
constexpr int kMap4K = VCSC_VIDEO_MAP_4K;
constexpr int kMapF8 = VCSC_VIDEO_MAP_F8;
constexpr int kMapF6 = VCSC_VIDEO_MAP_F6;
constexpr int kMapF4 = VCSC_VIDEO_MAP_F4;
constexpr int kMapFA = VCSC_VIDEO_MAP_FA;

struct PendingWrite {
   uint16_t address;
   uint8_t value;
};

static unsigned instruction_length(uint8_t opcode)
{
   const char *mode = mos6502::GetAddr(opcode);
   if (!mode || std::strcmp(mode, "(null)") == 0) return 1u;
   if (std::strcmp(mode, "IMP") == 0 || std::strcmp(mode, "ACC") == 0)
      return 1u;
   if (std::strcmp(mode, "IMM") == 0 || std::strcmp(mode, "ZER") == 0 ||
       std::strcmp(mode, "ZEX") == 0 || std::strcmp(mode, "ZEY") == 0 ||
       std::strcmp(mode, "REL") == 0 || std::strcmp(mode, "INX") == 0 ||
       std::strcmp(mode, "INY") == 0)
      return 2u;
   return 3u;
}

class DiscoveryMachine {
public:
   DiscoveryMachine(const uint8_t *rom, size_t rom_size, int mapper,
                    size_t bank_count, size_t reset_bank, bool superchip,
                    uint8_t *rom_exec_start, uint16_t *rom_exec_pc,
                    vcsc_concrete_result_t *result)
      : rom_(rom), rom_size_(rom_size), mapper_(mapper), bank_count_(bank_count),
        bank_(reset_bank), superchip_(superchip), rom_exec_start_(rom_exec_start),
        rom_exec_pc_(rom_exec_pc), result_(result),
        cpu_(read_thunk, write_thunk, nullptr)
   {
      active_ = this;
      std::memset(ram_, 0, sizeof(ram_));
      std::memset(cart_ram_, 0, sizeof(cart_ram_));
      std::fill(ram_source_, ram_source_ + VCSC_CONCRETE_RIOT_RAM_SIZE, VCSC_CONCRETE_NO_SOURCE);
      std::memset(result_, 0, sizeof(*result_));
      for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE; ++i)
         result_->ram_source_offset[i] = VCSC_CONCRETE_NO_SOURCE;
      for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE * VCSC_CONCRETE_MAX_INSN_BYTES; ++i)
         result_->ram_exec_source[i] = VCSC_CONCRETE_NO_SOURCE;
      std::memset(rom_exec_start_, 0, rom_size_);
      std::memset(rom_exec_pc_, 0, rom_size_ * sizeof(*rom_exec_pc_));
      cpu_.IRQ(true);
      cpu_.NMI(true);
      cpu_.Reset();
   }

   int run()
   {
      unsigned instructions;
      unsigned executed = 0;
      unsigned stale = 0;
      for (instructions = 0; instructions < kMaxInstructions; ++instructions) {
         const unsigned starts_before = result_->rom_instruction_starts +
                                        result_->ram_instruction_starts;
         const uint16_t pc = cpu_.GetPC();
         current_pc_ = pc;
         current_data_source_ = VCSC_CONCRETE_NO_SOURCE;
         current_data_value_ = 0;
         current_data_reads_ = 0;
         pending_count_ = 0;
         uint8_t opcode = peek_opcode(pc);
         current_opcode_ = opcode;
         current_len_ = instruction_length(opcode);
         const char *mnemonic = mos6502::GetCode(opcode);
         if (mnemonic && ((std::strcmp(mnemonic, "RTS") == 0 && jsr_depth_ == 0u) ||
                          (std::strcmp(mnemonic, "RTI") == 0 && interrupt_depth_ == 0u))) {
            result_->top_level_return = 1;
            break;
         }
         note_instruction(pc, opcode);

         const uint64_t before = cpu_cycles_;
         cpu_.Run(1, cpu_cycles_, mos6502::INST_COUNT);
         const uint64_t delta = cpu_cycles_ - before;
         if (delta == 0) {
            result_->halted = 1;
            break;
         }
         ++executed;
         virtual_cycles_ += delta;
         apply_pending();
         update_register_provenance(opcode);
         if (mnemonic) {
            if (std::strcmp(mnemonic, "JSR") == 0) ++jsr_depth_;
            else if (std::strcmp(mnemonic, "RTS") == 0 && jsr_depth_ != 0u) --jsr_depth_;
            else if (std::strcmp(mnemonic, "BRK") == 0) ++interrupt_depth_;
            else if (std::strcmp(mnemonic, "RTI") == 0 && interrupt_depth_ != 0u) --interrupt_depth_;
         }
         if (result_->rom_instruction_starts + result_->ram_instruction_starts == starts_before)
            ++stale;
         else
            stale = 0;
         if (stale >= kConvergenceInstructions) {
            result_->converged = 1;
            break;
         }
      }
      result_->instructions = executed;
      if (instructions == kMaxInstructions) result_->instruction_limit = 1;
      result_->final_pc = cpu_.GetPC();
      result_->final_a = cpu_.GetA();
      result_->final_x = cpu_.GetX();
      result_->final_y = cpu_.GetY();
      result_->final_sp = cpu_.GetS();
      result_->final_p = cpu_.GetP();
      std::memcpy(result_->ram, ram_, sizeof(ram_));
      for (unsigned i = 0; i < VCSC_CONCRETE_RIOT_RAM_SIZE; ++i)
         result_->ram_source_offset[i] = ram_source_[i];
      return 1;
   }

private:
   const uint8_t *rom_;
   size_t rom_size_;
   int mapper_;
   size_t bank_count_;
   size_t bank_;
   bool superchip_;
   uint8_t *rom_exec_start_;
   uint16_t *rom_exec_pc_;
   vcsc_concrete_result_t *result_;
   uint8_t ram_[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint32_t ram_source_[VCSC_CONCRETE_RIOT_RAM_SIZE];
   uint8_t cart_ram_[256];
   mos6502 cpu_;
   uint64_t cpu_cycles_ = 0;
   uint64_t virtual_cycles_ = 0;
   bool timer_active_ = false;
   uint64_t timer_start_ = 0;
   uint16_t timer_divisor_ = 1;
   uint8_t timer_loaded_ = 0;
   PendingWrite pending_[8]{};
   unsigned pending_count_ = 0;
   uint16_t current_pc_ = 0;
   uint8_t current_opcode_ = 0;
   unsigned current_len_ = 1;
   uint32_t current_data_source_ = VCSC_CONCRETE_NO_SOURCE;
   uint8_t current_data_value_ = 0;
   unsigned current_data_reads_ = 0;
   uint32_t a_source_ = VCSC_CONCRETE_NO_SOURCE;
   uint32_t x_source_ = VCSC_CONCRETE_NO_SOURCE;
   uint32_t y_source_ = VCSC_CONCRETE_NO_SOURCE;
   unsigned jsr_depth_ = 0;
   unsigned interrupt_depth_ = 0;

   static DiscoveryMachine *active_;
   static uint8_t read_thunk(uint16_t address) { return active_->read(address); }
   static void write_thunk(uint16_t address, uint8_t value) { active_->write(address, value); }

   static uint16_t bus_address(uint16_t address) {
      return static_cast<uint16_t>(address & 0x1fffu);
   }

   bool tia_selected(uint16_t bus) const { return (bus & 0x1080u) == 0u; }
   bool riot_ram_selected(uint16_t bus) const { return (bus & 0x1280u) == 0x0080u; }
   bool riot_io_selected(uint16_t bus) const { return (bus & 0x1280u) == 0x0280u; }

   bool select_bank(uint16_t bus)
   {
      size_t next = bank_;
      bool hit = false;
      if (mapper_ == kMapF8 && bus >= 0x1ff8u && bus <= 0x1ff9u) {
         next = static_cast<size_t>(bus - 0x1ff8u); hit = true;
      }
      else if (mapper_ == kMapF6 && bus >= 0x1ff6u && bus <= 0x1ff9u) {
         next = static_cast<size_t>(bus - 0x1ff6u); hit = true;
      }
      else if (mapper_ == kMapF4 && bus >= 0x1ff4u && bus <= 0x1ffbu) {
         next = static_cast<size_t>(bus - 0x1ff4u); hit = true;
      }
      else if (mapper_ == kMapFA && bus >= 0x1ff8u && bus <= 0x1ffau) {
         next = static_cast<size_t>(bus - 0x1ff8u); hit = true;
      }
      if (hit && next < bank_count_) bank_ = next;
      return hit;
   }

   bool map_cart(uint16_t bus, size_t *physical) const
   {
      size_t off;
      size_t bank_size;
      if (!(bus & 0x1000u)) return false;
      if (mapper_ == kMap1K) { off = static_cast<size_t>(bus & 0x03ffu); bank_size = 1024u; }
      else if (mapper_ == kMap2K) { off = static_cast<size_t>(bus & 0x07ffu); bank_size = 2048u; }
      else { off = static_cast<size_t>(bus & 0x0fffu); bank_size = 4096u; }
      *physical = bank_ * bank_size + off;
      return *physical < rom_size_;
   }

   uint8_t peek_opcode(uint16_t address) const
   {
      const uint16_t bus = bus_address(address);
      if (bus & 0x1000u) {
         size_t physical;
         if (map_cart(bus, &physical)) return rom_[physical];
         return 0xffu;
      }
      if (riot_ram_selected(bus)) return ram_[bus & 0x7fu];
      return 0u;
   }

   void note_instruction(uint16_t pc, uint8_t opcode)
   {
      const uint16_t bus = bus_address(pc);
      if (bus & 0x1000u) {
         size_t physical;
         if (map_cart(bus, &physical)) {
            if (!rom_exec_start_[physical]) {
               rom_exec_start_[physical] = 1;
               rom_exec_pc_[physical] = pc;
               ++result_->rom_instruction_starts;
            }
         }
         return;
      }
      if (riot_ram_selected(bus)) {
         const unsigned idx = static_cast<unsigned>(bus & 0x7fu);
         if (!result_->ram_exec_start[idx]) {
            result_->ram_exec_start[idx] = 1;
            result_->ram_exec_pc[idx] = pc;
            const unsigned len = instruction_length(opcode);
            result_->ram_exec_len[idx] = static_cast<uint8_t>(len);
            for (unsigned j = 0; j < len && j < VCSC_CONCRETE_MAX_INSN_BYTES; ++j) {
               const uint16_t a = static_cast<uint16_t>(pc + j);
               const uint16_t ab = bus_address(a);
               uint8_t v = 0;
               if (riot_ram_selected(ab)) {
                  const unsigned ri = static_cast<unsigned>(ab & 0x7fu);
                  v = ram_[ri];
                  result_->ram_exec_source[idx * VCSC_CONCRETE_MAX_INSN_BYTES + j] = ram_source_[ri];
               }
               result_->ram_exec_bytes[idx * VCSC_CONCRETE_MAX_INSN_BYTES + j] = v;
            }
            ++result_->ram_instruction_starts;
         }
      }
   }

   uint8_t timer_value() const
   {
      if (!timer_active_) return 0;
      const uint64_t ticks = (virtual_cycles_ - timer_start_) / timer_divisor_;
      if (ticks <= timer_loaded_) return static_cast<uint8_t>(timer_loaded_ - ticks);
      return static_cast<uint8_t>(255u - ((ticks - timer_loaded_ - 1u) & 255u));
   }

   bool timer_underflowed() const
   {
      if (!timer_active_) return false;
      return (virtual_cycles_ - timer_start_) / timer_divisor_ > timer_loaded_;
   }

   uint8_t cart_read(uint16_t bus)
   {
      if (mapper_ == kMapFA) {
         if (bus >= 0x1100u && bus <= 0x11ffu) return cart_ram_[bus & 0xffu];
         if (bus >= 0x1000u && bus <= 0x10ffu) return 0;
      }
      if (superchip_) {
         if (bus >= 0x1080u && bus <= 0x10ffu) return cart_ram_[bus & 0x7fu];
         if (bus >= 0x1000u && bus <= 0x107fu) return 0;
      }
      select_bank(bus);
      size_t physical;
      if (!map_cart(bus, &physical)) return 0xffu;
      const uint8_t value = rom_[physical];
      const uint16_t delta = static_cast<uint16_t>(bus - bus_address(current_pc_));
      const bool fetch_byte = delta < current_len_;
      if (!fetch_byte) {
         current_data_source_ = static_cast<uint32_t>(physical);
         current_data_value_ = value;
         ++current_data_reads_;
      }
      return value;
   }

   void cart_write(uint16_t bus, uint8_t value)
   {
      if (mapper_ == kMapFA && bus >= 0x1000u && bus <= 0x10ffu) {
         cart_ram_[bus & 0xffu] = value; return;
      }
      if (superchip_ && bus >= 0x1000u && bus <= 0x107fu) {
         cart_ram_[bus & 0x7fu] = value; return;
      }
      (void)select_bank(bus);
   }

   uint8_t read(uint16_t address)
   {
      const uint16_t bus = bus_address(address);
      if (bus & 0x1000u) return cart_read(bus);
      (void)select_bank(bus);
      if (tia_selected(bus)) {
         const uint8_t reg = static_cast<uint8_t>(bus & 0x3fu);
         if (reg >= 0x08u && reg <= 0x0du) return 0x80u;
         return 0u;
      }
      if (riot_ram_selected(bus)) {
         const unsigned idx = static_cast<unsigned>(bus & 0x7fu);
         current_data_source_ = ram_source_[idx];
         current_data_value_ = ram_[idx];
         ++current_data_reads_;
         return ram_[idx];
      }
      if (riot_io_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(0x0280u | (bus & 0x1fu));
         if (reg == 0x0280u) return 0xffu; /* no controllers connected */
         if (reg == 0x0282u) return 0xffu; /* console switches inactive/high */
         if (reg == 0x0284u) return timer_value();
         if (reg == 0x0285u) return timer_underflowed() ? 0x80u : 0u;
         return 0u;
      }
      return 0u;
   }

   uint32_t store_source() const
   {
      const char *m = mos6502::GetCode(current_opcode_);
      if (!m) return VCSC_CONCRETE_NO_SOURCE;
      if (std::strcmp(m, "STA") == 0) return a_source_;
      if (std::strcmp(m, "STX") == 0) return x_source_;
      if (std::strcmp(m, "STY") == 0) return y_source_;
      return VCSC_CONCRETE_NO_SOURCE;
   }

   void queue_write(uint16_t bus, uint8_t value)
   {
      if (pending_count_ < sizeof(pending_) / sizeof(pending_[0]))
         pending_[pending_count_++] = { bus, value };
   }

   void write(uint16_t address, uint8_t value)
   {
      const uint16_t bus = bus_address(address);
      if (bus & 0x1000u) { cart_write(bus, value); return; }
      (void)select_bank(bus);
      if (tia_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(bus & 0x3fu);
         if (reg == 0x02u) queue_write(reg, value);
         return;
      }
      if (riot_ram_selected(bus)) {
         const unsigned idx = static_cast<unsigned>(bus & 0x7fu);
         if (!result_->ram_written[idx]) {
            result_->ram_written[idx] = 1;
            ++result_->ram_bytes_written;
         }
         ram_[idx] = value;
         ram_source_[idx] = store_source();
         return;
      }
      if (riot_io_selected(bus)) {
         const uint16_t reg = static_cast<uint16_t>(0x0280u | (bus & 0x1fu));
         if (reg >= 0x0294u && reg <= 0x0297u) queue_write(reg, value);
      }
   }

   void load_timer(uint16_t reg, uint8_t value)
   {
      timer_active_ = true;
      timer_start_ = virtual_cycles_;
      timer_loaded_ = value;
      timer_divisor_ = reg == 0x0294u ? 1u : reg == 0x0295u ? 8u :
                       reg == 0x0296u ? 64u : 1024u;
   }

   void apply_pending()
   {
      for (unsigned i = 0; i < pending_count_; ++i) {
         const uint16_t reg = pending_[i].address;
         if (reg == 0x02u) {
            const uint64_t within = virtual_cycles_ % kCyclesPerLine;
            virtual_cycles_ += within ? kCyclesPerLine - within : kCyclesPerLine;
         }
         else if (reg >= 0x0294u && reg <= 0x0297u)
            load_timer(reg, pending_[i].value);
      }
      pending_count_ = 0;
   }

   uint32_t immediate_source(uint16_t pc) const
   {
      const uint16_t bus = bus_address(static_cast<uint16_t>(pc + 1u));
      size_t physical;
      if ((bus & 0x1000u) && map_cart(bus, &physical))
         return static_cast<uint32_t>(physical);
      if (riot_ram_selected(bus)) return ram_source_[bus & 0x7fu];
      return VCSC_CONCRETE_NO_SOURCE;
   }

   void update_register_provenance(uint8_t opcode)
   {
      const char *m = mos6502::GetCode(opcode);
      const char *mode = mos6502::GetAddr(opcode);
      if (!m) { a_source_ = x_source_ = y_source_ = VCSC_CONCRETE_NO_SOURCE; return; }
      uint32_t load_source = current_data_reads_ ? current_data_source_ : VCSC_CONCRETE_NO_SOURCE;
      if (mode && std::strcmp(mode, "IMM") == 0) load_source = immediate_source(current_pc_);
      if (std::strcmp(m, "LDA") == 0) a_source_ = load_source;
      else if (std::strcmp(m, "LDX") == 0) x_source_ = load_source;
      else if (std::strcmp(m, "LDY") == 0) y_source_ = load_source;
      else if (std::strcmp(m, "TAX") == 0) x_source_ = a_source_;
      else if (std::strcmp(m, "TAY") == 0) y_source_ = a_source_;
      else if (std::strcmp(m, "TXA") == 0) a_source_ = x_source_;
      else if (std::strcmp(m, "TYA") == 0) a_source_ = y_source_;
      else if (std::strcmp(m, "PLA") == 0) a_source_ = load_source;
      else if (std::strcmp(m, "INX") == 0 || std::strcmp(m, "DEX") == 0) x_source_ = VCSC_CONCRETE_NO_SOURCE;
      else if (std::strcmp(m, "INY") == 0 || std::strcmp(m, "DEY") == 0) y_source_ = VCSC_CONCRETE_NO_SOURCE;
      else if (std::strcmp(m, "ADC") == 0 || std::strcmp(m, "SBC") == 0 ||
               std::strcmp(m, "AND") == 0 || std::strcmp(m, "ORA") == 0 ||
               std::strcmp(m, "EOR") == 0 || std::strcmp(m, "ASL") == 0 ||
               std::strcmp(m, "LSR") == 0 || std::strcmp(m, "ROL") == 0 ||
               std::strcmp(m, "ROR") == 0)
         a_source_ = VCSC_CONCRETE_NO_SOURCE;
   }
};

DiscoveryMachine *DiscoveryMachine::active_ = nullptr;
}

extern "C" int vcsc_concrete_discover(const uint8_t *rom, size_t rom_size,
                                        int mapper, size_t bank_count,
                                        size_t reset_bank, int superchip,
                                        uint8_t *rom_exec_start,
                                        uint16_t *rom_exec_pc,
                                        vcsc_concrete_result_t *result)
{
   if (!rom || !rom_exec_start || !rom_exec_pc || !result ||
       bank_count == 0u || reset_bank >= bank_count) return 0;
   switch (mapper) {
   case kMap1K:
   case kMap2K:
   case kMap4K:
   case kMapF8:
   case kMapF6:
   case kMapF4:
   case kMapFA:
      break;
   default:
      std::memset(result, 0, sizeof(*result));
      return 0;
   }
   DiscoveryMachine machine(rom, rom_size, mapper, bank_count, reset_bank,
                            superchip != 0, rom_exec_start, rom_exec_pc, result);
   return machine.run();
}
