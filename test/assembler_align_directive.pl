#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: assembler align directive passed
# expectstderrexact:


use strict;
use warnings;
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);

my $repo = shift @ARGV // die "usage: $0 REPO TMP\n";
my $tmp  = shift @ARGV // die "usage: $0 REPO TMP\n";

$repo = abs_path($repo) // die "could not resolve repo root\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $asm = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
-x $asm or die "missing executable assembler: $asm\n";

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>', $path) or die "could not write $path: $!\n";
   print {$fh} $text;
   close($fh);
}

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or return '';
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
}

sub run_asm {
   my ($name, $body) = @_;
   my $src = File::Spec->catfile($tmp, "$name.s26");
   my $hex = File::Spec->catfile($tmp, "$name.hex");
   my $out = File::Spec->catfile($tmp, "$name.out");
   my $err = File::Spec->catfile($tmp, "$name.err");

   write_file($src, $body);

   my @cmd = ($asm, "--hex=$hex", $src);
   my $pid = fork();
   die "fork failed: $!\n" if !defined($pid);
   if ($pid == 0) {
      open(STDOUT, '>', $out) or die "open stdout failed: $!\n";
      open(STDERR, '>', $err) or die "open stderr failed: $!\n";
      exec @cmd;
      die "exec failed: $!\n";
   }

   waitpid($pid, 0);
   return ($? >> 8, slurp($out), slurp($err), $hex, join(' ', @cmd));
}


sub run_tool {
   my ($out, $err, @cmd) = @_;
   my $pid = fork();
   die "fork failed: $!\n" if !defined($pid);
   if ($pid == 0) {
      open(STDOUT, '>', $out) or die "open stdout failed: $!\n";
      open(STDERR, '>', $err) or die "open stderr failed: $!\n";
      exec @cmd;
      die "exec failed: $!\n";
   }
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, slurp($out), slurp($err));
}

sub parse_ihex {
   my ($path) = @_;
   my %mem;
   open(my $fh, '<', $path) or die "could not open $path: $!\n";
   while (my $line = <$fh>) {
      chomp $line;
      next if $line eq '';
      die "bad ihex line: $line\n" if $line !~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})([0-9A-Fa-f]*)([0-9A-Fa-f]{2})$/;
      my ($len_hex, $addr_hex, $type_hex, $data_hex) = ($1, $2, $3, $4);
      my $len = hex($len_hex);
      my $addr = hex($addr_hex);
      my $type = hex($type_hex);
      next if $type == 1;
      die "unsupported ihex record type $type\n" if $type != 0;
      die "bad ihex data length\n" if length($data_hex) != $len * 2;
      for my $i (0 .. $len - 1) {
         $mem{$addr + $i} = hex(substr($data_hex, $i * 2, 2));
      }
   }
   close($fh);
   return \%mem;
}

my ($exit, undef, $err, $hex, $cmd) = run_asm('align_good', <<'ASM');
.segmentdef "CODE", $8000, $0200
.segment "CODE"
.byte $AA
.align 4
middle:
.byte $BB
.word middle
.align 1
.byte $CC
.align 16, 5, $EA
offset_label:
.byte $DD
.word offset_label
ASM

if ($exit != 0) {
   die "align_good failed, exit $exit\n$cmd\n$err";
}

my $mem = parse_ihex($hex);
my @expect = (
   [ 0x8000, 0xAA ],
   [ 0x8001, 0x00 ],
   [ 0x8002, 0x00 ],
   [ 0x8003, 0x00 ],
   [ 0x8004, 0xBB ],
   [ 0x8005, 0x04 ],
   [ 0x8006, 0x80 ],
   [ 0x8007, 0xCC ],
   [ 0x8008, 0xEA ], [ 0x8009, 0xEA ], [ 0x800A, 0xEA ],
   [ 0x800B, 0xEA ], [ 0x800C, 0xEA ], [ 0x800D, 0xEA ],
   [ 0x800E, 0xEA ], [ 0x800F, 0xEA ], [ 0x8010, 0xEA ],
   [ 0x8011, 0xEA ], [ 0x8012, 0xEA ], [ 0x8013, 0xEA ],
   [ 0x8014, 0xEA ],
   [ 0x8015, 0xDD ], [ 0x8016, 0x15 ], [ 0x8017, 0x80 ],
);

for my $pair (@expect) {
   my ($addr, $want) = @$pair;
   my $got = $mem->{$addr};
   die sprintf("address %04X missing\n", $addr) if !defined($got);
   die sprintf("address %04X got %02X expected %02X\n", $addr, $got, $want) if $got != $want;
}

# Exercise the separate relocatable-object writer as well as direct image output.
my $ld = File::Spec->catfile($repo, 'linker', 'vcsc-ld');
my $cfg = File::Spec->catfile($repo, 'test', 'generic_6502.cfg');
my $obj_src = File::Spec->catfile($tmp, 'align_fill_o26.s26');
my $obj = File::Spec->catfile($tmp, 'align_fill_o26.o26');
my $bin = File::Spec->catfile($tmp, 'align_fill_o26.bin');
my $obj_out = File::Spec->catfile($tmp, 'align_fill_o26.out');
my $obj_err = File::Spec->catfile($tmp, 'align_fill_o26.err');
my $link_out = File::Spec->catfile($tmp, 'align_fill_link.out');
my $link_err = File::Spec->catfile($tmp, 'align_fill_link.err');
my $link_map = File::Spec->catfile($tmp, 'align_fill_o26.map');
my $offset_cfg = File::Spec->catfile($tmp, 'align_offset.cfg');
write_file($offset_cfg, slurp($cfg) =~ s/start = \$2000, size = \$E000/start = \$2003, size = \$DFFD/r);
write_file($obj_src, <<'ASM');
.segment "CODE"
.export __reset
.export __nmi
.export __irq
.export __irqbrk
.export aligned_label
.export aligned_label2
__nmi:
__irq:
__irqbrk:
__reset:
.byte $11
.align 16, 5, $EA
aligned_label:
.byte $22
.byte $33
.align 16, 9, $EB
aligned_label2:
.byte $44
ASM
my ($obj_exit, $obj_sig, undef, $obj_stderr) = run_tool($obj_out, $obj_err, $asm, '-o', $obj, $obj_src);
$obj_exit == 0 && !$obj_sig or die "fill-byte o26 assembly failed\n$obj_stderr";
my ($link_exit, $link_sig, undef, $link_stderr) = run_tool($link_out, $link_err, $ld, '-T', $offset_cfg, '-Map', $link_map, '-o', $bin, $obj);
$link_exit == 0 && !$link_sig or die "fill-byte o26 link failed\n$link_stderr";
my $linked = slurp($bin);
# The linker may choose a nonzero component-base phase; what .align promises is
# that the aligned *locations* are absolute after linking.  Here phase $4 makes
# the first alignment require no padding, while the second still emits two $EB
# bytes.  This proves both absolute placement and preservation of emitted fill.
substr($linked, 0, 6) eq pack('C*', 0x11, 0x22, 0x33, 0xEB, 0xEB, 0x44)
   or die "o26 absolute alignment/fill did not survive linking\n";
my $linked_map = slurp($link_map);
$linked_map =~ /^\s+CODE\s+load=\$2004\s+size=\$0006\s+page=preferred\s+component-align=\$0010\s+component-phase=\$0004$/m
   or die "o26 .align 16 did not carry its final-link base phase\n$linked_map";
$linked_map =~ /^\s+\$2005\s+aligned_label\b/m
   or die "o26 .align 16,5 did not land at absolute residue 5\n$linked_map";
$linked_map =~ /^\s+\$2009\s+aligned_label2\b/m
   or die "second o26 .align 16,9 did not land at absolute residue 9\n$linked_map";


# Direct images can align to any positive boundary because their final address is
# already known.  Relocatable o26 output must be able to carry the absolute
# contract through the linker, whose component-alignment metadata is power-of-two.
my $nonpow_src = File::Spec->catfile($tmp, 'align_nonpower_o26.s26');
my $nonpow_obj = File::Spec->catfile($tmp, 'align_nonpower_o26.o26');
my $nonpow_out = File::Spec->catfile($tmp, 'align_nonpower_o26.out');
my $nonpow_err = File::Spec->catfile($tmp, 'align_nonpower_o26.err');
write_file($nonpow_src, qq{.segment "CODE"\n.align 3\n.byte \$11\n});
my ($nonpow_exit, $nonpow_sig, undef, $nonpow_stderr) =
   run_tool($nonpow_out, $nonpow_err, $asm, '-o', $nonpow_obj, $nonpow_src);
$nonpow_exit != 0 && !$nonpow_sig
   or die "non-power-of-two o26 .align unexpectedly assembled\n";
index($nonpow_stderr, '.align boundary in o26 output must be a power of two') >= 0
   or die "non-power-of-two o26 .align diagnostic missing\n$nonpow_stderr";

my @bad = (
   [ align_zero => ".align 0\n", '.align requires a positive boundary' ],
   [ align_extra_arg => ".align 4, 0, 1, 2\n", '.align expects one, two, or three expressions' ],
   [ align_negative_offset => ".align 4, -1\n", '.align offset must be from zero through boundary minus one' ],
   [ align_large_offset => ".align 4, 4\n", '.align offset must be from zero through boundary minus one' ],
   [ align_negative_fill => ".align 4, 0, -1\n", '.align fill byte must be from zero through 255' ],
   [ align_large_fill => ".align 4, 0, 256\n", '.align fill byte must be from zero through 255' ],
);

for my $case (@bad) {
   my ($name, $body, $needle) = @$case;
   my ($bad_exit, undef, $bad_err, undef, $bad_cmd) = run_asm($name, $body);
   if ($bad_exit == 0) {
      die "$name unexpectedly assembled\n$bad_cmd\n";
   }
   if (index($bad_err, $needle) < 0) {
      die "$name stderr missing '$needle'\n$bad_cmd\nstderr:\n$bad_err";
   }
}

print "assembler align directive passed\n";
exit 0;
