#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub read_file { my ($p)=@_; open(my $f,'<',$p) or die "open $p: $!\n"; local $/; my $d=<$f>; close($f); return $d//''; }
sub write_file { my ($p,$d)=@_; open(my $f,'>',$p) or die "write $p: $!\n"; print {$f} $d; close($f); }
sub run_capture {
   my (@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $stdout=slurp_fh($out); my $stderr=slurp_fh($err); waitpid($pid,0);
   return ($?>>8,$?&127,$stdout,$stderr);
}

my $repo=shift @ARGV // usage(); my $tmp=shift @ARGV // usage(); usage() if @ARGV;
$repo=abs_path($repo) // die "bad repo\n"; $tmp=abs_path($tmp) // die "bad tmp\n";
my $src=File::Spec->catfile($tmp,'common_indexed_address_reuse.c26');
my $asm=File::Spec->catfile($tmp,'common_indexed_address_reuse.s');
write_file($src, <<'SRC');
include "machine_6502.c26"
struct Pair { uint16_t a; uint16_t b; };
Pair pairs[4];
uint8_t i;
uint8_t j;
uint16_t same_result;
uint16_t different_result;
void same_index(void) {
   same_result := pairs[i].a + pairs[i].b;
}
void different_index(void) {
   different_result := pairs[i].a + pairs[j].b;
}
SRC
my $vcsc_cc1=File::Spec->catfile($repo,'compiler','vcsc-cc1');
my $inc=File::Spec->catdir($repo,'test');
my ($exit,$sig,$stdout,$stderr)=run_capture($vcsc_cc1,'-quiet','-I',$inc,$src,'-o',$asm);
die "compiler exited $exit signal $sig\nstdout:\n$stdout\nstderr:\n$stderr" if $exit || $sig;
die "unexpected compiler output\n$stdout$stderr" if $stdout ne '' || $stderr ne '';
my $text=read_file($asm);
my ($same)=$text =~ /\.proc same_index\n(.*?)\.endproc/s;
my ($different)=$text =~ /\.proc different_index\n(.*?)\.endproc/s;
defined($same) && defined($different) or die "could not isolate generated procedures\n";
my $same_base=()=$same =~ /lda #<\{pairs \+ 0\}/g;
my $different_base=()=$different =~ /lda #<\{pairs \+ 0\}/g;
$same_base==1 or die "same-index fields computed the base $same_base times, expected once\n";
$different_base==2 or die "different-index fields computed the base $different_base times, expected twice\n";
for my $off (0..3) {
   $same =~ /ldy #$off\n\s*lda \(ptr0\),y/
      or die "same-index reuse is missing ptr0-relative field byte $off\n";
}
print "common indexed address reuse ok\n";
