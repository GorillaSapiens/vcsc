#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: host_string_const ok
# expectexit: 0
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use Text::ParseWords qw(shellwords);

my ($repo, $tmp) = @ARGV;
$repo = abs_path($repo);
make_path($tmp);
$tmp = abs_path($tmp);
my @cc = shellwords($ENV{CC} || 'cc');
my @flags = ('-std=gnu11', '-Wall', '-Wextra', '-Werror', '-pedantic',
             '-include', "$repo/test/fixtures/host_string_const.h", '-fsyntax-only');

sub compile {
   my ($file) = @_;
   # A file avoids pipe deadlocks when one translation unit has many errors.
   open my $saved, '>&', \*STDERR or die $!;
   open STDERR, '>', "$tmp/diagnostics" or die $!;
   my $status = system(@cc, @flags, $file);
   open STDERR, '>&', $saved or die $!;
   close $saved;
   open my $fh, '<', "$tmp/diagnostics" or die $!;
   local $/;
   my $diagnostics = <$fh> // '';
   return ($status, $diagnostics);
}

# Prove the injected signatures reject const discards for every function,
# independent of the host compiler's default language/library version.
for my $call ('strchr(s, 44)', 'strrchr(s, 44)', 'strstr(s, ",")',
              'strpbrk(s, ",")', 'memchr(s, 44, 3)') {
   for my $declaration ('char *p =', 'char *p; p =') {
      open my $fh, '>', "$tmp/bad.c" or die $!;
      print {$fh} "int main(void) { const char *s = \"a,b\"; $declaration $call; return p != 0; }\n";
      close $fh or die $!;
      my ($status, $diagnostics) = compile("$tmp/bad.c");
      $status && $diagnostics =~ /const|qualifier/i
         or die "const-discard negative control did not fail correctly: $call\n$diagnostics";
   }
   open my $fh, '>', "$tmp/mutable.c" or die $!;
   print {$fh} "int main(void) { char s[] = \"a,b\"; char *p = $call; if (p) *p = 0; return 0; }\n";
   close $fh or die $!;
   my ($status, $diagnostics) = compile("$tmp/mutable.c");
   $status == 0 or die "mutable search result must remain writable: $call\n$diagnostics";
}

# Check full translation units, not declaration-shaped regexes: this includes
# assignments to earlier-declared pointers, headers, and generated lexer/parser
# code. Normal `make tools` supplies all generated build prerequisites.
my @units;
for my $dir (qw(assembler archiver compiler linker driver disassembler)) {
   push @units, sort glob("$repo/$dir/*.c");
}
@units or die "no host C translation units found\n";
my @failures;
for my $unit (@units) {
   my ($status, $diagnostics) = compile($unit);
   push @failures, "$unit failed const-propagating string checks:\n$diagnostics" if $status;
}
die join("\n", @failures) if @failures;
print "host_string_const ok\n";
