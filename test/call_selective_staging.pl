#!/usr/bin/env perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: compile
# expectstdout: selective call argument staging ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub read_file {
   my ($path)=@_;
   open(my $fh,'<',$path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>',$path) or die "could not write $path: $!\n";
   print {$fh} $text; close($fh) or die "could not close $path: $!\n";
}
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($?>>8,$?&127,$stdout,$stderr);
}
sub compile_source {
   my ($cc1,$inc,$tmp,$stem,$source)=@_;
   my $src=File::Spec->catfile($tmp,"$stem.c26");
   my $asm=File::Spec->catfile($tmp,"$stem.s26");
   write_file($src,$source);
   my ($exit,$sig,$stdout,$stderr)=run_capture($cc1,'-quiet','-I',$inc,$src,'-o',$asm);
   die "$stem compiler exited $exit signal $sig\nstdout:\n$stdout\nstderr:\n$stderr"
      if $exit || $sig;
   die "$stem compiler wrote unexpected stdout:\n$stdout" if $stdout ne '';
   die "$stem compiler wrote unexpected stderr:\n$stderr" if $stderr ne '';
   return read_file($asm);
}
sub procedure_body {
   my ($text,$name)=@_;
   my ($body)=$text =~ /\.proc\s+\Q$name\E\n(.*?)\.endproc/s;
   defined($body) or die "could not isolate $name procedure\n";
   return $body;
}
sub sole_scratch_size {
   my ($text,$body,$label)=@_;
   my %used=map { $_ => 1 } ($body =~ /(__vcsc_scratch_\d+)/g);
   my @used=sort keys %used;
   @used == 1 or die "$label expected one reusable call scratch object, found @used\n";
   $text =~ /^\Q$used[0]\E:\n\s*\.res\s+(\d+)/m
      or die "$label could not find declaration for $used[0]\n";
   return ($used[0],0+$1);
}
sub ordered {
   my ($body,$label,@needles)=@_;
   my $at=0;
   for my $needle (@needles) {
      my $next=index($body,$needle,$at);
      $next >= 0 or die "$label missing ordered fragment '$needle'\n";
      $at=$next+length($needle);
   }
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temporary directory\n";
my $cc1=File::Spec->catfile($repo,'compiler','vcsc-cc1');
my $inc=File::Spec->catdir($repo,'test');

my $plain=compile_source($cc1,$inc,$tmp,'call_staging_plain',<<'SRC');
include "machine_6502.c26"
void sink(uint8_t a, uint16_t b, uint8_t c, uint32_t d) {}
void main(void) { sink(1, 2, 3, 4); }
SRC
my $plain_main=procedure_body($plain,'main');
my ($plain_scratch,$plain_size)=sole_scratch_size($plain,$plain_main,'plain call');
$plain_size == 4
   or die "plain call reserved $plain_size bytes, expected one four-byte reusable slot\n";
ordered($plain_main,'plain call',
        'sta  sink$a','sta  sink$b','sta  sink$c','sta  sink$d','jsr sink');

my $nested=compile_source($cc1,$inc,$tmp,'call_staging_nested',<<'SRC');
include "machine_6502.c26"
uint16_t later(void) { return 0x1234; }
void sink(uint8_t a, uint16_t b, uint8_t c, uint32_t d) {}
void main(void) { sink(1, later(), 3, 4); }
SRC
my $nested_main=procedure_body($nested,'main');
my ($nested_scratch,$nested_size)=sole_scratch_size($nested,$nested_main,'nested call');
$nested_size == 5
   or die "nested call reserved $nested_size bytes, expected one staged byte plus a four-byte reusable slot\n";
ordered($nested_main,'nested call',
        'jsr later','sta  sink$b','sta  sink$c','sta  sink$d','sta  sink$a','jsr sink');
my $before_later=substr($nested_main,0,index($nested_main,'jsr later'));
$before_later =~ /sta\s+\Q$nested_scratch\E(?:\s|$)/
   or die "nested call did not preserve the first argument before evaluating later()\n";
$before_later !~ /sta\s+sink\$a(?:\s|$)/
   or die "nested call wrote sink\$a before later() could clobber an overlaid activation\n";

my $first_call=compile_source($cc1,$inc,$tmp,'call_staging_first_call',<<'SRC');
include "machine_6502.c26"
uint16_t first(void) { return 0x1234; }
void sink(uint16_t a, uint32_t b) {}
void main(void) { sink(first(), 7); }
SRC
my $first_main=procedure_body($first_call,'main');
my ($first_scratch,$first_size)=sole_scratch_size($first_call,$first_main,'first-argument call');
$first_size == 4
   or die "first-argument call reserved $first_size bytes, expected no preserved prefix and one four-byte slot\n";
ordered($first_main,'first-argument call','jsr first','sta  sink$a','sta  sink$b','jsr sink');

print "selective call argument staging ok\n";
