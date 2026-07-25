#!/usr/bin/perl
use strict;
use warnings;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Spec;
use IPC::Open3;
use Symbol qw(gensym);

sub write_file {
   my ($path, $text) = @_;
   open(my $fh, '>:raw', $path) or die "write $path: $!\n";
   print {$fh} $text;
   close($fh) or die "close $path: $!\n";
}
sub run_capture {
   my (@cmd) = @_;
   my $err = gensym;
   my $pid = open3(my $in, my $out, $err, @cmd);
   close($in);
   local $/;
   my $stdout = <$out> // '';
   my $stderr = <$err> // '';
   waitpid($pid, 0);
   return ($? >> 8, $? & 127, $stdout, $stderr);
}
sub require_ok {
   my ($label, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit == 0 && !$sig or die "$label failed\n@cmd\n$out$err";
   return ($out, $err);
}
sub require_failed {
   my ($label, $re, @cmd) = @_;
   my ($exit, $sig, $out, $err) = run_capture(@cmd);
   $exit != 0 && !$sig or die "$label unexpectedly succeeded\n@cmd\n$out$err";
   $err =~ $re or die "$label lacked expected diagnostic\n$err";
   return $err;
}

my $repo = abs_path(shift @ARGV // die "usage: $0 REPO TMP\n");
my $tmp = shift @ARGV // die "usage: $0 REPO TMP\n";
@ARGV and die "usage: $0 REPO TMP\n";
make_path($tmp);
$tmp = abs_path($tmp);

my $as = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
my $ld = File::Spec->catfile($repo, 'linker', 'vcsc-ld');
my $ar = File::Spec->catfile($repo, 'archiver', 'vcsc-ar');
my $cfg = File::Spec->catfile($repo, 'test', 'generic_6502.cfg');
my $runtime = File::Spec->catfile($repo, 'libraries', 'runtime', 'libvcsc.l26');

my $component_s = File::Spec->catfile($tmp, 'component.s26');
my $component_o = File::Spec->catfile($tmp, 'component.o26');
write_file($component_s, <<'ASM');
.segment "CODE"
.export anchor
.export __sbpmeta$F$anchor
__sbpmeta$F$anchor = 0
.export __contractmeta$V1$function$require$req_fn$owner$component$decl$componentQ2Ec26$L10$C2$invoke$none$type$void$void
__contractmeta$V1$function$require$req_fn$owner$component$decl$componentQ2Ec26$L10$C2$invoke$none$type$void$void = 0
.export __contractmeta$V1$function$recommend$rec_fn$owner$component$decl$componentQ2Ec26$L11$C2$invoke$none$type$void$void
__contractmeta$V1$function$recommend$rec_fn$owner$component$decl$componentQ2Ec26$L11$C2$invoke$none$type$void$void = 0
.export __contractmeta$V1$object$require$req_obj$owner$component$decl$componentQ2Ec26$L12$C2$invoke$none$type$u8$unsignedQ20byte
__contractmeta$V1$object$require$req_obj$owner$component$decl$componentQ2Ec26$L12$C2$invoke$none$type$u8$unsignedQ20byte = 0
.export __contractmeta$V1$object$recommend$rec_obj$owner$component$decl$componentQ2Ec26$L13$C2$invoke$none$type$u8$unsignedQ20byte
__contractmeta$V1$object$recommend$rec_obj$owner$component$decl$componentQ2Ec26$L13$C2$invoke$none$type$u8$unsignedQ20byte = 0
.proc anchor
   rts
.endproc
ASM
require_ok('assemble component', $as, '-o', $component_o, $component_s);

sub make_main {
   my ($name, $owner, $extra_nodes, $extra_edges, $uses) = @_;
   my $s = File::Spec->catfile($tmp, "$name.s26");
   my $o = File::Spec->catfile($tmp, "$name.o26");
   write_file($s, qq{.segment "CODE"\n.import anchor\n.export main\n.export __sbpmeta\$F\$main\n__sbpmeta\$F\$main = 0\n.export __sbpmeta\$E\$main\$anchor\n__sbpmeta\$E\$main\$anchor = 0\n$extra_nodes$extra_edges$uses.proc main\n   jsr anchor\n   rts\n.endproc\n});
   require_ok("assemble $name", $as, '-o', $o, $s);
   return $o;
}

my $good_uses = <<'ASM';
.export __usemeta$V1$call$req_fn$owner$app$function$main$use$appQ2Ec26$L20$C3$invoke$none
__usemeta$V1$call$req_fn$owner$app$function$main$use$appQ2Ec26$L20$C3$invoke$none = 0
.export __usemeta$V1$write$req_obj$owner$app$function$main$use$appQ2Ec26$L21$C3$invoke$none
__usemeta$V1$write$req_obj$owner$app$function$main$use$appQ2Ec26$L21$C3$invoke$none = 0
ASM
my $good = make_main('good', 'app', '', '', $good_uses);
my (undef, $good_err) = require_ok('reachable external uses', $ld, '-T', $cfg,
   '-o', File::Spec->catfile($tmp, 'good.bin'), $good, $component_o, $runtime);
$good_err =~ /warning: recommended function 'rec_fn' not used/
   or die "missing recommended-function warning\n$good_err";
$good_err =~ /warning: recommended variable 'rec_obj' not used/
   or die "missing recommended-variable warning\n$good_err";
$good_err !~ /required .* not used/ or die "reachable external use did not satisfy requirement\n$good_err";

my $none = make_main('none', 'app', '', '', '');
my $none_err = require_failed('unused requirements', qr/required function 'req_fn' not used/,
   $ld, '-T', $cfg, '-o', File::Spec->catfile($tmp, 'none.bin'), $none, $component_o, $runtime);
$none_err =~ /component\.c26:12:2: vcsc-ld: required variable 'req_obj' not used/
   or die "missing required-object source diagnostic\n$none_err";

my $internal_uses = $good_uses;
$internal_uses =~ s/\$owner\$app\$/\$owner\$component\$/g;
my $internal = make_main('internal', 'component', '', '', $internal_uses);
require_failed('same-owner uses', qr/required function 'req_fn' not used/,
   $ld, '-T', $cfg, '-o', File::Spec->catfile($tmp, 'internal.bin'), $internal, $component_o, $runtime);

my $dead_nodes = ".export __sbpmeta\$F\$dead\n__sbpmeta\$F\$dead = 0\n";
my $dead_edges = ".export __sbpmeta\$E\$dead\$req_fn\n__sbpmeta\$E\$dead\$req_fn = 0\n";
my $dead_uses = $good_uses;
$dead_uses =~ s/\$function\$main\$/\$function\$dead\$/g;
my $dead = make_main('dead', 'app', $dead_nodes, $dead_edges, $dead_uses);
require_failed('unreachable uses', qr/required function 'req_fn' not used/,
   $ld, '-T', $cfg, '-o', File::Spec->catfile($tmp, 'dead.bin'), $dead, $component_o, $runtime);

my $archive = File::Spec->catfile($tmp, 'component.l26');
require_ok('create archive', $ar, 'rcs', $archive, $component_o);
my $plain_s = File::Spec->catfile($tmp, 'plain.s26');
my $plain_o = File::Spec->catfile($tmp, 'plain.o26');
write_file($plain_s, <<'ASM');
.segment "CODE"
.export main
.export __sbpmeta$F$main
__sbpmeta$F$main = 0
.proc main
   rts
.endproc
ASM
require_ok('assemble plain', $as, '-o', $plain_o, $plain_s);
my (undef, $archive_err) = require_ok('unselected archive is silent', $ld, '-T', $cfg,
   '-o', File::Spec->catfile($tmp, 'archive.bin'), $plain_o, $archive, $runtime);
$archive_err !~ /req_fn|req_obj/ or die "unselected archive contract produced diagnostics\n$archive_err";

require_failed('selected archive enforces contract', qr/required function 'req_fn' not used/,
   $ld, '-T', $cfg, '-o', File::Spec->catfile($tmp, 'selected.bin'), $none, $archive, $runtime);

print "linker enforces reachable external declaration-use contracts\n";
