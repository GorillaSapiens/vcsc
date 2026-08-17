#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub usage { die "usage: $0 REPO TMP [--shard INDEX/COUNT]\n"; }
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
my($shard_index,$shard_count);
if (@ARGV) {
   shift @ARGV eq '--shard' or usage();
   my $spec=shift @ARGV // usage();
   $spec =~ /\A([1-9][0-9]*)\/([1-9][0-9]*)\z/ or usage();
   ($shard_index,$shard_count)=($1,$2);
   $shard_index <= $shard_count or usage();
}
usage() if @ARGV;
$repo=abs_path($repo) // die "resolve repository\n";
make_path($tmp);
$tmp=abs_path($tmp) // die "resolve temporary directory\n";

my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $roundtrip=File::Spec->catfile($repo,'disassembler','roundtrip.pl');
my $vcs=File::Spec->catdir($repo,'libraries','vcs');
-f $roundtrip or die "missing disassembler round-trip verifier $roundtrip\n";
my $faithful_cfg=File::Spec->catfile($vcs,qw(renderers faithful_legacy_playercolors faithful_legacy_playercolors.cfg));
my $faithful_multisprite=File::Spec->catdir($vcs,qw(renderers faithful_legacy_multisprite));
my $faithful_multisprite_cfg=File::Spec->catfile($faithful_multisprite,'faithful_legacy_multisprite.cfg');
my $examples_root=File::Spec->catdir($repo,'examples');
my @examples;
sub profile_from_source {
   my($source)=@_;
   my $text=read_file($source);
   return '2k' if $text =~ /^\s*include\s+"vcs_2k\.c26"\s*$/m;
   return 'cv' if $text =~ /^\s*include\s+"vcs_2k_cv\.c26"\s*$/m;
   return '4ksc' if $text =~ /^\s*include\s+"vcs_4k_sc\.c26"\s*$/m;
   return 'f8' if $text =~ /^\s*include\s+"vcs_8k_f8\.c26"\s*$/m;
   return '0840' if $text =~ /^\s*include\s+"vcs_8k_0840\.c26"\s*$/m;
   return 'ua' if $text =~ /^\s*include\s+"vcs_8k_ua\.c26"\s*$/m;
   return 'uasw' if $text =~ /^\s*include\s+"vcs_8k_uasw\.c26"\s*$/m;
   return '0fa0' if $text =~ /^\s*include\s+"vcs_8k_0fa0\.c26"\s*$/m;
   return 'f8sc' if $text =~ /^\s*include\s+"vcs_8k_f8sc\.c26"\s*$/m;
   return 'fa' if $text =~ /^\s*include\s+"vcs_12k_fa\.c26"\s*$/m;
   return 'omni' if $text =~ /^\s*include\s+"vcs_omni_32k\.c26"\s*$/m;
   return 'jane' if $text =~ /^\s*include\s+"vcs_16k_jane\.c26"\s*$/m;
   return '4k';
}
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
my $all_example_count=scalar(@examples);
if (defined($shard_index)) {
   my @selected;
   for my $i (0..$#examples) {
      push @selected,$examples[$i] if ($i % $shard_count) == ($shard_index - 1);
   }
   @examples=@selected;
   @examples or die "example shard $shard_index/$shard_count is empty\n";
}

for my $entry (@examples) {
   my($dir,$file)=@$entry;
   my $source=File::Spec->catfile($examples_root,$dir,$file);
   my $tag=$dir; $tag =~ s{[^A-Za-z0-9_.-]+}{__}g;
   my $bin=File::Spec->catfile($tmp,"$tag.bin");
   my $map=File::Spec->catfile($tmp,"$tag.map");
   my $profile=profile_from_source($source);
   my @extra;
   if ($file eq 'bankswitching_diagnostic.c26' ||
       $file eq 'banked_standard_renderer.c26') {
      push @extra,'-DMAPPER_BANKS=2',
                  '-T',File::Spec->catfile($vcs,'vcs.cfg');
   } elsif ($profile eq '2k') {
      push @extra,'-T',File::Spec->catfile($vcs,'vcs.cfg');
   } elsif ($profile eq 'f8') {
      push @extra,'-T',File::Spec->catfile($vcs,'vcs_8k_f8.cfg');
   } elsif ($profile eq 'cv' || $profile eq '4ksc' || $profile eq 'f8sc' || $profile eq 'fa' || $profile eq 'omni' || $profile eq 'jane' || $profile eq '0840' || $profile eq 'ua' || $profile eq 'uasw' || $profile eq '0fa0') {
      # C26 owns the 4KSC/F8SC/FA cartridge and cartridge-RAM topology; the generic cfg
      # only reserves the RIOT hardware stack, matching the public Makefiles.
      push @extra,'-T',File::Spec->catfile($vcs,'vcs.cfg');
   } elsif ($file eq 'fingerprint.c26') {
      push @extra,'-Wa,--illegals';
   } elsif ($file =~ /\Afaithful_legacy_playercolors.*\.c26\z/) {
      push @extra,'-Wa,--illegals','-T',$faithful_cfg;
   } elsif ($file eq 'faithful_legacy_multisprite_diagnostic.c26') {
      push @extra,'-nostdlib','-Wa,--illegals','-T',$faithful_multisprite_cfg;
   } elsif ($file =~ /\Amultisprite_.*\.c26\z/) {
      push @extra,'-Wa,--illegals';
   } elsif ($file =~ /_unofficial_.*\.c26\z/) {
      push @extra,'-Wa,--illegals';
   }
   -f $source or die "missing editable example $source\n";
   my $source_dir=File::Spec->catdir($examples_root,$dir);
   my @cmd=($driver,'-I',$vcs,'-I',$source_dir,'-Map',$map,@extra);
   # Renderer source operands must follow the C source. Move any trailing .s26
   # operand after the example while leaving compiler/linker options in place.
   my @renderer=grep { /\.s26\z/ } @cmd;
   @cmd=grep { !/\.s26\z/ } @cmd;
   if ($file eq 'banked_standard_renderer.c26') {
      push @renderer,File::Spec->catfile(
         $vcs,qw(renderers standard_4k_ntsc standard_4k_ntsc_renderer.s26));
   }
   if ($file eq 'faithful_legacy_multisprite_diagnostic.c26') {
      push @renderer,
         File::Spec->catfile($source_dir,'faithful_legacy_multisprite_diagnostic_data.s26'),
         File::Spec->catfile($faithful_multisprite,'faithful_legacy_multisprite_renderer.s26'),
         File::Spec->catfile($faithful_multisprite,'faithful_legacy_multisprite_startup.s26');
   }
   push @cmd,$source,@renderer,'-o',$bin;
   my($rc,$sig,$out,$err)=capture(@cmd);
   $rc==0 && !$sig or die "$dir build failed\nstdout:\n$out\nstderr:\n$err";
   without_cartridge_usage($out) eq '' or die "$dir wrote unexpected stdout:\n$out";
   $err eq '' or die "$dir wrote stderr:\n$err";
   my $rom=read_file($bin);
   my $expected_size = ($file eq 'bankswitching_diagnostic.c26' ||
                        $file eq 'banked_standard_renderer.c26') ? 8192
      : ($profile eq '2k' || $profile eq 'cv') ? 2048 : ($profile eq 'f8' || $profile eq 'f8sc' || $profile eq '0840' || $profile eq 'ua' || $profile eq 'uasw' || $profile eq '0fa0') ? 8192 : $profile eq 'fa' ? 12288 : $profile eq 'jane' ? 16384 : $profile eq 'omni' ? 32768 : 4096;
   length($rom)==$expected_size
      or die "$dir produced ".length($rom)." bytes, expected $expected_size\n";
   my %known_signature=map { $_=>1 } (
      "4KSC", "F8\0\0", "F8SC", "F6\0\0", "F6SC",
      "F4\0\0", "F4SC", "FA\0\0", "CV\0\0", "OMNI", "JANE", "0840", "UA\0\0", "UASW", "0FA0",
   );
   my $tail_signature=substr($rom,$expected_size-8,4);
   my $vector_offset = $expected_size - 6;
   my($nmi,$reset,$irq)=unpack('v3',substr($rom,$vector_offset,6));
   if ($known_signature{$tail_signature}) {
      for my $v ($reset,$irq) {
         $v>=0xf000 && $v<=0xffff or die sprintf("%s vector %04X is outside ROM\n",$dir,$v);
      }
   } else {
      for my $v ($nmi,$reset,$irq) {
         $v>=0xf000 && $v<=0xffff or die sprintf("%s vector %04X is outside ROM\n",$dir,$v);
      }
   }
}

# Every editable example ROM is also part of the disassembler integration
# corpus.  Reuse the same shard-local binaries we just compiled so this adds
# byte-exact disassemble/reassemble coverage without rebuilding the examples a
# second time.  Keep the verifier's verbose per-ROM MD5 output buffered unless
# it fails; the public shard output remains compact and deterministic.
my $roundtrip_out=File::Spec->catdir($tmp,'disassembler-roundtrip');
my($rt_rc,$rt_sig,$rt_out,$rt_err)=capture($^X,$roundtrip,$tmp,$roundtrip_out);
$rt_rc==0 && !$rt_sig or die "example disassembler round trip failed\nstdout:\n$rt_out\nstderr:\n$rt_err";
$rt_err eq '' or die "example disassembler round trip wrote stderr:\n$rt_err";
my $expected_roundtrips=scalar(@examples);
$rt_out =~ /Summary:\s+\Q$expected_roundtrips\E passed, 0 failed, \Q$expected_roundtrips\E total\n\z/
   or die "unexpected example disassembler round-trip summary:\n$rt_out";

if (defined($shard_index)) {
   print "vcs_examples_build shard $shard_index/$shard_count ok: ".scalar(@examples).
      " of $all_example_count recursively discovered editable examples compile, link, and round-trip\n";
}
else {
   print "vcs_examples_build ok: all recursively discovered editable examples compile, link, and round-trip\n";
}
