#!/usr/bin/perl

use strict;
use warnings;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use File::Spec;
use Cwd qw(abs_path);

my $repo = shift @ARGV // dirname(dirname(abs_path($0)));
my $tmp  = shift @ARGV // File::Spec->catdir($repo, 'test', '.assembler-fixture-tmp');

$repo = abs_path($repo) // die "could not resolve repo root\n";
make_path($tmp);
$tmp = abs_path($tmp) // die "could not resolve temp dir\n";

my $asm = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $fixtures = File::Spec->catdir($repo, 'assembler', 'tests');
my $include = $fixtures;

-d $fixtures or die "missing assembler fixture directory: $fixtures\n";
-x $asm or die "missing executable assembler: $asm\n";

my @cases = (
   [ '0.s hex',              'hex', '0.s',              0, [] ],
   [ 'good.s hex',           'hex', 'good.s',           0, [] ],
   [ 'include.s hex',        'hex', 'include.s',        0, [] ],
   [ 'local1.s hex',         'hex', 'local1.s',         0, [] ],
   [ 'macro.s hex',          'hex', 'macro.s',          0, [] ],
   [ 'opxx.s hex',           'hex', 'opxx.s',           0, [] ],
   [ 'peep.s hex',           'hex', 'peep.s',           0, [] ],
   [ 'res.s hex',            'hex', 'res.s',            0, [] ],
   [ 'segment.s hex',        'hex', 'segment.s',        0, [] ],
   [ 'short.s hex',          'hex', 'short.s',          0, [] ],
   [ 'symbols.s hex',        'hex', 'symbols.s',        0, [] ],
   [ 'test_linker.s hex',    'hex', 'test_linker.s',    0, [] ],
   [ 'vectors.s hex',        'hex', 'vectors.s',        0, [] ],

   [ 'def_alias.s object',   'obj', 'def_alias.s',      0, [] ],
   [ 'import_fail.s object', 'obj', 'import_fail.s',    0, [] ],
   [ 'obj.s object',         'obj', 'obj.s',            0, [] ],
   [ 'obj2.s object',        'obj', 'obj2.s',           0, [] ],
   [ 'extended symbol namespace object', 'obj', 'extended_symbol_namespace.s', 0, [] ],
   [ 'selection.s object',   'obj', 'selection.s',      0, [] ],
   [ 'zp_annot.s object',    'obj', 'zp_annot.s',       0, [] ],

   [ 'amspec.s rejects bad forced modes', 'hex', 'amspec.s', 1,
      [ 'LDA.z requires a zero-page operand', 'illegal addressing mode for JSR.z' ] ],
   [ 'bad.s rejects illegal syntax',      'hex', 'bad.s',          1, [ 'parse error' ] ],
   [ 'bad2.s rejects illegal syntax',     'hex', 'bad2.s',         1, [ 'parse error' ] ],
   [ 'dup_symbols.s rejects duplicates',  'hex', 'dup_symbols.s',  1,
      [ "duplicate symbol 'foo'", "duplicate symbol 'start'", "duplicate symbol 'bar'", "duplicate symbol 'baz'" ] ],
   [ 'import_fail.s rejects unresolved final hex', 'hex', 'import_fail.s', 1,
      [ "imported symbol 'puts' was not resolved" ] ],
   [ 'selection.s rejects final STX abs,Y', 'hex', 'selection.s', 1,
      [ 'STX requires a zero-page operand' ] ],
   [ 'test.s rejects unresolved expression', 'hex', 'test.s',     1, [ 'unresolved expression' ] ],
   [ 'tiny.s rejects illegal modes',      'hex', 'tiny.s',        1,
      [ 'unsupported addressing mode', 'illegal addressing mode for STA' ] ],
);

sub slurp {
   my ($path) = @_;
   open(my $fh, '<', $path) or return '';
   local $/;
   my $text = <$fh>;
   close($fh);
   return defined($text) ? $text : '';
}

sub run_case {
   my ($index, $case) = @_;
   my ($name, $mode, $source, $want_exit, $needles) = @$case;
   my $src = File::Spec->catfile($fixtures, $source);
   my $stem = $source;
   $stem =~ s/\.s\z//;
   my $out = File::Spec->catfile($tmp, sprintf('asm_fixture_%02d.out', $index));
   my $err = File::Spec->catfile($tmp, sprintf('asm_fixture_%02d.err', $index));
   my $product = File::Spec->catfile($tmp, sprintf('%s_%02d.%s', $stem, $index, ($mode eq 'hex') ? 'hex' : 'o65'));
   my @cmd = ($asm, '-I', $include);
   if ($mode eq 'hex') {
      push @cmd, "--hex=$product";
   }
   elsif ($mode eq 'obj') {
      push @cmd, '-o', $product;
   }
   else {
      die "unknown case mode: $mode\n";
   }
   push @cmd, $src;

   my $pid = fork();
   die "fork failed: $!\n" if !defined($pid);
   if ($pid == 0) {
      open(STDOUT, '>', $out) or die "open stdout failed: $!\n";
      open(STDERR, '>', $err) or die "open stderr failed: $!\n";
      exec @cmd;
      die "exec failed: $!\n";
   }
   waitpid($pid, 0);
   my $got_exit = $? >> 8;
   my $stderr = slurp($err);
   my $stdout = slurp($out);

   if ($got_exit != $want_exit) {
      return "FAIL $name: exit $got_exit, expected $want_exit\ncmd: @cmd\nstderr:\n$stderr\nstdout:\n$stdout\n";
   }
   for my $needle (@$needles) {
      if (index($stderr, $needle) < 0) {
         return "FAIL $name: stderr missing '$needle'\ncmd: @cmd\nstderr:\n$stderr\n";
      }
   }
   if ($want_exit == 0 && !-s $product) {
      return "FAIL $name: expected non-empty output file $product\ncmd: @cmd\n";
   }
   return undef;
}

my @failures;
for my $i (0 .. $#cases) {
   my $err = run_case($i + 1, $cases[$i]);
   if (defined($err)) {
      push @failures, $err;
   }
}

if (@failures) {
   print STDERR join("\n", @failures);
   exit 1;
}

print 'assembler fixture summary: ' . scalar(@cases) . " passed\n";
exit 0;
