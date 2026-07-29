#!/usr/bin/perl
# runner: perl @FILE@ @REPO@
# phase: e2e
# expectstdout: driver_version_format ok
# expectexit: 0


use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage {
   die "usage: $0 REPO_ROOT\n";
}

sub trim {
   my ($text) = @_;
   $text =~ s/^\s+//;
   $text =~ s/\s+$//;
   return $text;
}

sub slurp_fh {
   my ($fh) = @_;
   local $/;
   my $data = <$fh>;
   return defined($data) ? $data : '';
}

sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   my $stdout = slurp_fh($out);
   my $stderr = slurp_fh($err);
   waitpid($pid, 0);
   my $exit = $? >> 8;
   my $signal = $? & 127;
   return ($exit, $signal, $stdout, $stderr);
}

sub delimiter_colons {
   my ($line) = @_;
   my @positions;
   my $pos = -1;
   while (1) {
      $pos = index($line, ' : ', $pos + 1);
      last if $pos < 0;
      push @positions, $pos + 1;
   }
   return @positions;
}

my $repo = shift @ARGV // usage();
usage() if @ARGV;
$repo = abs_path($repo) // die "could not resolve repo root: $repo\n";

my @expected = (
   [ 'vcsc',  File::Spec->catfile($repo, 'driver', 'vcsc') ],
   [ 'vcsc-cc1',   File::Spec->catfile($repo, 'compiler', 'vcsc-cc1') ],
   [ 'vcsc-as', File::Spec->catfile($repo, 'assembler', 'vcsc-as') ],
   [ 'vcsc-ld',  File::Spec->catfile($repo, 'linker', 'vcsc-ld') ],
   [ 'vcsc-ar',  File::Spec->catfile($repo, 'archiver', 'vcsc-ar') ],
   [ 'vcsc-sim', File::Spec->catfile($repo, 'simulator', 'vcsc-sim') ],
);

for my $entry (@expected) {
   my ($tool, $path) = @$entry;
   my $abs = abs_path($path) // die "$tool path does not exist: $path\n";
   die "$tool path is not executable: $abs\n" if !-x $abs;
   $entry->[1] = $abs;
}

my ($exit, $signal, $stdout, $stderr) = run_capture($expected[0]->[1], '-V');
die "vcsc -V exited $exit signal $signal\n$stderr" if $exit != 0 || $signal != 0;
die "vcsc -V wrote stderr:\n$stderr" if $stderr ne '';
die "vcsc -V output is missing final newline\n" if $stdout !~ /\n\z/;
die "vcsc -V output contains blank lines\n" if $stdout =~ /\n\n/;

chomp(my $text = $stdout);
my @lines = split(/\n/, $text, -1);
die "expected " . scalar(@expected) . " version lines, got " . scalar(@lines) . "\n$stdout" if @lines != @expected;

my ($first_colon, $second_colon);
for my $i (0 .. $#expected) {
   my $line = $lines[$i];
   my @colons = delimiter_colons($line);
   die "line " . ($i + 1) . " should contain exactly two field delimiters: $line\n" if @colons != 2;

   $first_colon //= $colons[0];
   $second_colon //= $colons[1];
   die "first colon is not aligned on line " . ($i + 1) . ": $line\n" if $colons[0] != $first_colon;
   die "path/version colon is not aligned on line " . ($i + 1) . ": $line\n" if $colons[1] != $second_colon;

   my $tool = trim(substr($line, 0, $colons[0]));
   my $path = trim(substr($line, $colons[0] + 1, $colons[1] - $colons[0] - 1));
   my $version = trim(substr($line, $colons[1] + 1));

   die "line " . ($i + 1) . " tool mismatch: got '$tool', expected '$expected[$i]->[0]'\n" if $tool ne $expected[$i]->[0];
   die "$tool path mismatch: got '$path', expected '$expected[$i]->[1]'\n" if $path ne $expected[$i]->[1];
   die "$tool version field is empty\n" if $version eq '';
}

print "driver_version_format ok\n";
