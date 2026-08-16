#!/usr/bin/perl
# runner: perl @FILE@ @REPO@

use strict;
use warnings;
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

my $repo = shift @ARGV;
die "usage: $0 REPO\n" unless defined $repo && -d $repo && !@ARGV;

sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close $in;
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   close $out;
   close $err;
   waitpid($pid, 0);
   return ($? >> 8, $stdout, $stderr);
}

my @tools = (
   File::Spec->catfile($repo, 'driver',    'vcsc'),
   File::Spec->catfile($repo, 'compiler',  'vcsc-cc1'),
   File::Spec->catfile($repo, 'assembler', 'vcsc-as'),
   File::Spec->catfile($repo, 'linker',    'vcsc-ld'),
   File::Spec->catfile($repo, 'archiver',  'vcsc-ar'),
   File::Spec->catfile($repo, 'simulator', 'vcsc-sim'),
   File::Spec->catfile($repo, 'disassembler', 'vcsc-disas'),
);

my $bad = '--definitely-not-a-vcsc-option';

for my $tool (@tools) {
   -x $tool or die "missing executable tool: $tool\n";

   my ($rc, $stdout, $stderr) = run_capture($tool, $bad);
   $rc != 0 or die "$tool unexpectedly accepted $bad\n";
   $stderr =~ /unsupported option '\Q$bad\E'/
      or die "$tool did not identify the unsupported option:\n$stderr";

   my $hint = "Try '$tool --help' for a list of supported options.";
   index($stderr, $hint) >= 0
      or die "$tool did not point to its full help list:\n$stderr";
   $stdout eq ''
      or die "$tool wrote unexpected stdout for an unsupported option:\n$stdout";

   ($rc, $stdout, $stderr) = run_capture($tool, '--help');
   $rc == 0 or die "$tool --help failed with exit code $rc\n";
   my $help = $stdout . $stderr;
   $help =~ /usage:/i or die "$tool --help did not print usage text\n";
}

exit 0;
