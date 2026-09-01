#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: banked archive reporting passed
# expectexit: 0

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my($fh)=@_; local $/; return <$fh> // ''; }
sub run_capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub require_ok {
   my($label,@cmd)=@_; my($rc,$sig,$out,$err)=run_capture(@cmd);
   $rc==0 && !$sig or die "$label failed rc=$rc sig=$sig\n@cmd\nstdout:\n$out\nstderr:\n$err";
   return ($out,$err);
}
sub write_file {
   my($path,$data)=@_; open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $data; close($fh);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $data=<$fh>; close($fh); return $data // '';
}

my $repo=abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp=shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp); $tmp=abs_path($tmp) // die "resolve temp\n";

my $as=File::Spec->catfile($repo,'assembler','vcsc-as');
my $ar=File::Spec->catfile($repo,'archiver','vcsc-ar');
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $profile=File::Spec->catfile($vcs,'F8','mapper.c26');

my $root_s=File::Spec->catfile($tmp,'root.s26');
my $remote_s=File::Spec->catfile($tmp,'remote.s26');
my $unused_s=File::Spec->catfile($tmp,'unused.s26');
my $root_o=File::Spec->catfile($tmp,'root.o26');
my $remote_o=File::Spec->catfile($tmp,'remote.o26');
my $unused_o=File::Spec->catfile($tmp,'unused.o26');
my $archive=File::Spec->catfile($tmp,'helpers.l26');
my $bin=File::Spec->catfile($tmp,'archive-banked.bin');
my $map_path=File::Spec->catfile($tmp,'archive-banked.map');
my $sym_path=File::Spec->catfile($tmp,'archive-banked.sym');
my $list_path=File::Spec->catfile($tmp,'archive-banked.lst');
my $distella=File::Spec->catfile($tmp,'archive-banked.cfg');

write_file($root_s, <<'ASM');
.export __reset
.export __nmi
.export __irqbrk
.export main
.import remote
.segment "CODE"
.proc __reset
   JSR main
   RTS
.endproc
.proc __nmi
   RTS
.endproc
.proc __irqbrk
   RTS
.endproc
.proc main
   JSR remote
   RTS
.endproc
ASM
write_file($remote_s, <<'ASM');
.export remote
.segment "CODE.bank1"
.proc remote
   RTS
.endproc
ASM
write_file($unused_s, <<'ASM');
.export unused_archive_function
.segment "CODE.bank1"
.proc unused_archive_function
   RTS
.endproc
ASM

require_ok('assemble root',$as,'-o',$root_o,$root_s);
require_ok('assemble selected archive member',$as,'-o',$remote_o,$remote_s);
require_ok('assemble unused archive member',$as,'-o',$unused_o,$unused_s);
require_ok('create archive',$ar,'rcs',$archive,$remote_o,$unused_o);
require_ok('link banked archive',$driver,'-I',$vcs,'-nostdlib','-Map',$map_path,'--sym',$sym_path,
   '--list',$list_path,'--cfg',$distella,'-o',$bin,$profile,$root_o,$archive);

my $image=read_file($bin);
my $map=read_file($map_path);
my $sym=read_file($sym_path);
my $list=read_file($list_path);
length($image)==8192 or die "banked archive link did not emit exactly 8192 bytes\n";

$map =~ m{\Q$archive\E\(remote\.o26\).*?CODE\.bank1\.__vcsc_function\$remote\s+load=\$D[0-9A-Fa-f]{3}.*?bank=bank1.*?region=bank1}s
   or die "selected archive member lacks BANK1 placement in map\n$map";
$map !~ /unused_archive_function|unused\.o26/
   or die "unused archive member was selected or reported\n$map";
$map =~ /TRAMPOLINES.*?entries=1 jmp=0 jsr=1/s &&
$map =~ /JSR entry=.*?target=\$D[0-9A-Fa-f]{3}\s+remote\s+source=bank0.*?destination=bank1/s
   or die "map omitted the archive member's cross-bank bridge\n$map";
$map =~ /^\s*\$D[0-9A-Fa-f]{3}\s+remote\s+\Q$archive\E\(remote\.o26\)/m
   or die "map symbol table omitted archive origin or logical BANK1 address\n$map";

$sym =~ /^remote\s+d[0-9a-f]{3}$/mi
   or die "Stella symbol file omitted remote's logical BANK1 address\n$sym";
$list =~ /remote\.s26:4 \[bank BANK1\] \| RTS\n\s*\d+\s+d[0-9a-f]{3}\s+60\s+.*; RTS\s*$/mi
   or die "linked listing omitted remote's BANK1 source/bytes\n$list";
$list =~ /root\.s26:8 \[bank BANK0\] \| JSR main\n\s*\d+\s+f[0-9a-f]{3}\s+20\s+[0-9a-f]{2}\s+f[0-9a-f]\s+.*; JSR main/mis
   or die "linked listing omitted BANK0 startup source/bytes\n$list";

print "banked archive reporting passed\n";
