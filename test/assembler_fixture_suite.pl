#!/usr/bin/perl
# runner: perl @FILE@ @REPO@ @TMP@
# phase: e2e
# expectexit: 0
# expectstdout: assembler fixture summary: 27 passed
# expectstderrexact:


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
   [ '0.s26 hex',              'hex', '0.s26',              0, [] ],
   [ 'good.s26 hex',           'hex', 'good.s26',           0, [] ],
   [ 'include.s26 hex',        'hex', 'include.s26',        0, [] ],
   [ 'local1.s26 hex',         'hex', 'local1.s26',         0, [] ],
   [ 'macro.s26 hex',          'hex', 'macro.s26',          0, [] ],
   [ 'opxx.s26 hex',           'hex', 'opxx.s26',           0, [] ],
   [ 'peep.s26 hex',           'hex', 'peep.s26',           0, [] ],
   [ 'res.s26 hex',            'hex', 'res.s26',            0, [] ],
   [ 'segment.s26 hex',        'hex', 'segment.s26',        0, [] ],
   [ 'short.s26 hex',          'hex', 'short.s26',          0, [] ],
   [ 'symbols.s26 hex',        'hex', 'symbols.s26',        0, [] ],
   [ 'test_linker.s26 hex',    'hex', 'test_linker.s26',    0, [] ],
   [ 'vectors.s26 hex',        'hex', 'vectors.s26',        0, [] ],

   [ 'def_alias.s26 object',   'obj', 'def_alias.s26',      0, [] ],
   [ 'import_fail.s26 object', 'obj', 'import_fail.s26',    0, [] ],
   [ 'obj.s26 object',         'obj', 'obj.s26',            0, [] ],
   [ 'extended symbol namespace object', 'obj', 'extended_symbol_namespace.s26', 0, [] ],
   [ 'selection.s26 object',   'obj', 'selection.s26',      0, [] ],
   [ 'zp_annot.s26 object',    'obj', 'zp_annot.s26',       0, [] ],

   [ 'amspec.s26 rejects bad forced modes', 'hex', 'amspec.s26', 1,
      [ 'LDA.z requires a zero-page operand', 'illegal addressing mode for JSR.z' ] ],
   [ 'bad.s26 rejects illegal syntax',      'hex', 'bad.s26',          1, [ 'parse error' ] ],
   [ 'bad2.s26 rejects illegal syntax',     'hex', 'bad2.s26',         1, [ 'parse error' ] ],
   [ 'dup_symbols.s26 rejects duplicates',  'hex', 'dup_symbols.s26',  1,
      [ "duplicate symbol 'foo'", "duplicate symbol 'start'", "duplicate symbol 'bar'", "duplicate symbol 'baz'" ] ],
   [ 'import_fail.s26 rejects unresolved final hex', 'hex', 'import_fail.s26', 1,
      [ "imported symbol 'puts' was not resolved" ] ],
   [ 'selection.s26 rejects final STX abs,Y', 'hex', 'selection.s26', 1,
      [ 'STX requires a zero-page operand' ] ],
   [ 'test.s26 rejects unresolved expression', 'hex', 'test.s26',     1, [ 'unresolved expression' ] ],
   [ 'tiny.s26 rejects illegal modes',      'hex', 'tiny.s26',        1,
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
   $stem =~ s/\.s26\z//;
   my $out = File::Spec->catfile($tmp, sprintf('asm_fixture_%02d.out', $index));
   my $err = File::Spec->catfile($tmp, sprintf('asm_fixture_%02d.err', $index));
   my $product = File::Spec->catfile($tmp, sprintf('%s_%02d.%s', $stem, $index, ($mode eq 'hex') ? 'hex' : 'o26'));
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
