#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: installed F8 profile certified
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
sub image_offset_for_addr {
   my ($addr) = @_;
   return ($addr >= 0xF000 ? 0x1000 : 0) + ($addr & 0x0FFF);
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $cfg = File::Spec->catfile($repo, 'libraries', 'vcs', 'vcs_8k_f8.cfg');
my $fixture = File::Spec->catfile($repo, 'test', 'fixtures', 'bankswitching',
                                  'f8_profile_diagnostic.c26');
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $ld = File::Spec->catfile($repo, 'linker', 'vcsc-ld');
-f $cfg or die "public vcs_8k_f8.cfg is missing\n";
-f $fixture or die "F8 profile diagnostic fixture is missing\n";

my $cfg_text = slurp($cfg);
$cfg_text =~ /mapper\s*=\s*F8/ or die "F8 profile does not select mapper F8\n";
$cfg_text =~ /BANK0:\s*start\s*=\s*\$F000,\s*size\s*=\s*\$1000,\s*hotspot\s*=\s*\$1FF9,\s*startup\s*=\s*yes/s
   or die "F8 profile BANK0/home declaration is wrong\n";
$cfg_text =~ /BANK1:\s*start\s*=\s*\$D000,\s*size\s*=\s*\$1000,\s*hotspot\s*=\s*\$1FF8,\s*startup\s*=\s*no/s
   or die "F8 profile BANK1/file-chunk-0 declaration is wrong\n";
$cfg_text =~ /bank0:\s*start\s*=\s*\$F000,\s*size\s*=\s*\$0F00,\s*type\s*=\s*ro/s &&
$cfg_text =~ /bank1:\s*start\s*=\s*\$D000,\s*size\s*=\s*\$0F00,\s*type\s*=\s*ro/s
   or die "F8 profile ordinary bank allocation spans are wrong\n";
$cfg_text =~ /trampoline\s*=\s*\$0F00/ &&
$cfg_text =~ /trampolinesize\s*=\s*\$00E0/ &&
$cfg_text =~ /vectorbridge\s*=\s*\$0FE0/
   or die "F8 profile common reserved corridors are wrong\n";

# Compile the public source diagnostic through the high-level driver.  This
# proves hard pins, automatic same-bank data affinity, BANK0 main/startup, both
# bridge kinds, map reporting, and exact output size using the shipped profile.
my $source_bin = File::Spec->catfile($tmp, 'f8-source.bin');
my $source_map = File::Spec->catfile($tmp, 'f8-source.map');
require_ok('compile public F8 source diagnostic',
           $driver, '-I', File::Spec->catdir($repo, 'test'),
           '-DMACHINE_6502_NO_DEFAULT_ZEROPAGE', '-DMACHINE_6502_NO_DEFAULT_CPUSTACK',
           '-DMACHINE_6502_NO_DEFAULT_RAM', '-DMACHINE_6502_NO_DEFAULT_ROM',
           '-T', $cfg, '-Map', $source_map, '-o', $source_bin, $fixture);
my $source_image = slurp($source_bin);
my $source_map_text = slurp($source_map);
length($source_image) == 8192 or die "public F8 source image was not exactly 8192 bytes\n";
$source_map_text =~ /BANK0\s+start=\$F000 size=\$1000 hotspot=\$1FF9 file=\$00001000 startup=yes/ &&
$source_map_text =~ /BANK1\s+start=\$D000 size=\$1000 hotspot=\$1FF8 file=\$00000000/
   or die "F8 map lost logical-bank/file-order/hotspot identities\n$source_map_text";
$source_map_text =~ /pinned\s+CODE\.__vcsc_function\$main\s+region=bank0/ &&
$source_map_text =~ /pinned\s+CODE\.bank0\.__vcsc_function\$home_leaf\s+region=bank0/ &&
$source_map_text =~ /pinned\s+CODE\.bank1\.__vcsc_function\$remote\s+region=bank1/
   or die "F8 source pins or main residency are wrong\n$source_map_text";
$source_map_text =~ /pinned\s+RODATA\.bank1\.__vcsc_object\$bank1_value\s+region=bank1.*\n\s+automatic CODE\.__vcsc_function\$automatic_reader\s+region=bank1/s
   or die "F8 automatic reader did not follow its BANK1 const object\n$source_map_text";
$source_map_text =~ /entries=5 jmp=1 jsr=4/ &&
$source_map_text =~ /JMP entry=.*destination=BANK0 hotspot=\$1FF9/ &&
$source_map_text =~ /JSR entry=.*source=BANK0 hotspot=\$1FF9 destination=BANK1 hotspot=\$1FF8/ &&
$source_map_text =~ /JSR entry=.*source=BANK1 hotspot=\$1FF8 destination=BANK0 hotspot=\$1FF9/
   or die "F8 source diagnostic did not generate the expected cross-bank bridges\n$source_map_text";
substr($source_image, 0x0F00, 0x00E0) eq substr($source_image, 0x1F00, 0x00E0)
   or die "F8 source trampoline corridor is not byte-identical in both file chunks\n";
substr($source_image, 0x0FE0, 0x0012) eq substr($source_image, 0x1FE0, 0x0012)
   or die "F8 source vector bridge is not byte-identical in both file chunks\n";
substr($source_image, 0x0FFA, 6) eq substr($source_image, 0x1FFA, 6)
   or die "F8 source vectors are not byte-identical in both file chunks\n";
unpack('v', substr($source_image, 0x0FFC, 2)) == 0xFFE6
   or die "F8 reset vector does not target the BANK0-mirror reset bridge\n";

# Link a tiny assembly diagnostic with the same public cfg and execute the
# reset path from each possible initially selected bank.  The opcode model is
# intentionally limited to this fixture; full mapper-aware vcsc-sim support is
# a later roadmap item.
my $asm_src = File::Spec->catfile($tmp, 'f8-exec.s26');
my $asm_obj = File::Spec->catfile($tmp, 'f8-exec.o26');
my $asm_bin = File::Spec->catfile($tmp, 'f8-exec.bin');
my $asm_map = File::Spec->catfile($tmp, 'f8-exec.map');
write_file($asm_src, <<'ASM');
.export __reset
.export __nmi
.export __irqbrk
.export main
.export home_leaf
.export remote
.export remote_jump
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
   LDA #$11
   JSR remote
   STA.a $0080
   RTS
.endproc
.segment "CODE.bank0"
.proc home_leaf
   STA.a $0083
   LDA #$33
   RTS
.endproc
.proc again
   JMP remote_jump
.endproc
.segment "CODE.bank1"
.proc remote
   STA.a $0081
   LDA #$22
   JSR home_leaf
   STA.a $0082
   RTS
.endproc
.proc remote_jump
   RTS
.endproc
ASM
require_ok('assemble F8 execution diagnostic', $as, '-o', $asm_obj, $asm_src);
require_ok('link F8 execution diagnostic', $ld, '-T', $cfg, '-Map', $asm_map,
           '--no-sym', '--no-list', '--no-cfg', '-o', $asm_bin, $asm_obj);
my $image = slurp($asm_bin);
my $map = slurp($asm_map);
length($image) == 8192 or die "F8 execution diagnostic was not exactly 8192 bytes\n";
$map =~ /entries=3 jmp=1 jsr=2/ or die "F8 execution diagnostic bridge counts are wrong\n$map";
my $reset_addr = map_symbol_addr($map, '__reset');
my $main_addr = map_symbol_addr($map, 'main');
$reset_addr >= 0xF000 && $main_addr >= 0xF000
   or die "F8 execution diagnostic startup or main escaped BANK0\n";

for my $initial (0, 1) {
   my @ram = (0) x 256;
   my @stack = (0) x 256;
   my $selected = $initial;
   my $sp = 0xFF;
   my $a = 0;
   my $steps = 0;
   my $read8 = sub {
      my ($addr) = @_;
      return $ram[$addr] if $addr < 0x100;
      return ord(substr($image, $selected * 0x1000 + ($addr & 0x0FFF), 1));
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
   $pc == 0xFFE6 or die sprintf("initial file chunk %u supplied reset vector %04X, expected FFE6\n", $initial, $pc);

   while (++$steps < 300) {
      my $op = $read8->($pc);
      if ($op == 0xA9) { # LDA immediate
         $a = $read8->(($pc + 1) & 0xFFFF);
         $pc = ($pc + 2) & 0xFFFF;
      }
      elsif ($op == 0x2C) { # BIT absolute; mapper hotspot access
         my $addr = $read8->(($pc + 1) & 0xFFFF) |
                    ($read8->(($pc + 2) & 0xFFFF) << 8);
         $selected = 0 if $addr == 0x1FF8;
         $selected = 1 if $addr == 0x1FF9;
         $pc = ($pc + 3) & 0xFFFF;
      }
      elsif ($op == 0x8D) { # STA absolute; RAM or mapper hotspot
         my $addr = $read8->(($pc + 1) & 0xFFFF) |
                    ($read8->(($pc + 2) & 0xFFFF) << 8);
         if ($addr == 0x1FF8) { $selected = 0; }
         elsif ($addr == 0x1FF9) { $selected = 1; }
         elsif ($addr < 0x100) { $ram[$addr] = $a; }
         $pc = ($pc + 3) & 0xFFFF;
      }
      elsif ($op == 0x4C) { # JMP absolute
         $pc = $read8->(($pc + 1) & 0xFFFF) |
               ($read8->(($pc + 2) & 0xFFFF) << 8);
      }
      elsif ($op == 0x6C) { # JMP (absolute)
         my $pointer = $read8->(($pc + 1) & 0xFFFF) |
                       ($read8->(($pc + 2) & 0xFFFF) << 8);
         $pc = $read8->($pointer) | ($read8->(($pointer + 1) & 0xFFFF) << 8);
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
         die sprintf("F8 reset/JSR model hit unsupported opcode %02X at %04X from initial file chunk %u\n",
                     $op, $pc, $initial);
      }
   }
   $steps < 300 or die "F8 reset/JSR execution did not terminate\n";
   $ram[0x81] == 0x11 or die "F8 destination callee lost caller A\n";
   $ram[0x83] == 0x22 or die "F8 nested BANK0 callee lost caller A\n";
   $ram[0x82] == 0x33 or die "F8 nested return did not restore BANK1 correctly\n";
   $ram[0x80] == 0x33 or die "F8 outer return did not restore BANK0 correctly\n";
   $selected == 1 or die "F8 reset/JSR path did not finish in BANK0/file chunk 1\n";
   $sp == 0xFF or die "F8 reset/JSR path did not balance the hardware stack\n";
}

print "installed F8 profile certified\n";
