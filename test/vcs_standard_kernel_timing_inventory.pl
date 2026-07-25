#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Spec;

sub usage { die "usage: $0 REPO_ROOT TMP_DIR\n"; }
sub read_file {
   my ($path)=@_;
   open(my $fh,'<:raw',$path) or die "could not open $path: $!\n";
   local $/; my $data=<$fh>; close($fh) or die "could not close $path: $!\n";
   return defined($data)?$data:'';
}

my $repo=shift @ARGV // usage();
my $tmp=shift @ARGV // usage();
usage() if @ARGV;
$repo=abs_path($repo) // die "could not resolve repo root\n";
$tmp=abs_path($tmp) // die "could not resolve temp dir\n";
my $dir=File::Spec->catdir($repo,'libraries','vcs','kernels','standard_4k_ntsc');
my $script=File::Spec->catfile($dir,'inventory.pl');
my $table=File::Spec->catfile($dir,'standard_4k_ntsc_timing_inventory.tsv');
my $doc=File::Spec->catfile($dir,'TIMING_INVENTORY.md');

my $fresh=`cd '$dir' && ./inventory.pl`;
$? == 0 or die "inventory generator failed\n";
$fresh eq read_file($table) or die "timing inventory is stale; regenerate it with inventory.pl\n";
my @rows=grep { length($_) } split(/\n/,$fresh);
shift @rows eq "file\tline\tkind\topcode\toperand\tpurpose"
   or die "timing inventory header is wrong\n";
my (%kind,%illegal);
for my $row (@rows) {
   my @f=split(/\t/,$row,-1);
   @f==6 or die "malformed timing inventory row: $row\n";
   ++$kind{$f[2]};
   ++$illegal{$f[3]} if $f[2] eq 'unofficial_opcode';
   length($f[5]) or die "inventory row has no purpose: $row\n";
}
my %want_kind=(relative_branch=>28,indexed_read=>35,indirect_pointer=>11,
               padding=>18,alignment=>5,segment=>4,unofficial_opcode=>0);
for my $name (sort keys %want_kind) {
   ($kind{$name}//0)==$want_kind{$name}
      or die "$name inventory count changed: got ".($kind{$name}//0).", expected $want_kind{$name}\n";
}
keys(%illegal) == 0 or die "unofficial opcode inventory is not empty\n";
my $docs=read_file($doc);
for my $needle ('task-20e baseline','28 relative branches','35 indexed reads',
                '11 indexed indirect pointer reads','no source-level unofficial-opcode sites',
                'task 20r replaced the final `SBX`, `ASR`, and `NOP.z` sites',
                'task 20q removed all 11 `DCP` sites',
                'task 20p removed all 5 `LAX` sites') {
   index($docs,$needle)>=0 or die "TIMING_INVENTORY.md lacks $needle\n";
}
print "vcs_standard_kernel_timing_inventory ok\n";
