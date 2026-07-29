#!/usr/bin/env perl
# runner: perl @FILE@ @VCSC_CC1@ @TEST_ROOT@
# phase: compile
# timeout: 20
# expectexit: 0
# expectstdout: template hygiene tests passed

use strict;
use warnings;
use File::Spec;
use File::Temp qw(tempdir);

my ($cc1, $test_root) = @ARGV;
die "usage: $0 vcsc-cc1 test_root\n" if !defined $cc1 || !defined $test_root;

my @bad = (
   [object       => 'uint8_t forgotten;',                         "file-scope object 'forgotten'"],
   [function     => 'void forgotten(void) {}',                    "file-scope function 'forgotten'"],
   [typedef      => 'typedef uint8_t forgotten;',                 "file-scope typedef 'forgotten'"],
   [enum_tag     => 'enum forgotten { TEMPLATE_ok := 0 };',       "file-scope enum tag 'forgotten'"],
   [enum_constant=> 'enum TEMPLATE_enum { forgotten := 0 };',     "file-scope enum constant 'forgotten'"],
   [struct_tag   => 'struct forgotten { uint8_t member; };',      "file-scope struct tag 'forgotten'"],
   [union_tag    => 'union forgotten { uint8_t member; };',       "file-scope union tag 'forgotten'"],
   [table        => 'uint8_t forgotten[2];',                      "file-scope object 'forgotten'"],
   [asm_symbol   => 'inline void TEMPLATE_draw(void) {' . "\n" .
                    '   asm forgotten:' . "\n" .
                    '   asm nop;' . "\n" .
                    '}',                                          "source-visible assembler symbol 'forgotten'"],
);

sub write_file {
   my ($path, $text) = @_;
   open my $fh, '>', $path or die "write $path: $!";
   print {$fh} $text;
   close $fh;
}

for my $case (@bad) {
   my ($name, $body, $needle) = @$case;
   my $tmp = tempdir("VCSC_template_hygiene_${name}_XXXX", TMPDIR => 1, CLEANUP => 1);
   my $component = File::Spec->catfile($tmp, 'component.c26');
   my $main = File::Spec->catfile($tmp, 'main.c26');
   my $asm = File::Spec->catfile($tmp, 'out.s26');
   my $err = File::Spec->catfile($tmp, 'err.txt');

   write_file($component, "$body\n");
   write_file($main, <<'C26');
include "machine_6502.c26"
template "component.c26" as one
void main(void) {
}
C26

   my @cmd = ($cc1, '-quiet', '-I', $test_root, '-I', $tmp, $main, '-o', $asm);
   my $status = system(join(' ', map { quotemeta($_) } @cmd) . " 2>" . quotemeta($err));
   $status != 0 or die "$name: unqualified template definition unexpectedly compiled\n";
   open my $efh, '<', $err or die "read $err: $!";
   local $/;
   my $text = <$efh>;
   close $efh;
   index($text, 'template hygiene:') >= 0
      or die "$name: missing template-hygiene diagnostic\n$text";
   index($text, $needle) >= 0
      or die "$name: wrong definition-class diagnostic; expected '$needle'\n$text";
   index($text, "must use 'TEMPLATE' or the 'TEMPLATE_' prefix") >= 0
      or die "$name: missing required-prefix guidance\n$text";
}

{
   my $tmp = tempdir('VCSC_template_hygiene_positive_XXXX', TMPDIR => 1, CLEANUP => 1);
   my $shared = File::Spec->catfile($tmp, 'shared.c26');
   my $component = File::Spec->catfile($tmp, 'component.c26');
   my $main = File::Spec->catfile($tmp, 'main.c26');
   my $asm = File::Spec->catfile($tmp, 'out.s26');

   write_file($shared, <<'C26');
extern uint8_t shared_value;
typedef uint8_t shared_byte;
C26
   write_file($component, <<'C26');
include "shared.c26"
typedef shared_byte TEMPLATE_byte;
enum TEMPLATE_enum { TEMPLATE_zero := 0 };
struct TEMPLATE_struct { uint8_t member; };
union TEMPLATE_union { uint8_t member; };
TEMPLATE_byte TEMPLATE_table[2];
inline void TEMPLATE_draw(void) {
   uint8_t local;
   local := shared_value;
   asm @local:
   asm TEMPLATE_visible:
   asm nop
}
C26
   write_file($main, <<'C26');
include "machine_6502.c26"
template "component.c26" as first
template "component.c26" as second
uint8_t shared_value;
void main(void) {
   first_draw();
   second_draw();
}
C26
   my @cmd = ($cc1, '-quiet', '-I', $test_root, '-I', $tmp, $main, '-o', $asm);
   system(@cmd) == 0 or die "prefixed definitions or ordinary included shared declarations were rejected: @cmd\n";
}

print "template hygiene tests passed\n";
