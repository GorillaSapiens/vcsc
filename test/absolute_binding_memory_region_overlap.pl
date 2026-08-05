#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# timeout: 120
# expectstdout: absolute binding memory-region overlap checks passed
# expectexit: 0

use strict;
use warnings;
use File::Spec;
use File::Path qw(make_path);
use IPC::Open3;
use Symbol qw(gensym);

sub slurp_fh { my ($fh)=@_; local $/; return <$fh> // ''; }
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
sub write_file {
   my ($path,$text)=@_;
   open(my $fh,'>:raw',$path) or die "write $path: $!\n";
   print {$fh} $text or die "write $path: $!\n";
   close($fh) or die "close $path: $!\n";
}

my ($repo,$tmp)=@ARGV;
die "usage: $0 REPO TMP\n" unless defined $repo && defined $tmp;
make_path($tmp);
my $driver=File::Spec->catfile($repo,'driver','vcsc');
my $inc=File::Spec->catdir($repo,'test');
my $cfg=File::Spec->catfile($tmp,'absolute_overlap.cfg');

write_file($cfg, <<'CFG');
MEMORY {
    ZEROPAGE: start = $0080, size = $0080, type = rw, define = yes;
    RAM:      start = $0200, size = $0080, type = rw, define = yes;
    banana:   start = $3000, size = $0010, type = rw, define = yes;
    pair:     read_start = $5003, write_start = $7007, size = $0005, type = rw, define = yes;
    ROM:      start = $8000, size = $8000, type = ro, define = yes;
}
SEGMENTS {
    ZEROPAGE: load = ROM, run = ZEROPAGE, type = zp,   define = yes;
    CODE:     load = ROM,                 type = ro,   define = yes;
    RODATA:   load = ROM,                 type = ro,   define = yes;
    BSS:      load = RAM,                 type = bss,  define = yes;
    DATA:     load = ROM, run = RAM,      type = data, define = yes;
}
CFG

sub source_prefix {
   return <<'SRC';
type void { $size:0 };
type * { $size:2 $integer:unsigned $endian:little };
type uint8_t { $size:1 $integer:unsigned };
type uint16_t { $size:2 $integer:unsigned $endian:little };
SRC
}

sub expect_fail {
   my ($label,$decl,$pattern)=@_;
   my $src=File::Spec->catfile($tmp,"$label.c26");
   my $hex=File::Spec->catfile($tmp,"$label.hex");
   write_file($src, source_prefix().$decl."\nvoid main(void) { while (1) {} }\n");
   my ($rc,$sig,$out,$err)=run_capture($driver,'-I',$inc,'-T',$cfg,$src,'-o',$hex);
   $rc!=0 && !$sig or die "$label unexpectedly linked\n$out\n$err";
   $err =~ $pattern or die "$label produced the wrong diagnostic\n$err";
}

expect_fail('ordinary_read_overlap',
   'uint8_t port @[0x300f/none];',
   qr/absolute external binding 'port'.*overlaps allocator-managed MEMORY region 'banana' read window \$3000-\$300F/s);
expect_fail('ordinary_write_overlap',
   'uint8_t port @[none/0x3000];',
   qr/absolute external binding 'port'.*overlaps allocator-managed MEMORY region 'banana' write window \$3000-\$300F/s);
expect_fail('split_read_overlap',
   'uint8_t port[3] @[0x5006/none];',
   qr/absolute external binding 'port'.*overlaps allocator-managed MEMORY region 'pair' read window \$5003-\$5007/s);
expect_fail('split_write_overlap',
   'uint16_t port @[none/0x700a];',
   qr/absolute external binding 'port'.*overlaps allocator-managed MEMORY region 'pair' write window \$7007-\$700B/s);
expect_fail('local_overlap',
   'void probe(void) { uint8_t local @[none/0x0200]; local := 1; }',
   qr/absolute external binding 'local'.*overlaps allocator-managed MEMORY region 'RAM' write window \$0200-\$027F/s);

my $valid=File::Spec->catfile($tmp,'valid_external_bindings.c26');
my $valid_hex=File::Spec->catfile($tmp,'valid_external_bindings.hex');
write_file($valid, source_prefix().<<'SRC');
uint8_t VSYNC @[none/0x0000];
uint8_t SWCHA @[0x0280/0x0280];
// Direction matters: the opposite split window is not the address used by
// this binding's operation and therefore is not an allocator collision.
uint8_t pair_write_as_read @[0x7007/none];
uint8_t pair_read_as_write @[none/0x5003];
void main(void) { VSYNC := 2; while (1) {} }
SRC
my ($rc,$sig,$out,$err)=run_capture($driver,'-I',$inc,'-T',$cfg,$valid,'-o',$valid_hex);
$rc==0 && !$sig or die "non-overlapping bindings did not link\n$out\n$err";

print "absolute binding memory-region overlap checks passed\n";
