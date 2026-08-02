#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: banked relocation classes enforced
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}
sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "could not read $path: $!\n";
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
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
sub require_fail {
   my ($label, $fragment, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   ($exit != 0 || $sig) or die "$label unexpectedly succeeded\n@cmd\n";
   index($err, $fragment) >= 0
      or die "$label stderr missing '$fragment'\nstdout:\n$out\nstderr:\n$err";
   return $err;
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $ld = File::Spec->catfile($repo, 'linker', 'vcsc-ld');
my $cfg = File::Spec->catfile($tmp, 'f8.cfg');

write_file($cfg, <<'CFG');
CARTRIDGE {
   mapper = F8;
   fillval = $FF;
   trampoline = $0F00;
   trampolinesize = $00E0;
   vectorbridge = $0FE0;
}
BANKS {
   BANK0: start=$F000, size=$1000, hotspot=$1FF9, startup=yes;
   BANK1: start=$D000, size=$1000, hotspot=$1FF8, startup=no;
}
MEMORY {
   ZEROPAGE: start=$0000, size=$0080, type=rw;
   RAM: start=$0080, size=$0080, type=rw;
   bank1: start=$D000, size=$0F00, type=ro, bank=BANK1;
   BANK1_TRAMPOLINE: start=$DF00, size=$00E0, bank=BANK1;
   BANK1_VECTOR_BRIDGE: start=$DFE0, size=$0012, bank=BANK1;
   BANK1_TAIL: start=$DFF2, size=$0008, bank=BANK1;
   BANK1_VECTORS: start=$DFFA, size=$0006, bank=BANK1;
   ROM: start=$F000, size=$0F00, type=ro, bank=BANK0;
   BANK0_TRAMPOLINE: start=$FF00, size=$00E0, bank=BANK0;
   BANK0_VECTOR_BRIDGE: start=$FFE0, size=$0012, bank=BANK0;
   BANK0_TAIL: start=$FFF2, size=$0008, bank=BANK0;
   BANK0_VECTORS: start=$FFFA, size=$0006, bank=BANK0;
}
SEGMENTS {
   ZEROPAGE: load=ROM, run=ZEROPAGE, type=zp;
   DATA: load=ROM, run=RAM, type=data;
   BSS: load=RAM, type=bss;
   STARTUP: load=ROM, type=ro;
   CODE: load=ROM, type=ro;
   CODE.bank1: load=bank1, type=ro;
   RODATA: load=ROM, type=ro;
   VECTORS: load=BANK0_VECTORS, type=ro, start=$FFFA;
}
CFG

sub assemble_case {
   my ($name, $source) = @_;
   my $src = File::Spec->catfile($tmp, "$name.s26");
   my $obj = File::Spec->catfile($tmp, "$name.o26");
   write_file($src, $source);
   require_ok("assemble $name", $as, '-o', $obj, $src);
   return $obj;
}
sub link_command {
   my ($name, @objects) = @_;
   return ($ld, '-T', $cfg, '--no-map', '--no-sym', '--no-list', '--no-cfg',
           '-o', File::Spec->catfile($tmp, "$name.bin"), @objects);
}

my $preamble = <<'ASM';
.export __reset
.export __nmi
.export __irqbrk
.export main
.segment "CODE"
.proc __reset
   RTS
.endproc
.proc __nmi
   RTS
.endproc
.proc __irqbrk
   RTS
.endproc
ASM

my $same = assemble_case('same_and_shared', $preamble . <<'ASM');
.export same_target
.export same_data
.export shared_byte
.proc main
   JSR same_target
   LDA same_data
   LDA shared_byte
   JMP same_exit
.endproc
.proc same_target
   RTS
.endproc
same_data:
   .byte $42
same_exit:
   RTS
.segment "BSS"
shared_byte:
   .res 1
ASM
require_ok('same-bank code/data and shared RAM relocations',
           link_command('same_and_shared', $same));

my $cross_jsr = assemble_case('cross_jsr', $preamble . <<'ASM');
.export remote
.proc main
   JSR remote
   RTS
.endproc
.segment "CODE.bank1"
.proc remote
   RTS
.endproc
ASM
my $jsr_err = require_fail('cross-bank JSR classification', 'cross-bank JSR',
                           link_command('cross_jsr', $cross_jsr));
$jsr_err =~ /\(BANK0\).*\(BANK1\).*JSR trampoline generation/s
   or die "cross-bank JSR diagnostic omitted bank identities or trampoline status\n$jsr_err";

my $cross_jmp = assemble_case('cross_jmp', $preamble . <<'ASM');
.export remote
.export again
.export return_home
.export home_target
.proc main
   JMP remote
.endproc
.proc again
   JMP remote
.endproc
.proc home_target
   RTS
.endproc
.segment "CODE.bank1"
.proc remote
   RTS
.endproc
.proc return_home
   JMP home_target
.endproc
ASM
my $cross_jmp_bin = File::Spec->catfile($tmp, 'cross_jmp.bin');
my $cross_jmp_map = File::Spec->catfile($tmp, 'cross_jmp.map');
require_ok('cross-bank JMP trampoline generation',
           $ld, '-T', $cfg, '-Map', $cross_jmp_map,
           '--no-sym', '--no-list', '--no-cfg',
           '-o', $cross_jmp_bin, $cross_jmp);
my $jmp_image = slurp($cross_jmp_bin);
my $jmp_map = slurp($cross_jmp_map);
length($jmp_image) == 8192 or die "cross-JMP image was not 8K\n";
$jmp_map =~ /common-offset=\$F00 reserved=\$0E0 used=\$010 replicated=\$00000020 target-passing=inline entries=2 entry-size=\$08/
   or die "map omitted common JMP table accounting or deduplication\n$jmp_map";
my $bank1_table = substr($jmp_image, 0x0F00, 0x10);
my $bank0_table = substr($jmp_image, 0x1F00, 0x10);
$bank1_table eq $bank0_table
   or die "common JMP table was not byte-identical in both banks\n";
sub map_symbol_addr {
   my ($map, $name) = @_;
   return hex($1) if $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m;
   die "map omitted symbol $name\n$map";
}
sub image_offset_for_addr {
   my ($addr) = @_;
   return ($addr >= 0xF000 ? 0x1000 : 0) + ($addr & 0x0FFF);
}
my $remote_addr = map_symbol_addr($jmp_map, 'remote');
my $home_addr = map_symbol_addr($jmp_map, 'home_target');
my $main_addr = map_symbol_addr($jmp_map, 'main');
my $again_addr = map_symbol_addr($jmp_map, 'again');
my $return_home_addr = map_symbol_addr($jmp_map, 'return_home');
my $entry0 = pack('C*',
   0x8D, 0xF8, 0x1F,
   0x6C, 0x06, 0xFF,
   $remote_addr & 0xFF, $remote_addr >> 8);
my $entry1 = pack('C*',
   0x8D, 0xF9, 0x1F,
   0x6C, 0x0E, 0xFF,
   $home_addr & 0xFF, $home_addr >> 8);
substr($bank0_table, 0x00, 0x08) eq $entry0
   or die "BANK0-to-BANK1 JMP entry bytes are wrong\n";
substr($bank0_table, 0x08, 0x08) eq $entry1
   or die "BANK1-to-BANK0 JMP entry bytes are wrong\n";
substr($jmp_image, image_offset_for_addr($main_addr), 3) eq pack('Cv', 0x4C, 0xFF00)
   or die "main JMP was not redirected to BANK0's first table mirror\n";
substr($jmp_image, image_offset_for_addr($again_addr), 3) eq pack('Cv', 0x4C, 0xFF00)
   or die "equivalent JMP target did not reuse the first table entry\n";
substr($jmp_image, image_offset_for_addr($return_home_addr), 3) eq pack('Cv', 0x4C, 0xDF08)
   or die "BANK1 JMP was not redirected to BANK1's second table mirror\n";
$jmp_map =~ /JMP entry=0 .*target=\$[0-9A-Fa-f]{4} .*destination=BANK1 hotspot=\$1FF8/
   or die "map omitted BANK1 JMP entry details\n$jmp_map";
$jmp_map =~ /JMP entry=1 .*target=\$[0-9A-Fa-f]{4} .*destination=BANK0 hotspot=\$1FF9/
   or die "map omitted BANK0 JMP entry details\n$jmp_map";

my $tiny_cfg = File::Spec->catfile($tmp, 'tiny-trampoline.cfg');
my $tiny_text = slurp($cfg);
$tiny_text =~ s/trampolinesize = \$00E0/trampolinesize = \$0008/;
write_file($tiny_cfg, $tiny_text);
require_fail('common JMP corridor exhaustion', 'common trampoline corridor',
             $ld, '-T', $tiny_cfg, '--no-map', '--no-sym', '--no-list', '--no-cfg',
             '-o', File::Spec->catfile($tmp, 'tiny-trampoline.bin'), $cross_jmp);

my $cross_branch = assemble_case('cross_branch', $preamble . <<'ASM');
.export remote
.proc main
   BNE remote
   RTS
.endproc
.segment "CODE.bank1"
.proc remote
   RTS
.endproc
ASM
require_fail('cross-bank relative branch', 'cross-bank conditional branch',
             link_command('cross_branch', $cross_branch));

my $long_padding = join('', map { "   .byte \$00\n" } 1 .. 140);
my $cross_long_branch = assemble_case('cross_long_branch', $preamble . <<'ASM' . $long_padding . <<'ASM');
.export remote
.proc main
   BNE remote
   RTS
.endproc
.segment "CODE"
ASM
.segment "CODE.bank1"
.proc remote
   RTS
.endproc
ASM
require_fail('cross-bank relaxed long branch', 'cross-bank conditional branch',
             link_command('cross_long_branch', $cross_long_branch));

for my $case (
   ['cross_word', 'LDA.a remote_data', 'cross-bank ROM word relocation'],
   ['cross_low',  'LDA #<remote_data', 'cross-bank ROM low-byte relocation'],
   ['cross_high', 'LDX #>remote_data', 'cross-bank ROM high-byte relocation'],
   ['cross_pointer', '.word remote_data', 'cross-bank ROM word relocation'],
   ['cross_indirect', 'JMP (remote_data)', 'the indirect-JMP vector is a data reference'],
) {
   my ($name, $statement, $fragment) = @$case;
   my $body;
   if ($statement =~ /^\./) {
      $body = $preamble . ".proc main\n   RTS\n.endproc\npointer_value:\n   $statement\n";
   } else {
      $body = $preamble . ".proc main\n   $statement\n   RTS\n.endproc\n";
   }
   $body .= <<'ASM';
.segment "CODE.bank1"
remote_data:
   .word $1234
ASM
   my $obj = assemble_case($name, $body);
   require_fail($name, $fragment, link_command($name, $obj));
}

my $bank1_shared = assemble_case('bank1_shared', $preamble . <<'ASM');
.export remote
.export shared_byte
.proc main
   RTS
.endproc
.segment "CODE.bank1"
.proc remote
   LDA shared_byte
   RTS
.endproc
.segment "BSS"
shared_byte:
   .res 1
ASM
require_ok('BANK1 access to shared RAM', link_command('bank1_shared', $bank1_shared));

print "banked relocation classes enforced\n";
