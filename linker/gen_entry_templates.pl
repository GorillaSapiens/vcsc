#!/usr/bin/env perl
# This file is covered under CC0-1.0. See libraries/LICENSE.txt.
use strict;
use warnings;
use File::Temp qw(tempdir);

@ARGV >= 3 or die "usage: $0 vcsc-as output.h NAME=mapper/entry.s26 ...\n";
my ($as, $out, @spec) = @ARGV;
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
      elsif ($type == 1) { last; }
      elsif ($type == 4) {
         $len == 2 or die "$0: bad extended linear address record in $path\n";
         $upper = hex($data) << 16;
      }
      else { die "$0: unsupported Intel HEX record type $type in $path\n"; }
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

my @entry;
for my $item (@spec) {
   $item =~ /^([A-Z][A-Z0-9_]*)=(.+)$/ or die "$0: bad entry spec '$item'\n";
   my ($name, $src) = ($1, $2);
   my $hex = "$tmp/$name.hex";
   my $map = "$tmp/$name.map";
   system($as, "--hex=$hex", "--map=$map", $src) == 0
      or die "$0: assembler failed for $src\n";
   my $bytes = parse_ihex($hex);
   my $symbols = parse_map($map);
   exists $symbols->{__vcsc_mapper_entry_begin} && exists $symbols->{__vcsc_mapper_entry_end}
      or die "$0: $src lacks mapper entry begin/end symbols\n";
   my $begin = $symbols->{__vcsc_mapper_entry_begin};
   my $end = $symbols->{__vcsc_mapper_entry_end};
   my $size = $end - $begin;
   $size == 3 or die "$0: $src mapper entry must currently be exactly 3 bytes, got $size\n";
   my @bytes;
   for my $addr ($begin .. $end - 1) {
      exists $bytes->{$addr} or die sprintf("%s: %s missing byte at \$%04X\n", $0, $src, $addr);
      push @bytes, $bytes->{$addr};
   }
   my $display = $src;
   $display =~ s{^.*?(libraries/)}{$1};
   push @entry, [$name, $display, \@bytes];
}

open my $fh, '>', $out or die "$0: $out: $!\n";
print {$fh} "/* Generated mapper reset-entry bytes. Do not edit. */\n";
print {$fh} "#define VCSC_MAPPER_ENTRY_SIZE 3u\n";
for my $e (@entry) {
   my ($name, $src, $bytes) = @$e;
   my $var = lc($name);
   printf {$fh} "/* %s */\n", $src;
   printf {$fh} "static const uint8_t vcsc_%s_entry[VCSC_MAPPER_ENTRY_SIZE] = { %s };\n",
      $var, join(', ', map { sprintf('0x%02Xu', $_) } @$bytes);
}
close $fh or die "$0: close $out: $!\n";
