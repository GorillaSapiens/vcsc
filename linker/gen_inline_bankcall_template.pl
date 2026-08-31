#!/usr/bin/env perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
use strict;
use warnings;
use File::Temp qw(tempdir);

@ARGV == 3 || @ARGV == 4 or die "usage: $0 vcsc-as F8/inline_bankcall.s26 output.h [PREFIX]\n";
my ($as, $src, $out, $prefix) = @ARGV;
$prefix //= "GENERIC";
$prefix =~ /^[A-Z][A-Z0-9_]*$/ or die "$0: invalid template prefix '$prefix'\n";
my $macro = "VCSC_${prefix}_BANKCALL";
my $var_prefix = lc($prefix);
$var_prefix = "vcsc_${var_prefix}_bankcall";
my $display_src = $src;
$display_src =~ s{^.*?(libraries/)}{$1};
$display_src =~ s{^.*?(linker/)}{$1};
my $tmp = tempdir(CLEANUP => 1);

sub parse_ihex {
   my ($path) = @_;
   open my $fh, '<', $path or die "$0: $path: $!\n";
   my %byte;
   my $upper = 0;
   while (my $line = <$fh>) {
      chomp $line;
      $line =~ s/\r$//;
      next if $line eq '';
      $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})([0-9A-Fa-f]*)[0-9A-Fa-f]{2}$/
         or die "$0: malformed Intel HEX line in $path: $line\n";
      my ($len, $addr, $type, $data) = (hex($1), hex($2), hex($3), $4);
      length($data) == 2 * $len or die "$0: bad Intel HEX length in $path\n";
      if ($type == 0) {
         for my $i (0 .. $len - 1) {
            $byte{$upper + $addr + $i} = hex(substr($data, 2 * $i, 2));
         }
      }
      elsif ($type == 1) {
         last;
      }
      elsif ($type == 4) {
         $len == 2 or die "$0: bad extended linear address record in $path\n";
         $upper = hex($data) << 16;
      }
      else {
         die "$0: unsupported Intel HEX record type $type in $path\n";
      }
   }
   close $fh;
   return \%byte;
}

sub parse_map {
   my ($path) = @_;
   open my $fh, '<', $path or die "$0: $path: $!\n";
   my %sym;
   while (my $line = <$fh>) {
      if ($line =~ /^\$([0-9A-Fa-f]{8})\s+(\S+)\s*$/) {
         $sym{$2} = hex($1);
      }
   }
   close $fh;
   return \%sym;
}

sub assemble {
   my ($tag, $ptr0, $selector, $source_descriptor) = @_;
   my $hex = "$tmp/$tag.hex";
   my $map = "$tmp/$tag.map";
   my @cmd = ($as,
      '-DVCSC_BANKCALL_PTR0=' . $ptr0,
      '-DVCSC_BANKCALL_SELECTOR_BASE=' . $selector,
      '-DVCSC_BANKCALL_SOURCE_DESCRIPTOR=' . $source_descriptor,
      "--hex=$hex", "--map=$map", $src);
   system(@cmd) == 0 or die "$0: assembler failed: @cmd\n";
   return (parse_ihex($hex), parse_map($map));
}

my $base_ptr = 0x80;
my $base_selector = 0x1F20;
my $base_source_descriptor = 0xF9;
my ($base_bytes, $symbols) = assemble('base', $base_ptr, $base_selector, $base_source_descriptor);
my ($ptr_bytes) = assemble('ptr', 0x90, $base_selector, $base_source_descriptor);
my ($selector_bytes) = assemble('selector', $base_ptr, 0x2E37, $base_source_descriptor);
my ($source_bytes) = assemble('source', $base_ptr, $base_selector, 0xE3);

for my $name (qw(
   __vcsc_generic_bankcall_begin
   __vcsc_generic_bankreturn
   __vcsc_generic_bankcall_switch_and_jump
   __vcsc_generic_bankcall_end
   __vcsc_generic_bankcall_reserved_end
)) {
   exists $symbols->{$name} or die "$0: template map lacks $name\n";
}

my $begin = $symbols->{__vcsc_generic_bankcall_begin};
my $end = $symbols->{__vcsc_generic_bankcall_end};
my $reserved_end = $symbols->{__vcsc_generic_bankcall_reserved_end};
my $return = $symbols->{__vcsc_generic_bankreturn};
my $switch = $symbols->{__vcsc_generic_bankcall_switch_and_jump};
my $size = $end - $begin;
my $reserved = $reserved_end - $begin;
$size > 0 or die "$0: empty template\n";
$reserved >= $size or die "$0: reserved block is smaller than template\n";
$size <= 255 && $reserved <= 255 or die "$0: template sizes exceed one-byte offsets\n";
$return >= $begin + 3 or die "$0: return label cannot follow internal JSR\n";
my $jsr_operand = $return - $begin - 2;

my @bytes;
for my $addr ($begin .. $end - 1) {
   exists $base_bytes->{$addr} or die sprintf("%s: missing template byte at \$%04X\n", $0, $addr);
   push @bytes, $base_bytes->{$addr};
}

my @ptr_patch;
for my $i (0 .. $#bytes) {
   my $addr = $begin + $i;
   my $a = $base_bytes->{$addr};
   my $b = $ptr_bytes->{$addr};
   next if !defined($b) || $a == $b;
   my $delta = $a - $base_ptr;
   ($delta == 0 || $delta == 1)
      or die sprintf("%s: unexpected ptr0-sensitive byte at +\$%02X: \$%02X -> \$%02X\n", $0, $i, $a, $b);
   $b == 0x90 + $delta
      or die sprintf("%s: ptr0-sensitive byte at +\$%02X is not ptr0+%u\n", $0, $i, $delta);
   push @ptr_patch, [$i, $delta];
}
@ptr_patch or die "$0: template has no ptr0 patches\n";

my @selector_diff;
for my $i (0 .. $#bytes) {
   my $addr = $begin + $i;
   my $a = $base_bytes->{$addr};
   my $b = $selector_bytes->{$addr};
   push @selector_diff, $i if defined($b) && $a != $b;
}
my @selector_patch;
while (@selector_diff) {
   my $lo = shift @selector_diff;
   my $hi = shift @selector_diff;
   defined($hi) && $hi == $lo + 1
      or die "$0: selector-base patch is not a contiguous little-endian word\n";
   $bytes[$lo] == ($base_selector & 0xff) && $bytes[$hi] == (($base_selector >> 8) & 0xff)
      or die "$0: selector-base baseline bytes do not match placeholder\n";
   push @selector_patch, $lo;
}



my @source_patch;
for my $i (0 .. $#bytes) {
   my $addr = $begin + $i;
   my $a = $base_bytes->{$addr};
   my $b = $source_bytes->{$addr};
   next if !defined($b) || $a == $b;
   $a == $base_source_descriptor && $b == 0xE3
      or die sprintf("%s: unexpected source-descriptor-sensitive byte at +\$%02X: \$%02X -> \$%02X\n", $0, $i, $a, $b);
   push @source_patch, $i;
}

$bytes[$jsr_operand - 1] == 0x20
   or die sprintf("%s: expected JSR opcode before internal operand at +\$%02X\n", $0, $jsr_operand);
my $assembled_switch = $bytes[$jsr_operand] | ($bytes[$jsr_operand + 1] << 8);
$assembled_switch == $switch
   or die sprintf("%s: internal JSR points to \$%04X, expected switch label \$%04X\n",
                  $0, $assembled_switch, $switch);

open my $ofh, '>', $out or die "$0: $out: $!\n";
print {$ofh} "/* Generated from $display_src.  Do not edit. */\n";
printf {$ofh} "#define %s_TEMPLATE_SIZE 0x%02Xu\n", $macro, $size;
printf {$ofh} "#define %s_RESERVED_SIZE 0x%02Xu\n", $macro, $reserved;
printf {$ofh} "#define %s_SWITCH_OFFSET 0x%02Xu\n", $macro, $switch - $begin;
printf {$ofh} "#define %s_INTERNAL_JSR_OPERAND_OFFSET 0x%02Xu\n", $macro, $jsr_operand;
printf {$ofh} "static const uint8_t %s_template[%s_TEMPLATE_SIZE] = {\n", $var_prefix, $macro;
for (my $i = 0; $i < @bytes; $i += 12) {
   my $last = $i + 11 < $#bytes ? $i + 11 : $#bytes;
   print {$ofh} "   ", join(', ', map { sprintf('0x%02Xu', $bytes[$_]) } $i .. $last);
   print {$ofh} $last == $#bytes ? "\n" : ",\n";
}
print {$ofh} "};\n";
printf {$ofh} "static const uint8_t %s_ptr_patches[][2] = {\n", $var_prefix;
for my $patch (@ptr_patch) {
   printf {$ofh} "   { 0x%02Xu, %uu },\n", $patch->[0], $patch->[1];
}
print {$ofh} "};\n";
printf {$ofh} "#define %s_PTR_PATCH_COUNT %uu\n", $macro, scalar @ptr_patch;
printf {$ofh} "static const uint8_t %s_selector_patches[] = {\n   ", $var_prefix;
print {$ofh} join(', ', map { sprintf('0x%02Xu', $_) } @selector_patch), "\n};\n";
printf {$ofh} "#define %s_SELECTOR_PATCH_COUNT %uu\n", $macro, scalar @selector_patch;
printf {$ofh} "static const uint8_t %s_source_descriptor_patches[] = {\n   ", $var_prefix;
print {$ofh} @source_patch ? join(', ', map { sprintf('0x%02Xu', $_) } @source_patch) : '0x00u';
print {$ofh} "\n};\n";
printf {$ofh} "#define %s_SOURCE_DESCRIPTOR_PATCH_COUNT %uu\n", $macro, scalar @source_patch;
close $ofh or die "$0: could not close $out: $!\n";
