#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectstdout: vcs_examples_build ok: all recursively discovered editable examples compile and link

use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP\n"; }
sub slurp_fh { my($fh)=@_; local $/; my $d=<$fh>; return defined($d)?$d:''; }
sub capture {
   my(@cmd)=@_; my $err=gensym; my $pid=open3(my $in,my $out,$err,@cmd); close($in);
   my $so=slurp_fh($out); my $se=slurp_fh($err); waitpid($pid,0);
   return ($? >> 8,$? & 127,$so,$se);
}
sub read_file {
   my($path)=@_; open(my $fh,'<:raw',$path) or die "read $path: $!\n";
   local $/; my $d=<$fh>; close($fh); return defined($d)?$d:'';
}
sub without_cartridge_usage {
   my($out)=@_; $out =~ s/\AMEMORY USAGE\n(?:  [^\n]+\n)+//; return $out;
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
my $faithful_cfg=File::Spec->catfile($vcs,qw(renderers faithful_legacy_playercolors faithful_legacy_playercolors.cfg));
my $examples_root=File::Spec->catdir($repo,'examples');
my @examples;
find({
   no_chdir=>1,
   wanted=>sub {
      return unless -f $_ && /\.c26\z/;
      my $source=$File::Find::name;
      return if $source =~ m{[\/]examples[\/]common[\/]};
      my($vol,$dir,$file)=File::Spec->splitpath($source);
      my $rel=File::Spec->abs2rel($dir,$examples_root);
      push @examples,[$rel,$file];
   },
},$examples_root);
@examples=sort { $a->[0] cmp $b->[0] || $a->[1] cmp $b->[1] } @examples;
@examples or die "no editable examples found under $examples_root\n";

for my $entry (@examples) {
   my($dir,$file)=@$entry;
   my $source=File::Spec->catfile($examples_root,$dir,$file);
   my $tag=$dir; $tag =~ s{[^A-Za-z0-9_.-]+}{__}g;
   my $bin=File::Spec->catfile($tmp,"$tag.bin");
   my $map=File::Spec->catfile($tmp,"$tag.map");
   my @extra;
   if ($file eq 'fingerprint.c26') {
      push @extra,'-Wa,--illegals';
   } elsif ($file =~ /\Afaithful_legacy_playercolors.*\.c26\z/) {
      push @extra,'-Wa,--illegals','-T',$faithful_cfg;
   } elsif ($file =~ /_unofficial_.*\.c26\z/) {
      push @extra,'-Wa,--illegals';
   } elsif ($file eq 'bankswitching_diagnostic.c26') {
      push @extra,'-DMAPPER_BANKS=2','-DSOURCE_BANK=0','-DJUMP_DEST=0',
                  '-T',File::Spec->catfile($vcs,'vcs_8k_f8.cfg');
   }
   -f $source or die "missing editable example $source\n";
   my $source_dir=File::Spec->catdir($examples_root,$dir);
   my @cmd=($driver,'-I',$vcs,'-I',$source_dir,'-Map',$map,@extra);
   # Renderer source operands must follow the C source. Move any trailing .s26
   # operand after the example while leaving compiler/linker options in place.
   my @renderer=grep { /\.s26\z/ } @cmd;
   @cmd=grep { !/\.s26\z/ } @cmd;
   push @cmd,$source,@renderer,'-o',$bin;
   my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$dir build failed\nstdout:\n$out\nstderr:\n$err";
   without_cartridge_usage($out) eq '' or die "$dir wrote unexpected stdout:\n$out";
   $err eq '' or die "$dir wrote stderr:\n$err";
   my $rom=read_file($bin);
   my $expected_size = $file eq 'bankswitching_diagnostic.c26' ? 8192 : 4096;
   length($rom)==$expected_size
      or die "$dir produced ".length($rom)." bytes, expected $expected_size\n";
   my $vector_offset = $expected_size - 6;
   my($nmi,$reset,$irq)=unpack('v3',substr($rom,$vector_offset,6));
   for my $v ($nmi,$reset,$irq) {
      $v>=0xf000 && $v<=0xffff or die sprintf("%s vector %04X is outside ROM\n",$dir,$v);
   }
}

print "vcs_examples_build ok: all recursively discovered editable examples compile and link\n";
