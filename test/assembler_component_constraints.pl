#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: assembler_component_constraints ok
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub slurp_fh { my ($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub run_capture {
   my (@cmd)=@_;
   my $err=gensym;
   my $pid=open3(my $in,my $out,$err,@cmd);
   close($in);
   my $stdout=slurp_fh($out);
   my $stderr=slurp_fh($err);
   waitpid($pid,0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>:raw',$path) or die "could not create $path: $!\n";
   print {$fh} $text;
   close($fh) or die "could not close $path: $!\n";
}
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not open $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub require_fail {
   my ($label,$re,@cmd)=@_;
   my ($exit,$sig,$out,$err)=run_capture(@cmd);
   $exit != 0 && !$sig or die "$label unexpectedly succeeded\nstdout:\n$out\nstderr:\n$err";
   $err =~ $re or die "$label did not report the expected error\nstdout:\n$out\nstderr:\n$err";
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";

my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $cfg=File::Spec->catfile($vcs,'vcs.cfg');
my $profile=File::Spec->catfile($vcs,'vcs_4k.c26');
my $valid_s=File::Spec->catfile($tmp,'component_valid.s26');
my $valid_o=File::Spec->catfile($tmp,'component_valid.o26');
my $main=File::Spec->catfile($tmp,'component_main.c26');
my $map=File::Spec->catfile($tmp,'component_valid.map');
my $bin=File::Spec->catfile($tmp,'component_valid.bin');

write_file($valid_s,<<'ASM');
.segmentregion "COMPONENT_CODE", startup
.segmentalign "COMPONENT_CODE", 256
.segmentprivate "COMPONENT_CODE"
.callstackextra 2
.segment "COMPONENT_CODE"
.export component_entry
component_entry:
   RTS
ASM
write_file($main,<<'C26');
include "vcs.c26"
extern void component_entry(void);
void main(void) { component_entry(); }
C26

my ($aexit,$asig,$aout,$aerr)=run_capture($as,'-o',$valid_o,$valid_s);
$aexit == 0 && !$asig or die "valid component assembly failed\nstdout:\n$aout\nstderr:\n$aerr";
$aout eq '' && $aerr eq '' or die "valid component assembly was noisy\nstdout:\n$aout\nstderr:\n$aerr";
my $object=read_file($valid_o);
index($object,'__componentmeta$V1$S$2')>=0
   or die "object lacks hidden-stack metadata\n";
index($object,'__componentmeta$V1$L$434F4D504F4E454E545F434F4445$4073746172747570$256$1')>=0
   or die "object lacks canonical layout metadata\n";

my ($lexit,$lsig,$lout,$lerr)=run_capture(
   $driver,'-I',$vcs,'-T',$cfg,'-Map',$map,$profile,$main,$valid_o,'-o',$bin);
$lexit == 0 && !$lsig or die "valid component link failed\nstdout:\n$lout\nstderr:\n$lerr";
$lerr eq '' or die "valid component link wrote stderr:\n$lerr";
-s $bin == 4096 or die "valid component link did not produce a 4K image\n";
my $map_text=read_file($map);
$map_text =~ /COMPONENT_CODE\s+load=\$[0-9A-F]{4}\s+size=\$0001.*component-region=\@startup.*component-align=\$0100.*component-private=yes/
   or die "map lacks component placement contract\n";
$map_text =~ /region=ram\s+depth=1\s+bytes=\$0004.*extra=\$0002/
   or die "map lacks component hidden-stack accounting\n";

my @bad = (
   [ 'non-power-of-two alignment', qr/must be a power of two/,
     ".segmentalign \"CODE\", 3\n.segment \"CODE\"\nfoo:\n RTS\n" ],
   [ 'missing segment', qr/names missing or empty segment 'NO_SUCH_SEGMENT'/,
     ".segmentalign \"NO_SUCH_SEGMENT\", 256\n.segment \"CODE\"\nfoo:\n RTS\n" ],
   [ 'conflicting regions', qr/conflicting \.segmentregion for 'CODE'/,
     ".segmentregion \"CODE\", startup\n.segmentregion \"CODE\", nowhere\n.segment \"CODE\"\nfoo:\n RTS\n" ],
   [ 'nonconstant stack', qr/\.callstackextra must be a constant/,
     ".callstackextra missing_symbol\n.segment \"CODE\"\nfoo:\n RTS\n" ],
);
for my $case (@bad) {
   my ($label,$re,$text)=@$case;
   my $src=File::Spec->catfile($tmp,"bad_" . ($label =~ s/\W+/_/gr) . '.s26');
   my $obj=File::Spec->catfile($tmp,"bad_" . ($label =~ s/\W+/_/gr) . '.o26');
   write_file($src,$text);
   require_fail($label,$re,$as,'-o',$obj,$src);
}

# The linker must reject malformed reserved metadata even when it comes from an
# otherwise valid object file.
my $badmeta_s=File::Spec->catfile($tmp,'bad_component_metadata.s26');
my $badmeta_o=File::Spec->catfile($tmp,'bad_component_metadata.o26');
write_file($badmeta_s,<<'ASM');
__componentmeta$V1$bad = 0
.export __componentmeta$V1$bad
.segment "CODE"
.export component_entry
component_entry:
   RTS
ASM
my ($mexit,$msig,$mout,$merr)=run_capture($as,'-o',$badmeta_o,$badmeta_s);
$mexit == 0 && !$msig or die "could not construct malformed metadata object\n$mout$merr";
require_fail('malformed linker metadata',qr/unknown component metadata record/,
   $driver,'-I',$vcs,'-T',$cfg,$profile,$main,$badmeta_o,'-o',
   File::Spec->catfile($tmp,'bad_component_metadata.bin'));

print "assembler_component_constraints ok\n";
