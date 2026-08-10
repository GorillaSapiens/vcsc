#!/usr/bin/perl

use strict;
use warnings;
use POSIX qw(strftime);
use Sys::Hostname qw(hostname);
use File::Spec;

sub usage {
   return "usage: $0 [version.h]\n";
}

sub git_lines {
   my (@args) = @_;
   open(my $saved_stderr, '>&', STDERR) or die "could not save stderr: $!\n";
   open(STDERR, '>', File::Spec->devnull()) or die "could not redirect stderr: $!\n";
   my $opened = open(my $fh, '-|', 'git', @args);
   open(STDERR, '>&', $saved_stderr) or die "could not restore stderr: $!\n";
   close($saved_stderr);
   return () if !$opened;
   my @lines = <$fh>;
   close($fh);
   return () if $? != 0;
   chomp @lines;
   s/\r$// for @lines;
   return @lines;
}

sub git_line {
   my (@args) = @_;
   my @lines = git_lines(@args);
   return @lines ? $lines[0] : '';
}

sub have_git_head {
   return 0 if git_line('rev-parse', '--is-inside-work-tree') ne 'true';
   return git_line('rev-parse', '--verify', 'HEAD') ne '';
}

sub no_git_identity {
   my $user = $ENV{USER} // $ENV{USERNAME} // getpwuid($<) // 'unknown';
   my $host = hostname() || 'unknown';

   if ($host !~ /\./ && -r '/etc/resolv.conf') {
      if (open(my $fh, '<', '/etc/resolv.conf')) {
         while (my $line = <$fh>) {
            if ($line =~ /^\s*(?:search|domain)\s+(\S+)/) {
               $host .= ".$1";
               last;
            }
         }
         close($fh);
      }
   }

   return "$user\@$host";
}

my $output = shift(@ARGV) // 'version.h';
die usage() if @ARGV;

my $version;
if (have_git_head()) {
   my $epoch = git_line('show', '-s', '--format=%ct', 'HEAD');
   my $stamp = ($epoch =~ /^\d+$/)
      ? strftime('%Y-%m-%d %H:%M:%SZ', gmtime($epoch))
      : strftime('%Y-%m-%d %H:%M:%SZ', gmtime(time));

   my @tags = git_lines('tag', '--points-at', 'HEAD', '--sort=-version:refname');
   my $ref = @tags ? $tags[0] : git_line('branch', '--show-current');
   $ref = 'detached' if $ref eq '';

   my $hash = git_line('rev-parse', '--short=12', 'HEAD');
   $hash = 'unknown' if $hash eq '';

   my @status = git_lines('status', '--porcelain', '-uno');
   my $state = @status ? 'modified' : 'clean';

   $version = "$stamp $ref $hash $state";
}
else {
   my $stamp = strftime('%Y-%m-%d %H:%M:%SZ', gmtime(time));
   $version = "$stamp nogit " . no_git_identity() . " clean";
}

$version =~ s/([\\"])/\\$1/g;
open(my $out, '>', $output) or die "could not write $output: $!\n";
print $out qq{#define VERSION "$version"\n};
close($out) or die "could not close $output: $!\n";
