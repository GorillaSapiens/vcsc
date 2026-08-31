#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: exhaustive bankswitch JSR matrix passed
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

sub capture {
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
   my ($exit, $sig, $out, $err) = capture(@cmd);
   $exit == 0 && !$sig
      or die "$label failed: exit=$exit signal=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out, $err);
}

sub map_symbol_addr {
   my ($map, $name) = @_;
   $map =~ /^\s*\$([0-9A-Fa-f]{4})\s+\Q$name\E\b/m
      or die "map missing symbol $name\n";
   return hex($1);
}

sub parse_dump {
   my ($text) = @_;
   my @mem = (0) x 65536;
   for my $line (split /\n/, $text) {
      next unless $line =~ /^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})00([0-9A-Fa-f]*)[0-9A-Fa-f]{2}$/;
      my ($n, $addr, $data) = (hex($1), hex($2), $3);
      for my $i (0 .. $n - 1) {
         $mem[$addr + $i] = hex(substr($data, $i * 2, 2));
      }
   }
   return \@mem;
}

sub generated_source {
   my ($include, $banks, $source) = @_;
   my $text = "// Generated exhaustive ordered JSR/RTS bank-pair regression.\n";
   $text .= qq{include "$include"\n\n};
   $text .= "uint8_t matrix_failure;\nuint8_t matrix_count;\nuint8_t matrix_sp_before;\nuint8_t matrix_sp_after;\n\n";

   for my $bank (0 .. $banks - 1) {
      my $value = 0x80 + $bank;
      $text .= sprintf("bank%d uint8_t matrix_probe%d(void) { matrix_count := matrix_count + 1; return 0x%02X; }\n",
                       $bank, $bank, $value);
   }

   $text .= "\n";
   $text .= sprintf("bank%d void matrix_source(void) {\n", $source);
   $text .= "   matrix_count := 0;\n";
   for my $dest (0 .. $banks - 1) {
      my $value = 0x80 + $dest;
      my $err_value = 1 + $dest;
      my $stack_err = 0x40 + $dest;
      $text .= "   asm tsx; asm stx matrix_sp_before;\n";
      $text .= sprintf("   if (matrix_probe%d() != 0x%02X) { matrix_failure := 0x%02X; }\n",
                       $dest, $value, $err_value);
      $text .= "   asm tsx; asm stx matrix_sp_after;\n";
      $text .= sprintf("   if (matrix_sp_after != matrix_sp_before) { matrix_failure := 0x%02X; }\n",
                       $stack_err);
   }
   $text .= sprintf("   if (matrix_count != %d) { matrix_failure := 0x7E; }\n", $banks);
   $text .= "}\n\n";
   $text .= "bank0 void matrix_done(void) { while (1) { } }\n\n";
   $text .= "bank0 void main(void) {\n";
   $text .= "   matrix_failure := 0;\n";
   $text .= "   matrix_source();\n";
   $text .= "   asm jmp matrix_done;\n";
   $text .= "}\n";
   return $text;
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);

my $vcs = File::Spec->catdir($repo, 'libraries', 'vcs');
my $driver = File::Spec->catfile($repo, 'driver', 'vcsc');
my $sim = File::Spec->catfile($repo, 'simulator', 'vcsc-sim');
my $generic_cfg = File::Spec->catfile($vcs, 'vcs.cfg');

my @profiles = (
   [ 'F8',    'vcs_8k_f8.c26',    'vcs_8k_f8.cfg',    [0x1ff9,0x1ff8] ],
   [ 'F8SC',  'vcs_8k_f8sc.c26',  'vcs_8k_f8sc.cfg',  [0x1ff9,0x1ff8] ],
   [ 'F6',    'vcs_16k_f6.c26',   'vcs_16k_f6.cfg',   [0x1ff9,0x1ff8,0x1ff7,0x1ff6] ],
   [ 'F6SC',  'vcs_16k_f6sc.c26', 'vcs_16k_f6sc.cfg', [0x1ff9,0x1ff8,0x1ff7,0x1ff6] ],
   [ 'F4',    'vcs_32k_f4.c26',   'vcs_32k_f4.cfg',   [0x1ffb,0x1ffa,0x1ff9,0x1ff8,0x1ff7,0x1ff6,0x1ff5,0x1ff4] ],
   [ 'F4SC',  'vcs_32k_f4sc.c26', 'vcs_32k_f4sc.cfg', [0x1ffb,0x1ffa,0x1ff9,0x1ff8,0x1ff7,0x1ff6,0x1ff5,0x1ff4] ],
   [ 'FA',    'vcs_12k_fa.c26',   'vcs_12k_fa.cfg',   [0x1ffa,0x1ff9,0x1ff8] ],
   [ 'FA2-24','vcs_24k_fa2.c26',  'vcs_24k_fa2.cfg',  [0x1ff5,0x1ff6,0x1ff7,0x1ff8,0x1ff9,0x1ffa] ],
   [ 'FA2-28','vcs_28k_fa2.c26',  'vcs_28k_fa2.cfg',  [0x1ff5,0x1ff6,0x1ff7,0x1ff8,0x1ff9,0x1ffa,0x1ffb] ],
   [ 'JANE',  'vcs_16k_jane.c26', 'vcs_16k_jane.cfg', [0x1ff1,0x1ff0,0x1ff8,0x1ff9] ],
   [ '0840',  'vcs_8k_0840.c26',  'vcs_8k_0840.cfg',  [0x0800,0x0840] ],
   [ 'UA',    'vcs_8k_ua.c26',    'vcs_8k_ua.cfg',    [0x0220,0x0240] ],
   [ 'UASW',  'vcs_8k_uasw.c26',  'vcs_8k_uasw.cfg',  [0x0240,0x0220] ],
   [ '0FA0',  'vcs_8k_0fa0.c26',  'vcs_8k_0fa0.cfg',  [0x0fc0,0x0fa0] ],
   [ 'DPC',   'vcs_10k_dpc.c26',  'vcs_10k_dpc.cfg',  [0x1ff9,0x1ff8] ],
);

my $pair_count = 0;
for my $profile (@profiles) {
   my ($name, $include, $cfg_name, $hotspots) = @$profile;
   my $banks = scalar(@$hotspots);
   my $cfg = File::Spec->catfile($vcs, $cfg_name);

   for my $source (0 .. $banks - 1) {
      my $tag = lc($name); $tag =~ s/[^a-z0-9]+/-/g;
      my $src = File::Spec->catfile($tmp, "$tag-source$source.c26");
      my $bin = File::Spec->catfile($tmp, "$tag-source$source.bin");
      my $map_path = File::Spec->catfile($tmp, "$tag-source$source.map");
      open(my $fh, '>:raw', $src) or die "could not write $src: $!\n";
      print {$fh} generated_source($include, $banks, $source);
      close($fh) or die "could not close $src: $!\n";

      require_ok("build $name ordered-call source bank $source",
                 $driver, '-I', $vcs, '-T', $generic_cfg, '-Map', $map_path,
                 $src, '-o', $bin);
      my $map = slurp($map_path);
      my $expected_jsr = ($banks - 1) + ($source == 0 ? 0 : 1);
      $map =~ /entries=\d+\s+jmp=\d+\s+jsr=\Q$expected_jsr\E\b/
         or die "$name source bank $source generated unexpected JSR bridge count (wanted $expected_jsr)\n$map";

      for my $dest (0 .. $banks - 1) {
         next if $dest == $source;
         my $src_hot = sprintf('%04X', $hotspots->[$source]);
         my $dst_hot = sprintf('%04X', $hotspots->[$dest]);
         $map =~ /JSR entry=.*source=BANK\Q$source\E hotspot=\$\Q$src_hot\E destination=BANK\Q$dest\E hotspot=\$\Q$dst_hot\E/im
            or die "$name missing generated ordered JSR bridge BANK$source -> BANK$dest\n$map";
         $pair_count++;
      }

      my $done = map_symbol_addr($map, 'matrix_done');
      my $failure = map_symbol_addr($map, 'matrix_failure');
      my $count = map_symbol_addr($map, 'matrix_count');
      my ($out, $err) = require_ok("simulate $name ordered-call source bank $source",
                                   $sim, '-T', $cfg,
                                   sprintf('--stop-pc=0x%04X', $done), '--dump-on-stop', $bin);
      $err eq '' or die "$name source bank $source simulator stderr:\n$err";
      my $mem = parse_dump($out);
      $mem->[$failure] == 0
         or die sprintf("%s source bank %d ordered-call matrix failed with $%02X\n", $name, $source, $mem->[$failure]);
      $mem->[$count] == $banks
         or die "$name source bank $source executed $mem->[$count] probes, expected $banks\n";
   }
}

$pair_count == 240 or die "ordered call pair accounting changed: got $pair_count expected 240\n";
print "exhaustive bankswitch JSR matrix passed\n";
