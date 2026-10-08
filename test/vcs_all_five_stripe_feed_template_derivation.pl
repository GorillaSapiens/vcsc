#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_all_five_stripe_feed_template_derivation ok
# expectexit: 0

# The generic stripe renderer derives its three feed tables from the public
# eight-byte-per-stripe record, and the record is declared by the EXAMPLE while the
# feed is declared by the COMPONENT.  Those are separate compilation units joined by
# `instantiate`.
#
# That boundary is the load-bearing risk in the whole feed design, and nothing pinned
# it.  The tables being link-time data is what makes the design work at all: the feed
# is 288 bytes, and cartridge RAM has 25 bytes free against 103 used.  So if a
# component cannot derive a page-contained, zero-RAM table from a record bound across
# an instantiate boundary, the entire generic machine is blocked -- and the failure
# would not surface until deep inside renderer work, after a great deal of it.
#
# So this proves the capability on its own, in miniature:
#
#   * the record is `const` in the example's unit, and is read by CONSTANT INDEX in
#     the component's unit, which is exactly what the real feed does;
#   * the index order is a PERMUTATION, because the real feed transposes rather than
#     copying, and a copy would not exercise the same path;
#   * one slot is a literal zero, because the real feed's spare slots are;
#   * the derived table is page contained, because every read of it is a fixed
#     four-cycle abs,Y and the six-line machine has no slack;
#   * and it costs NO RAM, which is the entire reason for deriving it rather than
#     computing it into RAM at startup.
#
# The negative case matters as much as the positive one and is asserted too: the same
# derivation from a record that is NOT const must NOT fold, because then it would need
# RAM and a startup copy.  A check that only ever saw the good case could not tell a
# working fold from an accidental one.

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n" }
@ARGV == 2 or usage();
my ($repo, $tmp) = @ARGV;
make_path($tmp);

my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $vcs    = File::Spec->catdir($repo, 'libraries', 'vcs');
-f $driver or die "driver not built at $driver\n";

sub capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   my $so = do { local $/; <$out> };
   my $se = do { local $/; <$err> };
   waitpid($pid, 0);
   $so = '' unless defined $so;
   $se = '' unless defined $se;
   return ($? >> 8, $? & 127, $so, $se);
}

# Scratch goes in the caller-supplied tmp, never the shared system temporary
# directory, because concurrent runs from separate checkouts are normal here.
my $comp = File::Spec->catfile($tmp, 'feed_derivation_component.c26');

# Two components, identical but for the const-ness of the record binding.  The split is
# necessary rather than cosmetic: a non-const record conflicts with a `const` extern,
# and the compiler is right to say so, so the negative case cannot reuse the positive
# case's component.
sub write_component {
   my ($name, $extern) = @_;
   my $path = File::Spec->catfile($tmp, "$name.c26");
   open(my $fh, '>', $path) or die "could not write $path: $!\n";
   print {$fh} <<"COMP";
// Probe component.  The record is bound by the example under this name; the derived
// table is read by constant index, in a permuted order, with a literal spare slot --
// the three things the real feed depends on.
parameter tag := 0;
$extern uint8_t TEMPLATE_playfield_data[4];
page const uint8_t deriv[4] := {
   TEMPLATE_playfield_data[3], TEMPLATE_playfield_data[1],
   TEMPLATE_playfield_data[0], 0
};
void TEMPLATE_main(void) { }
COMP
   close($fh);
   return $name;
}

my $comp_const = write_component('feed_derivation_const_component', 'extern const');
my $comp_plain = write_component('feed_derivation_plain_component', 'extern');


sub build_and_read {
   my ($name, $component, $record_decl) = @_;
   my $ex = File::Spec->catfile($tmp, "$name.c26");
   my $mapfile = File::Spec->catfile($tmp, "$name.map");
   my $binfile = File::Spec->catfile($tmp, "$name.bin");
   open(my $f, '>', $ex) or die "could not write $ex: $!\n";
   print {$f} <<"EX";
include "vcs.c26"
$record_decl
instantiate "$component.c26" as game (tag:=0)
void main(void) { VBLANK := 2; game_main(); while (1) { } }
EX
   close($f);

   my ($rc, $sig, $out, $err) =
      capture($driver, '-I', $vcs, '-Map', $mapfile, $ex, '-o', $binfile);
   ($rc == 0 && !$sig) or die "$name build failed\n$out$err";
   my $map = do { open(my $m, '<', $mapfile) or die "no map for $name\n"; local $/; <$m> };
   my $rom = do { open(my $b, '<', $binfile) or die "no binary for $name\n"; local $/; <$b> };
   length($rom) == 4096 or die "$name did not produce a 4K cartridge\n";
   return ($map, $rom, $out);
}

my $REC_CONST = "const uint8_t game_playfield_data[4] := { 0x11, 0x22, 0x33, 0x44 };";
my $REC_PLAIN = "uint8_t game_playfield_data[4] := { 0x11, 0x22, 0x33, 0x44 };";

# --- the positive case: a const record folds across the instantiate boundary ------
{
   my ($map, $rom, $log) = build_and_read('feed_derivation_const', $comp_const, $REC_CONST);

   my ($addr, $size, $rest) =
      $map =~ /^\s+RODATA\.__vcsc_object\$deriv\s+load=\$([0-9A-Fa-f]+)\s+size=\$([0-9A-Fa-f]+)(.*)$/m;
   defined $addr or die "deriv is not in RODATA; a link-time derivation is what keeps"
                      . " the feed out of RAM\n";
   hex($size) == 4 or die "deriv is $size bytes, expected 4\n";
   $rest =~ /page=hard/
      or die "deriv is not page contained; every read of it is a fixed four-cycle"
            . " abs,Y and a straddling table costs a cycle the machine does not have\n";

   my @got = unpack('C*', substr($rom, hex($addr) - 0xf000, hex($size)));
   # Spelled out one slot at a time, so a failure names the slot and the record index
   # it should have come from.
   $got[0] == 0x44 or die sprintf("deriv slot 0 holds 0x%02x, expected 0x44 (record index 3)\n", $got[0]);
   $got[1] == 0x22 or die sprintf("deriv slot 1 holds 0x%02x, expected 0x22 (record index 1)\n", $got[1]);
   $got[2] == 0x11 or die sprintf("deriv slot 2 holds 0x%02x, expected 0x11 (record index 0)\n", $got[2]);
   $got[3] == 0x00 or die sprintf("deriv slot 3 holds 0x%02x, expected 0x00 (the spare slot)\n", $got[3]);

   # The point of deriving rather than computing: no RAM, and no startup copy.
   $map !~ /deriv.*\.bss/m
      or die "deriv reached BSS; it must be link-time ROM\n";
   # RAM usage is reported by the driver's build log, not the map.
   my ($ram) = $log =~ /ram\s+used=(\d+)\s+bytes/m;
   defined $ram
      or die "could not read RAM usage from the build log\n$log\n";
   # 2 bytes is the hardware stack the language reserves; a four-byte object would
   # push this to 6.  Allow the stack and nothing else.
   $ram <= 2
      or die "deriv cost RAM: ram used=$ram bytes, expected at most 2 (the hardware"
            . " stack), so the derivation did not fold\n";
}

# --- the negative case: a non-const record must NOT fold -------------------------
# Same source shape, record not const.  Now the value is not known at link time, so
# the table has to be computed into RAM at startup -- and the check is that it no
# longer claims to be free.  If this folded, the fold would be reading something other
# than the record, and the positive case would be proving nothing.
#
# The cost is worth stating, because it is the whole reason the record is const in the
# real design: this four-byte table costs 20 bytes of RAM (22 used, against 2 for the
# hardware stack alone).  Scaled to the real 288-byte feed it would not fit at all --
# the cartridge has 25 bytes free against 103 used.
{
   my ($map, $rom, $log) = build_and_read('feed_derivation_plain', $comp_plain, $REC_PLAIN);
   $map =~ /^\s+BSS\.__vcsc_object\$deriv\b/m
      or die "a derivation from a record that is NOT const still landed in link-time"
            . " ROM; the fold must depend on the record being a compile-time constant,"
            . " or the positive case is not proving what it claims\n";
   my ($ram) = $log =~ /ram\s+used=(\d+)\s+bytes/m;
   defined $ram
      or die "could not read RAM usage from the build log\n$log\n";
   $ram > 2
      or die "the non-const record still cost no RAM beyond the hardware stack, so the"
            . " runtime path was not taken and the negative case proves nothing\n";
}

print "vcs_all_five_stripe_feed_template_derivation ok\n";
exit 0;
