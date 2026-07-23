#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use File::Basename qw(basename);
use File::Find;
use File::Spec;

my $repo=abs_path($ARGV[0] // File::Spec->catdir(File::Spec->curdir(),'..'));
my $test=File::Spec->catdir($repo,'test');
my $fixtures=File::Spec->catdir($repo,'assembler','tests');

sub slurp {
   my($path)=@_;
   open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $data=<$fh>; close($fh);
   return defined($data)?$data:'';
}

opendir(my $tdh,$test) or die "open $test: $!\n";
my @test_files=sort map { File::Spec->catfile($test,$_) }
   grep { $_ ne '.' && $_ ne '..' && -f File::Spec->catfile($test,$_) }
   readdir($tdh);
closedir($tdh);
my %text=map { $_ => slurp($_) } @test_files;

sub referenced_elsewhere {
   my($path)=@_;
   my $name=basename($path);
   for my $other (@test_files) {
      next if $other eq $path;
      return 1 if index($text{$other},$name)>=0;
   }
   return 0;
}

my @dead;
for my $path (@test_files) {
   my $name=basename($path);
   if ($name =~ /\.c26\z/) {
      my @header;
      for my $line (split(/\n/,$text{$path})) {
         if ($line =~ /^\s*\z/ || $line =~ /^\s*(?:(?:\/\/)|#|;)/) {
            push @header,$line;
            next;
         }
         last;
      }
      my $header=join("\n",@header);
      my $runnable=$header =~ /^\s*(?:(?:\/\/)|#|;)\s*(?:runner:|vcsc-cc1\b|vcsc\b|vcsc-as\b|vcsc-ld\b|vcsc-ar\b|vcsc-sim\b|perl\b|make\b|stdbuf\b)/m;
      push @dead,$name if !$runnable && !referenced_elsewhere($path);
   }
   elsif ($name =~ /\.pl\z/ && $name ne 'test.pl') {
      push @dead,$name if !referenced_elsewhere($path);
   }
   elsif ($name =~ /\.(?:s26|cfg|hex|cpp)\z/) {
      push @dead,$name if !referenced_elsewhere($path);
   }
}
@dead and die "unreferenced test/support files: @dead\n";

my $fixture_driver=slurp(File::Spec->catfile($test,'assembler_fixture_suite.pl'));
opendir(my $fdh,$fixtures) or die "open $fixtures: $!\n";
my @fixture_files=sort map { File::Spec->catfile($fixtures,$_) }
   grep { /\.s26\z/ && -f File::Spec->catfile($fixtures,$_) }
   readdir($fdh);
closedir($fdh);
my @unused_fixtures=grep { index($fixture_driver,basename($_))<0 } @fixture_files;
@unused_fixtures and die "assembler fixtures absent from suite: ".join(' ',map {basename($_)} @unused_fixtures)."\n";

my %hashes;
for my $path (@test_files,@fixture_files) {
   next unless basename($path) =~ /\.(?:c26|test|pl|s26|cfg|hex|cpp)\z/;
   push @{$hashes{sha256_hex(slurp($path))}},$path;
}
my @duplicates;
for my $paths (values %hashes) {
   next if @$paths<2;
   push @duplicates,join(' == ',map {File::Spec->abs2rel($_,$repo)} @$paths);
}
@duplicates and die "byte-identical source/test files remain:\n".join("\n",sort @duplicates)."\n";

my $ledger=File::Spec->catfile($repo,'.top_secret','remove.txt');
my %seen;
my %generated_paths=('compiler/coverage_map.h'=>1);
my(@duplicate_ledger,@resurrected);
for my $line (split(/\n/,slurp($ledger))) {
   $line =~ s/^\s+|\s+$//g;
   next if $line eq '';
   push @duplicate_ledger,$line if $seen{$line}++;
   push @resurrected,$line if !$generated_paths{$line} && -e File::Spec->catfile($repo,split('/', $line));
}
@duplicate_ledger and die "duplicate remove.txt paths: @duplicate_ledger\n";
@resurrected and die "remove.txt paths have reappeared: @resurrected\n";

print "source tree hygiene ok\n";
