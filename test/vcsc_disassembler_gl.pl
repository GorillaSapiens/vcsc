#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcsc-disassembler GL ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path remove_tree);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

my $repo = abs_path($ARGV[0] // die "missing repo\n");
my $tmp = $ARGV[1] // die "missing temp directory\n";
make_path($tmp) if !-d $tmp;

my $disas = File::Spec->catfile($repo, 'disassembler', 'vcsc-disas');
my $roundtrip = File::Spec->catfile($repo, 'disassembler', 'roundtrip.pl');
my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
-x $disas or die "missing $disas\n";
-f $roundtrip or die "missing $roundtrip\n";
-x $as or die "missing $as\n";

sub write_raw {
   my ($path, $data) = @_;
   open(my $fh, '>:raw', $path) or die "write $path: $!\n";
   print {$fh} $data or die "write $path: $!\n";
   close($fh) or die "close $path: $!\n";
}
sub slurp {
   my ($path) = @_;
   open(my $fh, '<:raw', $path) or die "read $path: $!\n";
   local $/;
   my $data = <$fh>;
   close($fh);
   return defined($data) ? $data : '';
}
sub put16 {
   my ($sref, $off, $value) = @_;
   substr($$sref, $off, 2, pack('v', $value));
}
sub capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out>;
   my $stderr = <$err>;
   $stdout = '' if !defined($stdout);
   $stderr = '' if !defined($stderr);
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub require_re {
   my ($text, $re, $what) = @_;
   $text =~ $re or die "missing $what\n";
}
sub reject_re {
   my ($text, $re, $what) = @_;
   $text !~ $re or die "unexpected $what\n";
}

my $in = File::Spec->catdir($tmp, 'gl-in');
my $out = File::Spec->catdir($tmp, 'gl-out');
remove_tree($in, $out);
make_path($in, $out);

# Four independently selected 1K ROM windows.  GameLine powers up with ROM
# bank 0 mirrored into all four runtime windows, so RESET comes from bank 0's
# $FC00 view.  Each selector is a low-address RIOT-RAM mirror cycle snooped by
# the cartridge; the returned byte is unspecified rather than cartridge ROM or
# trustworthy RIOT data.
my $gl4 = chr(0x02) x 4096;
substr($gl4, 0x000, 9, pack('C*',
   0xAD,0xB8,0x0C,                 # LDA $0CB8 -- established GL detector
   0xAD,0x81,0x04,                 # segment 0 -> ROM bank 1
   0x4C,0x00,0xF0));               # JMP $F000
substr($gl4, 0x400, 6, pack('C*',
   0xAD,0x82,0x05,                 # segment 1 -> ROM bank 2
   0x4C,0x00,0xF4));               # JMP $F400
substr($gl4, 0x800, 6, pack('C*',
   0xAD,0x83,0x08,                 # segment 2 -> ROM bank 3
   0x4C,0x00,0xF8));               # JMP $F800
substr($gl4, 0xC00, 6, pack('C*',
   0xAD,0x80,0x09,                 # segment 3 -> ROM bank 0
   0x4C,0x20,0xFC));               # JMP $FC20
substr($gl4, 0x020, 7, pack('C*',
   0xAD,0xA4,0x04,                 # segment 0 -> RAM bank 0, write selector
   0xAD,0x80,0x04,                 # segment 0 -> ROM bank 0
   0x60));                          # RTS
put16(\$gl4, 0x3FA, 0xFC00);
put16(\$gl4, 0x3FC, 0xFC00);
put16(\$gl4, 0x3FE, 0xFC00);
write_raw(File::Spec->catfile($in, 'gl4.bin'), $gl4);

# Pin the distinction between an intercepted selector *read* and a normal
# console write to the same mirror family.  LDA $0481 changes GL segment 0 and
# returns an unknown value.  STA $0981 is only a RIOT-RAM-mirror write; it must
# NOT switch segment 3.  If writes were incorrectly treated as GL selectors,
# the following opcode fetch would move to JAM-filled physical ROM bank 1.
my $gl_intercept = chr(0x02) x 4096;
substr($gl_intercept, 0x000, 14, pack('C*',
   0xAD,0xB8,0x0C,                 # GL detector / intercepted control read
   0xAD,0x81,0x04,                 # intercepted read: seg0 -> ROM bank 1
   0xA9,0x00,
   0x8D,0x81,0x09,                 # STA $0981: RIOT mirror write, NOT selector
   0xA9,0x42,                      # must remain in reset segment / bank 0
   0x60));
put16(\$gl_intercept, 0x3FA, 0xFC00);
put16(\$gl_intercept, 0x3FC, 0xFC00);
put16(\$gl_intercept, 0x3FE, 0xFC00);
write_raw(File::Spec->catfile($in, 'gl-intercept.bin'), $gl_intercept);

# Stella's 6K GameLine save/download form is 4K ROM followed by a 2K initial
# RAM image.  Static flow stops when segment 0 becomes RAM; concrete RESET
# discovery executes the seeded RAM instruction, which selects ROM bank 1 for
# the *next* opcode fetch at $F003.  This proves the RAM seed affects execution
# without ever pretending the trailing file bytes are ROM.
my $gl6 = chr(0x02) x 6144;
substr($gl6, 0x000, 9, pack('C*',
   0xAD,0xB8,0x0C,
   0xAD,0x84,0x04,                 # segment 0 -> RAM bank 0 (read selector)
   0x4C,0x00,0xF0));               # enter seeded cartridge RAM
substr($gl6, 0x403, 5, pack('C*',
   0xA9,0x77,                      # fetched after RAM executes LDA $0481
   0x85,0x84,
   0x60));
put16(\$gl6, 0x3FA, 0xFC00);
put16(\$gl6, 0x3FC, 0xFC00);
put16(\$gl6, 0x3FE, 0xFC00);
substr($gl6, 4096, 2048, chr(0xEA) x 2048);
substr($gl6, 4096, 3, pack('C*',0xAD,0x81,0x04)); # RAM: select seg0 ROM bank1
write_raw(File::Spec->catfile($in, 'gl6-seeded.bin'), $gl6);


# GL's mapper context must retain RAM direction, not just the low-nibble bank
# number.  Both arms select RAM bank 0 in segment 0 and ROM bank 1 in segment 1,
# but one uses read mode and the other write mode.  They then converge on the
# same physical/runtime instruction with different known nonzero A values.  If
# bit 5 is dropped from mapper context, those abstract states merge, A becomes
# unknown, and the impossible BEQ target is falsely promoted as code.
my $gl_direction = chr(0x02) x 4096;
substr($gl_direction, 0x000, 33, pack('C*',
   0xAD,0xB8,0x0C,                 # GL detector; also enables PROM
   0xAD,0x80,0x0C,                 # disable PROM so the fixture isolates direction
   0xAD,0x80,0x02,                 # LDA SWCHA -- unknown statically
   0x30,0x0B,                      # BMI $FC16
   0xAD,0x84,0x04,                 # seg0 -> RAM bank 0, read mode
   0xAD,0x81,0x05,                 # seg1 -> ROM bank 1
   0xA9,0x01,
   0x4C,0x00,0xF4,                 # JMP shared bank-1 code
   0xAD,0xA4,0x04,                 # seg0 -> RAM bank 0, write mode
   0xAD,0x81,0x05,                 # seg1 -> ROM bank 1
   0xA9,0x02,
   0x4C,0x00,0xF4));               # JMP shared bank-1 code
substr($gl_direction, 0x400, 9, pack('C*',
   0xC9,0x00,                      # CMP #0 -- Z is false in both contexts
   0xF0,0x02,                      # impossible BEQ $F406
   0x60,                           # RTS
   0x02,                           # filler
   0xA9,0xEE,0x60));               # must remain raw, never reachable code
put16(\$gl_direction, 0x3FA, 0xFC00);
put16(\$gl_direction, 0x3FC, 0xFC00);
put16(\$gl_direction, 0x3FE, 0xFC00);
write_raw(File::Spec->catfile($in, 'gl-direction.bin'), $gl_direction);

# $0C80-page reads control the 32-byte PROM overlay.  With PROM enabled, a jump
# to $FFC0 must not be decoded from the selected ROM bank.  A second fixture
# disables the overlay before the same jump and proves ordinary ROM mapping is
# restored.  Both still round-trip byte-for-byte.
my $gl_prom_on = chr(0x02) x 4096;
substr($gl_prom_on, 0x000, 6, pack('C*',
   0xAD,0xB8,0x0C,                 # enable PROM ($0CB8 has bits 4+5 set)
   0x4C,0xC0,0xFF));               # JMP into overlaid $1FC0
substr($gl_prom_on, 0x3C0, 3, pack('C*',0xA9,0xE1,0x60));
put16(\$gl_prom_on, 0x3FA, 0xFC00);
put16(\$gl_prom_on, 0x3FC, 0xFC00);
put16(\$gl_prom_on, 0x3FE, 0xFC00);
write_raw(File::Spec->catfile($in, 'gl-prom-on.bin'), $gl_prom_on);

my $gl_prom_off = chr(0x02) x 4096;
substr($gl_prom_off, 0x000, 9, pack('C*',
   0xAD,0xB8,0x0C,                 # enable PROM
   0xAD,0x80,0x0C,                 # disable PROM
   0x4C,0xC0,0xFF));               # selected ROM is visible again
substr($gl_prom_off, 0x3C0, 3, pack('C*',0xA9,0xE2,0x60));
put16(\$gl_prom_off, 0x3FA, 0xFC00);
put16(\$gl_prom_off, 0x3FC, 0xFC00);
put16(\$gl_prom_off, 0x3FE, 0xFC00);
write_raw(File::Spec->catfile($in, 'gl-prom-off.bin'), $gl_prom_off);

my ($rrc, $rsig, $rout, $rerr) = capture($^X, $roundtrip, $in, $out);
$rrc == 0 && $rsig == 0
   or die "GL round trip failed\nstdout:\n$rout\nstderr:\n$rerr";
$rerr eq '' or die "GL round trip wrote stderr:\n$rerr";
$rout =~ /Summary:\s+6 passed, 0 failed, 6 total\n\z/
   or die "unexpected GL round-trip summary:\n$rout";

my $src4 = slurp(File::Spec->catfile($out, 'gl4.s26'));
require_re($src4, qr/^; mapper: GL \(/m, 'GL mapper header');
require_re($src4, qr/GL segments: four independently selected 1K cartridge windows/, 'GL segment description');
require_re($src4, qr/GL intercepted low-address reads have an unspecified\/open-bus-like return value/, 'GL console-bus semantics');
require_re($src4, qr/LDA \$0481\s+; GameLine read snoop: RIOT RAM mirror address; return value unknown; segment 0 -> ROM bank 1/, 'segment-0 selector comment');
require_re($src4, qr/LDA \$0582\s+; GameLine read snoop: RIOT RAM mirror address; return value unknown; segment 1 -> ROM bank 2/, 'segment-1 selector comment');
require_re($src4, qr/LDA \$0883\s+; GameLine read snoop: RIOT RAM mirror address; return value unknown; segment 2 -> ROM bank 3/, 'segment-2 selector comment');
require_re($src4, qr/LDA \$0980\s+; GameLine read snoop: RIOT RAM mirror address; return value unknown; segment 3 -> ROM bank 0/, 'segment-3 selector comment');
require_re($src4, qr/LDA \$04A4\s+; GameLine read snoop: RIOT RAM mirror address; return value unknown; segment 0 -> RAM bank 0 \(write mode\)/, 'GL RAM write-mode selector comment');

my $src_intercept = slurp(File::Spec->catfile($out, 'gl-intercept.s26'));
require_re($src_intercept, qr/^; mapper: GL \(high confidence; 1 decoded hotspot access,/m,
           'only GL selector reads count as hotspots');
require_re($src_intercept,
           qr/LDA \$0481\s+; GameLine read snoop: RIOT RAM mirror address; return value unknown; segment 0 -> ROM bank 1/,
           'intercepted GL selector read');
require_re($src_intercept, qr/^\s+STA \$0981\s*$/m,
           'ordinary RIOT mirror write at a selector-looking address');
require_re($src_intercept, qr/^\s+LDA #\$42\s*$/m,
           'store to GL mirror family did not bankswitch segment 3');
reject_re($src_intercept, qr/STA \$0981.*GameLine/m,
          'write incorrectly annotated as a GameLine selector');

my $src6 = slurp(File::Spec->catfile($out, 'gl6-seeded.s26'));
require_re($src6, qr/GL 6K preservation form: file \$1000-\$17FF is the 2K initial-RAM image/, 'GL 6K header');
require_re($src6, qr/concrete RESET discovery:.*ROM-starts=5/, 'GL seeded-RAM concrete discovery');
require_re($src6, qr/^\s+LDA #\$77\s*$/m, 'ROM continuation reached through seeded GL RAM');
require_re($src6, qr/; ---- GameLine initial 2K RAM image ----\n.*?\.org \$1000\n/s, 'raw GL initial-RAM image');


my $src_direction = slurp(File::Spec->catfile($out, 'gl-direction.s26'));
require_re($src_direction,
           qr/LDA \$0484\s+; GameLine read snoop: RIOT RAM mirror address; return value unknown; segment 0 -> RAM bank 0 \(read mode\)/,
           'GL RAM read-mode selector');
require_re($src_direction,
           qr/LDA \$04A4\s+; GameLine read snoop: RIOT RAM mirror address; return value unknown; segment 0 -> RAM bank 0 \(write mode\)/,
           'GL RAM write-mode selector');
require_re($src_direction, qr/^\s+CMP #\$00\s*$/m,
           'shared GL context code');
reject_re($src_direction, qr/^\s+LDA #\$EE\s*$/m,
          'impossible branch created by merging opposite GL RAM directions');
require_re($src_direction, qr/\.byte \$02, \$A9, \$EE, \$60/,
           'unreachable GL direction-merge branch remains raw');

my $src_prom_on = slurp(File::Spec->catfile($out, 'gl-prom-on.s26'));
require_re($src_prom_on,
           qr/LDA \$0CB8\s+; GameLine control read: return value unknown; PROM overlay \$1FC0-\$1FDF enabled/,
           'GL PROM enable annotation');
require_re($src_prom_on, qr/^\s+JMP \$FFC0\s*$/m,
           'GL PROM-overlay jump stays unresolved ROM');
reject_re($src_prom_on, qr/^\s+LDA #\$E1\s*$/m,
          'ROM bytes decoded through enabled GL PROM overlay');

my $src_prom_off = slurp(File::Spec->catfile($out, 'gl-prom-off.s26'));
require_re($src_prom_off,
           qr/LDA \$0C80\s+; GameLine control read: return value unknown; PROM overlay \$1FC0-\$1FDF disabled/,
           'GL PROM disable annotation');
require_re($src_prom_off, qr/^\s+LDA #\$E2\s*$/m,
           'GL ROM mapping restored after PROM disable');

print "vcsc-disassembler GL ok\n";
