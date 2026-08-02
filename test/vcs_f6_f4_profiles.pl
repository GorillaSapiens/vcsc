#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: installed F6 and F4 profiles certified
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not read $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
}
sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}
sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub require_ok {
   my ($label, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit == 0 && !$sig
      or die "$label failed: exit=$exit signal=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out, $err);
}
sub map_symbol_addr {
   my ($map, $name) = @_;
   return hex($1) if $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m;
   die "map omitted symbol $name\n$map";
}
sub mapper_info {
   my ($mapper) = @_;
   return (4, 0x1FF6, 'vcs_16k_f6.cfg') if $mapper eq 'F6';
   return (8, 0x1FF4, 'vcs_32k_f4.cfg') if $mapper eq 'F4';
   die "unknown mapper $mapper\n";
}
sub bank_start {
   my ($bank) = @_;
   return 0xF000 - $bank * 0x2000;
}
sub file_index_for_bank {
   my ($count, $bank) = @_;
   return $count - 1 - $bank;
}
sub hotspot_for_bank {
   my ($count, $first_hotspot, $bank) = @_;
   return $first_hotspot + file_index_for_bank($count, $bank);
}
sub bank_for_hotspot {
   my ($count, $first_hotspot, $address) = @_;
   my $file_index = ($address & 0x1FFF) - $first_hotspot;
   return undef if $file_index < 0 || $file_index >= $count;
   return $count - 1 - $file_index;
}
sub diagnostic_source {
   my ($count) = @_;
   my $text = <<'ASM';
.export __reset
.export __nmi
.export __irqbrk
.export main
ASM
   for my $bank (1 .. $count - 1) {
      $text .= sprintf(".export bank%d_fn\n", $bank);
   }
   $text .= <<'ASM';
.segment "CODE"
.proc __reset
   JSR main
   RTS
.endproc
.proc __nmi
   RTS
.endproc
.proc __irqbrk
   RTS
.endproc
.proc main
   LDA #$A0
   STA.a $0080
   JSR bank1_fn
   LDA #$B0
   STA.a $0090
   RTS
.endproc
ASM
   for my $bank (1 .. $count - 1) {
      $text .= sprintf(".segment \"CODE.bank%d\"\n", $bank);
      $text .= sprintf(".proc bank%d_fn\n", $bank);
      $text .= sprintf("   LDA #\$%02X\n", $bank);
      $text .= sprintf("   STA.a \$%04X\n", 0x0080 + $bank);
      if ($bank + 1 < $count) {
         $text .= sprintf("   JSR bank%d_fn\n", $bank + 1);
      }
      $text .= sprintf("   LDA #\$%02X\n", 0x80 + $bank);
      $text .= sprintf("   STA.a \$%04X\n", 0x0090 + $bank);
      $text .= "   RTS\n.endproc\n";
   }
   return $text;
}
sub certify_execution {
   my ($mapper, $count, $first_hotspot, $image, $initial_bank) = @_;
   my @ram = (0) x 256;
   my @stack = (0) x 256;
   my @hotspot_seen = (0) x $count;
   my $selected = $initial_bank;
   my $sp = 0xFF;
   my $a = 0;
   my $steps = 0;

   my $read8 = sub {
      my ($addr) = @_;
      if ($addr < 0x100) {
         return $ram[$addr];
      }
      my $file_index = file_index_for_bank($count, $selected);
      my $value = ord(substr($image, $file_index * 0x1000 + ($addr & 0x0FFF), 1));
      my $bank = bank_for_hotspot($count, $first_hotspot, $addr);
      if (defined $bank) {
         $selected = $bank;
         $hotspot_seen[$bank]++;
      }
      return $value;
   };
   my $write8 = sub {
      my ($addr, $value) = @_;
      my $bank = bank_for_hotspot($count, $first_hotspot, $addr);
      if (defined $bank) {
         $selected = $bank;
         $hotspot_seen[$bank]++;
      }
      elsif ($addr < 0x100) {
         $ram[$addr] = $value & 0xFF;
      }
   };
   my $push = sub {
      my ($value) = @_;
      $stack[$sp] = $value & 0xFF;
      $sp = ($sp - 1) & 0xFF;
   };
   my $pop = sub {
      $sp = ($sp + 1) & 0xFF;
      return $stack[$sp];
   };

   my $pc = $read8->(0xFFFC) | ($read8->(0xFFFD) << 8);
   $pc == 0xFFE6
      or die sprintf("%s reset from BANK%d produced vector %04X, expected FFE6\n",
                     $mapper, $initial_bank, $pc);

   while (++$steps < 4000) {
      my $op = $read8->($pc);
      if ($op == 0xA9) { # LDA immediate
         $a = $read8->(($pc + 1) & 0xFFFF);
         $pc = ($pc + 2) & 0xFFFF;
      }
      elsif ($op == 0x2C) { # BIT absolute; the read may select a bank
         my $addr = $read8->(($pc + 1) & 0xFFFF) |
                    ($read8->(($pc + 2) & 0xFFFF) << 8);
         $read8->($addr);
         $pc = ($pc + 3) & 0xFFFF;
      }
      elsif ($op == 0x8D) { # STA absolute; RAM or mapper hotspot
         my $addr = $read8->(($pc + 1) & 0xFFFF) |
                    ($read8->(($pc + 2) & 0xFFFF) << 8);
         $write8->($addr, $a);
         $pc = ($pc + 3) & 0xFFFF;
      }
      elsif ($op == 0x4C) { # JMP absolute
         $pc = $read8->(($pc + 1) & 0xFFFF) |
               ($read8->(($pc + 2) & 0xFFFF) << 8);
      }
      elsif ($op == 0x6C) { # JMP (absolute)
         my $pointer = $read8->(($pc + 1) & 0xFFFF) |
                       ($read8->(($pc + 2) & 0xFFFF) << 8);
         my $lo = $read8->($pointer);
         my $hi = $read8->(($pointer + 1) & 0xFFFF);
         $pc = $lo | ($hi << 8);
      }
      elsif ($op == 0x20) { # JSR absolute
         my $target = $read8->(($pc + 1) & 0xFFFF) |
                      ($read8->(($pc + 2) & 0xFFFF) << 8);
         my $ret = ($pc + 2) & 0xFFFF;
         $push->($ret >> 8);
         $push->($ret & 0xFF);
         $pc = $target;
      }
      elsif ($op == 0x60) { # RTS
         last if $sp == 0xFF;
         $pc = (($pop->() | ($pop->() << 8)) + 1) & 0xFFFF;
      }
      else {
         die sprintf("%s execution hit unsupported opcode %02X at %04X from initial BANK%d\n",
                     $mapper, $op, $pc, $initial_bank);
      }
   }
   $steps < 4000 or die "$mapper nested execution did not terminate\n";
   $ram[0x80] == 0xA0 && $ram[0x90] == 0xB0
      or die "$mapper main did not execute before and after the nested chain\n";
   for my $bank (1 .. $count - 1) {
      $ram[0x80 + $bank] == $bank
         or die "$mapper BANK$bank entry signature is wrong\n";
      $ram[0x90 + $bank] == 0x80 + $bank
         or die "$mapper BANK$bank return signature is wrong\n";
   }
   $selected == 0 or die "$mapper nested chain did not finish in VCSC BANK0\n";
   $sp == 0xFF or die "$mapper nested chain did not balance the hardware stack\n";
   for my $bank (0 .. $count - 1) {
      $hotspot_seen[$bank] > 0
         or die "$mapper execution never exercised BANK$bank selector hotspot\n";
   }
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $ld = File::Spec->catfile($repo, 'linker', 'vcsc-ld');

for my $mapper (qw(F6 F4)) {
   my ($count, $first_hotspot, $cfg_name) = mapper_info($mapper);
   my $cfg = File::Spec->catfile($repo, 'libraries', 'vcs', $cfg_name);
   -f $cfg or die "public $cfg_name is missing\n";
   my $cfg_text = slurp($cfg);
   $cfg_text =~ /mapper\s*=\s*\Q$mapper\E/
      or die "$cfg_name does not select mapper $mapper\n";

   for my $bank (0 .. $count - 1) {
      my $start = bank_start($bank);
      my $hotspot = hotspot_for_bank($count, $first_hotspot, $bank);
      my $startup = $bank == 0 ? 'yes' : 'no';
      $cfg_text =~ /BANK\Q$bank\E:\s*start\s*=\s*\$\Q@{[sprintf('%04X',$start)]}\E,\s*size\s*=\s*\$1000,\s*hotspot\s*=\s*\$\Q@{[sprintf('%04X',$hotspot)]}\E,\s*startup\s*=\s*\Q$startup\E/s
         or die "$cfg_name BANK$bank declaration is wrong\n";
      $cfg_text =~ /bank\Q$bank\E:\s*start\s*=\s*\$\Q@{[sprintf('%04X',$start)]}\E,\s*size\s*=\s*\$0F00,\s*type\s*=\s*ro/s
         or die "$cfg_name bank$bank allocation span is wrong\n";
   }

   my $src = File::Spec->catfile($tmp, lc($mapper) . '-profile.s26');
   my $obj = File::Spec->catfile($tmp, lc($mapper) . '-profile.o26');
   my $bin = File::Spec->catfile($tmp, lc($mapper) . '-profile.bin');
   my $map_path = File::Spec->catfile($tmp, lc($mapper) . '-profile.map');
   write_file($src, diagnostic_source($count));
   require_ok("assemble public $mapper profile diagnostic", $as, '-o', $obj, $src);
   require_ok("link public $mapper profile diagnostic", $ld, '-T', $cfg,
              '-Map', $map_path, '--no-sym', '--no-list', '--no-cfg',
              '-o', $bin, $obj);

   my $image = slurp($bin);
   my $map = slurp($map_path);
   length($image) == $count * 0x1000
      or die "$mapper image was not exactly " . ($count * 4096) . " bytes\n";
   $map =~ /mapper=\Q$mapper\E output-size=\$[0-9A-Fa-f]{8}/
      or die "$mapper map omitted cartridge metadata\n$map";
   $map =~ /entries=@{[$count - 1]} jmp=0 jsr=@{[$count - 1]}/
      or die "$mapper did not generate one nested JSR bridge per non-home bank\n$map";

   for my $bank (0 .. $count - 1) {
      my $start = bank_start($bank);
      my $hotspot = hotspot_for_bank($count, $first_hotspot, $bank);
      my $file = file_index_for_bank($count, $bank) * 0x1000;
      my $startup = $bank == 0 ? ' startup=yes' : '';
      $map =~ /BANK\Q$bank\E\s+start=\$\Q@{[sprintf('%04X',$start)]}\E size=\$1000 hotspot=\$\Q@{[sprintf('%04X',$hotspot)]}\E file=\$\Q@{[sprintf('%08X',$file)]}\E\Q$startup\E/
         or die "$mapper map has wrong BANK$bank logical/file/hotspot identity\n$map";
      if ($bank > 0) {
         my $addr = map_symbol_addr($map, "bank${bank}_fn");
         ($addr & 0xF000) == ($start & 0xF000)
            or die "$mapper bank${bank}_fn escaped BANK$bank\n";
      }
   }
   (map_symbol_addr($map, 'main') & 0xF000) == 0xF000
      or die "$mapper main escaped BANK0\n";

   my $common_trampoline = substr($image, 0x0F00, 0x00E0);
   my $common_bridge = substr($image, 0x0FE0, 0x0012);
   my $common_vectors = substr($image, 0x0FFA, 6);
   $common_vectors eq pack('v3', 0xFFE0, 0xFFE6, 0xFFEC)
      or die "$mapper vectors do not use BANK0-mirror bridge addresses\n";
   for my $file_index (0 .. $count - 1) {
      my $chunk = $file_index * 0x1000;
      substr($image, $chunk + 0x0F00, 0x00E0) eq $common_trampoline
         or die "$mapper trampoline corridor differs in file chunk $file_index\n";
      substr($image, $chunk + 0x0FE0, 0x0012) eq $common_bridge
         or die "$mapper vector bridge differs in file chunk $file_index\n";
      substr($image, $chunk + 0x0FFA, 6) eq $common_vectors
         or die "$mapper vectors differ in file chunk $file_index\n";
      for my $selector ($first_hotspot .. $first_hotspot + $count - 1) {
         my $offset = $selector & 0x0FFF;
         my $actual = ord(substr($image, $chunk + $offset, 1));
         my $expected = $offset >= 0x0FFA
                      ? ord(substr($common_vectors, $offset - 0x0FFA, 1))
                      : 0xFF;
         $actual == $expected
            or die sprintf("%s file chunk %u selector byte %03X was %02X, expected reserved %02X\n",
                           $mapper, $file_index, $offset, $actual, $expected);
      }
   }

   # F4's NMI vector bytes are themselves selector hotspots.  Fetching the
   # byte-identical word must still produce $FFE0 and finish with BANK0 selected.
   if ($mapper eq 'F4') {
      for my $initial (0 .. $count - 1) {
         my $selected = $initial;
         my @bytes;
         for my $addr (0xFFFA, 0xFFFB) {
            my $file_index = file_index_for_bank($count, $selected);
            push @bytes, ord(substr($image, $file_index * 0x1000 + ($addr & 0x0FFF), 1));
            my $bank = bank_for_hotspot($count, $first_hotspot, $addr);
            $selected = $bank if defined $bank;
         }
         ($bytes[0] | ($bytes[1] << 8)) == 0xFFE0 && $selected == 0
            or die "F4 NMI vector/hotspot overlap was not deterministic from BANK$initial\n";
      }
   }

   certify_execution($mapper, $count, $first_hotspot, $image, $_)
      for 0 .. $count - 1;
}

print "installed F6 and F4 profiles certified\n";
