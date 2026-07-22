#!/usr/bin/perl

use strict;
use warnings;
use File::Spec;
use File::Basename qw(basename dirname);
use File::Temp qw(tempdir tempfile);
use Cwd qw(abs_path getcwd);
use Getopt::Long qw(GetOptions);
use Text::ParseWords qw(shellwords);
use Time::HiRes qw(sleep);

$| = 1; # turns on autoflush
binmode STDOUT, ':encoding(UTF-8)';

my $FAIL = "\e[31mFAIL\e[0m";
my $PASS = "\e[32mpass\e[0m";
my $CLEAR = "\e[K";

my $GRAY = "\e[90m";
my $NOCOLOR = "\e[0m";
my @LINE = ( " ",
             "\x{258F}",
             "\x{258E}",
             "\x{258D}",
             "\x{258C}",
             "\x{258B}",
             "\x{258A}",
             "\x{2589}",
             "\x{2588}");

my $compile_only = 0;
my $e2e_only = 0;
my $help = 0;
GetOptions(
   'compile-only' => \$compile_only,
   'e2e-only' => \$e2e_only,
   'help' => \$help,
) or die usage();
die usage() if $help;
die usage() if $compile_only && $e2e_only;

my $test_root = abs_path('.');
my $repo_root = abs_path(File::Spec->catdir($test_root, '..'));

my $vcsc_cc1  = File::Spec->catfile($repo_root, 'compiler', 'vcsc-cc1');
my $vcsc = File::Spec->catfile($repo_root, 'driver', 'vcsc');
my $vcsc_as = File::Spec->catfile($repo_root, 'assembler', 'vcsc-as');
my $vcsc_ld  = File::Spec->catfile($repo_root, 'linker', 'vcsc-ld');
my $vcsc_ar  = File::Spec->catfile($repo_root, 'archiver', 'vcsc-ar');
my $vcsc_sim = File::Spec->catfile($repo_root, 'simulator', 'vcsc-sim');
my $runtime = File::Spec->catfile($repo_root, 'libraries', 'runtime', 'libvcsc.l26');
my $runtime_inc = File::Spec->catdir($repo_root, 'libraries', 'runtime');
my $generic_link_cfg = File::Spec->catfile($test_root, 'generic_6502.cfg');

my %tool_alias = (
   'vcsc-cc1'  => $vcsc_cc1,
   'vcsc' => $vcsc,
   'vcsc-as' => $vcsc_as,
   'vcsc-ld'  => $vcsc_ld,
   'vcsc-ar'  => $vcsc_ar,
   'vcsc-sim' => $vcsc_sim,
);

sub usage {
   return "usage: $0 [--compile-only] [--e2e-only] [test-file ...]\n";
}

sub slurp_file {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "[$FAIL] could not open $path: $!\n";
   local $/;
   my $data = <$fh>;
   close($fh);
   return $data;
}

sub write_text_file {
   my ($path, $text) = @_;
   open(my $fh, '>', $path) or die "[$FAIL] could not write $path: $!\n";
   print $fh $text;
   close($fh);
}

sub read_header_lines {
   my ($path) = @_;
   open(my $fh, '<', $path) or die "[$FAIL] could not open $path: $!\n";
   my @lines;
   while (my $line = <$fh>) {
      $line =~ s/[\x0a\x0d]//g;
      if ($line =~ /^\s*$/) {
         push @lines, $line;
         next;
      }
      last if $line !~ /^\s*(?:(?:\/\/)|#|;)/;
      push @lines, $line;
   }
   close($fh);
   return \@lines;
}

sub strip_comment_body {
   my ($line) = @_;
   return undef if $line !~ /^\s*(?:(?:\/\/)|#|;)\s?(.*)$/;
   return $1;
}

sub parse_words_safe {
   my ($file, $text) = @_;
   if ($text =~ /[;`]/) {
      die "[$FAIL] $file :: hey! no sneaky shell shenanigans !!!\n";
   }
   return grep { length($_) } shellwords($text);
}

sub parse_runner_from_header {
   my ($file, $header_lines) = @_;
   for my $line (@$header_lines) {
      my $body = strip_comment_body($line);
      next if !defined $body;
      if ($body =~ /^runner:\s*(.*?)\s*$/) {
         my @words = parse_words_safe($file, $1);
         return \@words if @words;
      }
      if ($body =~ /^(vcsc-cc1|vcsc|vcsc-as|vcsc-ld|vcsc-ar|vcsc-sim|perl|make|stdbuf)\b(.*)$/) {
         my @words = parse_words_safe($file, $body);
         return \@words if @words;
      }
   }
   return undef;
}

sub parse_directives {
   my ($path, $header_lines) = @_;
   my %meta = (
      expectasm => [],
      expectasmordered => [],
      forbidasm => [],
      expecterr => [],
      forbiderr => [],
      expectsim => [],
      expectsimerr => [],
      expectlinkerr => [],
      expectmap => [],
      expectfile => [],
      forbidfile => [],
      archive => [],
      archivegroup => [],
      object => [],
      linkcfg => undef,
      simcfg => undef,
      simargs => [],
      expectfail => 0,
      expectlinkfail => 0,
      expectexit => undef,
      phase => undef,
      timeout => 2,
      expectstdout => [],
      expectstdoutordered => [],
      forbidstdout => [],
      expectstderr => [],
      expectstderrordered => [],
      forbidstderr => [],
      expectstdoutexact => undef,
      expectstderrexact => undef,
   );

   for my $line (@$header_lines) {
      my $body = strip_comment_body($line);
      next if !defined $body;
      if ($body =~ /^expectasm:\s*(.*?)\s*$/) {
         push @{$meta{expectasm}}, $1;
      }
      elsif ($body =~ /^expectasmordered:\s*(.*?)\s*$/) {
         push @{$meta{expectasmordered}}, $1;
      }
      elsif ($body =~ /^forbidasm:\s*(.*?)\s*$/) {
         push @{$meta{forbidasm}}, $1;
      }
      elsif ($body =~ /^expecterr:\s*(.*?)\s*$/) {
         push @{$meta{expecterr}}, $1;
      }
      elsif ($body =~ /^forbiderr:\s*(.*?)\s*$/) {
         push @{$meta{forbiderr}}, $1;
      }
      elsif ($body =~ /^expectsim:\s*(.*?)\s*$/) {
         push @{$meta{expectsim}}, $1;
      }
      elsif ($body =~ /^expectsimerr:\s*(.*?)\s*$/) {
         push @{$meta{expectsimerr}}, $1;
      }
      elsif ($body =~ /^expectlinkerr:\s*(.*?)\s*$/) {
         push @{$meta{expectlinkerr}}, $1;
      }
      elsif ($body =~ /^expectmap:\s*(.*?)\s*$/) {
         push @{$meta{expectmap}}, $1;
      }
      elsif ($body =~ /^expectfile:\s*(\S+)\s+(.*?)\s*$/) {
         push @{$meta{expectfile}}, [$1, $2];
      }
      elsif ($body =~ /^forbidfile:\s*(\S+)\s+(.*?)\s*$/) {
         push @{$meta{forbidfile}}, [$1, $2];
      }
      elsif ($body =~ /^archive:\s*(.*?)\s*$/) {
         push @{$meta{archive}}, $1;
      }
      elsif ($body =~ /^archivegroup:\s*(\S+)\s+(.*?)\s*$/) {
         my ($group, $rest) = ($1, $2);
         my @members = grep { length($_) } split(/\s+/, $rest);
         push @{$meta{archivegroup}}, [$group, @members];
      }
      elsif ($body =~ /^object:\s*(.*?)\s*$/) {
         push @{$meta{object}}, $1;
      }
      elsif ($body =~ /^linkcfg:\s*(.*?)\s*$/) {
         $meta{linkcfg} = $1;
      }
      elsif ($body =~ /^simcfg:\s*(.*?)\s*$/) {
         $meta{simcfg} = $1;
      }
      elsif ($body =~ /^simargs:\s*(.*?)\s*$/) {
         push @{$meta{simargs}}, parse_words_safe($path, $1);
      }
      elsif ($body =~ /^expectfail\s*$/) {
         $meta{expectfail} = 1;
      }
      elsif ($body =~ /^expectlinkfail\s*$/) {
         $meta{expectlinkfail} = 1;
      }
      elsif ($body =~ /^expectexit:\s*(0x[0-9A-Fa-f]+|[0-9]+)\s*$/) {
         my $value = $1;
         $meta{expectexit} = ($value =~ /^0x/i) ? hex($value) : int($value);
      }
      elsif ($body =~ /^phase:\s*(compile|e2e|any)\s*$/) {
         $meta{phase} = $1;
      }
      elsif ($body =~ /^timeout:\s*([0-9]+)\s*$/) {
         $meta{timeout} = int($1);
      }
      elsif ($body =~ /^expectstdout:\s*(.*?)\s*$/) {
         push @{$meta{expectstdout}}, $1;
      }
      elsif ($body =~ /^expectstdoutordered:\s*(.*?)\s*$/) {
         push @{$meta{expectstdoutordered}}, $1;
      }
      elsif ($body =~ /^forbidstdout:\s*(.*?)\s*$/) {
         push @{$meta{forbidstdout}}, $1;
      }
      elsif ($body =~ /^expectstderr:\s*(.*?)\s*$/) {
         push @{$meta{expectstderr}}, $1;
      }
      elsif ($body =~ /^expectstderrordered:\s*(.*?)\s*$/) {
         push @{$meta{expectstderrordered}}, $1;
      }
      elsif ($body =~ /^forbidstderr:\s*(.*?)\s*$/) {
         push @{$meta{forbidstderr}}, $1;
      }
      elsif ($body =~ /^expectstdoutexact:\s*(.*?)\s*$/) {
         $meta{expectstdoutexact} = $1;
      }
      elsif ($body =~ /^expectstderrexact:\s*(.*?)\s*$/) {
         $meta{expectstderrexact} = $1;
      }
   }
   return \%meta;
}

sub is_e2e_case {
   my ($meta) = @_;
   return 1 if defined($meta->{phase}) && $meta->{phase} eq 'e2e';
   return 0 if defined($meta->{phase}) && $meta->{phase} eq 'compile';
   return scalar(@{$meta->{expectsim}})
      || scalar(@{$meta->{expectlinkerr}})
      || scalar(@{$meta->{expectmap}})
      || scalar(@{$meta->{archive}})
      || scalar(@{$meta->{archivegroup}})
      || scalar(@{$meta->{object}})
      || defined($meta->{linkcfg})
      || defined($meta->{simcfg})
      || scalar(@{$meta->{simargs}})
      || scalar(@{$meta->{expectsimerr}})
      || $meta->{expectlinkfail}
      || defined($meta->{expectexit});
}

sub expand_placeholders {
   my ($text, $ctx) = @_;
   my $expanded = $text;
   for my $key (keys %$ctx) {
      my $value = defined($ctx->{$key}) ? $ctx->{$key} : '';
      $expanded =~ s/\Q$key\E/$value/g;
   }
   return $expanded;
}

sub expand_tokens {
   my ($tokens, $ctx) = @_;
   my @expanded;
   for my $token (@$tokens) {
      my $value = expand_placeholders($token, $ctx);
      $value = $tool_alias{$value} if exists $tool_alias{$value};
      push @expanded, $value;
   }
   return @expanded;
}

sub run_cmd {
   my ($cmd, $out_path, $err_path) = @_;
   my $pid = fork();
   die "[$FAIL] fork failed: $!\n" if !defined $pid;

   if ($pid == 0) {
      open(STDOUT, '>', $out_path) or die "open stdout failed: $!\n";
      open(STDERR, '>', $err_path) or die "open stderr failed: $!\n";
      exec @$cmd;
      die "exec failed for @$cmd: $!\n";
   }

   waitpid($pid, 0);
   return ($? >> 8, $? & 127);
}

sub run_cmd_with_timeout {
   my ($cmd, $out_path, $err_path, $seconds) = @_;
   my $pid = fork();
   die "[$FAIL] fork failed: $!\n" if !defined $pid;

   if ($pid == 0) {
      open(STDOUT, '>', $out_path) or die "open stdout failed: $!\n";
      open(STDERR, '>', $err_path) or die "open stderr failed: $!\n";
      exec @$cmd;
      die "exec failed for @$cmd: $!\n";
   }

   my $timed_out = 0;
   my ($exit_code, $signal) = (0, 0);
   eval {
      local $SIG{ALRM} = sub { die "TIMEOUT\n"; };
      alarm $seconds;
      waitpid($pid, 0);
      alarm 0;
      $exit_code = $? >> 8;
      $signal = $? & 127;
   };
   if ($@) {
      if ($@ eq "TIMEOUT\n") {
         $timed_out = 1;
         kill 'TERM', $pid;
         select(undef, undef, undef, 0.2);
         kill 'KILL', $pid;
         waitpid($pid, 0);
         $exit_code = $? >> 8;
         $signal = $? & 127;
      }
      else {
         die $@;
      }
   }

   return ($timed_out, $exit_code, $signal);
}

sub fail_result {
   my ($message) = @_;
   return { ok => 0, message => $message };
}

sub pass_result {
   return { ok => 1 };
}

sub require_substrings_result {
   my ($haystack, $needles, $label) = @_;
   for my $needle (@$needles) {
      if (index($haystack, $needle) < 0) {
         return "$label missing fragment: $needle";
      }
   }
   return undef;
}

sub require_ordered_substrings_result {
   my ($haystack, $needles, $label) = @_;
   my $start = 0;
   for my $needle (@$needles) {
      my $pos = index($haystack, $needle, $start);
      if ($pos < 0) {
         return "$label missing ordered fragment: $needle";
      }
      $start = $pos + length($needle);
   }
   return undef;
}

sub require_absent_substrings_result {
   my ($haystack, $needles, $label) = @_;
   for my $needle (@$needles) {
      if (index($haystack, $needle) >= 0) {
         return "$label unexpected fragment: $needle";
      }
   }
   return undef;
}

sub check_exact_result {
   my ($got, $want, $label) = @_;
   return undef if !defined $want;
   return undef if $got eq $want;
   return "$label exact mismatch";
}

sub require_file_expectations_result {
   my ($meta, $ctx) = @_;
   for my $entry (@{$meta->{expectfile}}) {
      my ($relpath, $needle) = @$entry;
      my $path = expand_placeholders($relpath, $ctx);
      $path = File::Spec->catfile($test_root, $path) if !File::Spec->file_name_is_absolute($path);
      my $text = slurp_file($path);
      if (index($text, expand_placeholders($needle, $ctx)) < 0) {
         return "missing file fragment in $relpath: $needle";
      }
   }
   for my $entry (@{$meta->{forbidfile}}) {
      my ($relpath, $needle) = @$entry;
      my $path = expand_placeholders($relpath, $ctx);
      $path = File::Spec->catfile($test_root, $path) if !File::Spec->file_name_is_absolute($path);
      my $text = slurp_file($path);
      if (index($text, expand_placeholders($needle, $ctx)) >= 0) {
         return "unexpected file fragment in $relpath: $needle";
      }
   }
   return undef;
}

sub compile_n_to_object {
   my ($src_name, $runner_args, $tmp, $test_name) = @_;
   my ($stem) = $src_name =~ /^(.*)\.c26$/;
   my $src_path = File::Spec->catfile($test_root, $src_name);
   my $s_path   = File::Spec->catfile($tmp, "$stem.s");
   my $o_path   = File::Spec->catfile($tmp, "$stem.o26");
   my $out_path = File::Spec->catfile($tmp, "$stem.compile.out");
   my $err_path = File::Spec->catfile($tmp, "$stem.compile.err");
   my @cmd = ($vcsc_cc1, '-quiet', @$runner_args, $src_path, '-o', $s_path, '-dumpbase', $src_name, '-dumpbase-ext', '.c26', '-dumpdir', $tmp);
   my ($exit_code) = run_cmd(\@cmd, $out_path, $err_path);
   if ($exit_code != 0) {
      return (undef, "$test_name extra compile exit code $exit_code\n" . join(' ', @cmd) . "\n" . slurp_file($err_path));
   }
   my @asm_cmd = ($vcsc_as, '-I', $runtime_inc, '-o', $o_path, $s_path);
   my ($asm_exit) = run_cmd(\@asm_cmd, File::Spec->catfile($tmp, "$stem.asm.out"), File::Spec->catfile($tmp, "$stem.asm.err"));
   if ($asm_exit != 0) {
      return (undef, "$test_name extra assemble exit code $asm_exit\n" . join(' ', @asm_cmd) . "\n" . slurp_file(File::Spec->catfile($tmp, "$stem.asm.err")));
   }
   return ($o_path, undef);
}

sub run_compile_case {
   my ($case) = @_;
   my $file = $case->{name};
   my $runner_args = $case->{runner_args};
   my $meta = $case->{meta};

   my ($outfh, $outfile) = tempfile('test_output_XXXX', UNLINK => 1);
   my ($errfh, $errfile) = tempfile('test_error_XXXX', UNLINK => 1);
   close($outfh);
   close($errfh);

   my @cmd = ($vcsc_cc1, '-quiet', @$runner_args, $case->{path});
   my ($exit_code) = run_cmd(\@cmd, $outfile, $errfile);

   if ($meta->{expectfail}) {
      if ($exit_code == 0) {
         return fail_result("expected compiler failure but exited 0\n" . join(' ', @cmd));
      }
   }
   elsif ($exit_code != 0) {
      return fail_result("compiler exit code $exit_code\n" . join(' ', @cmd) . "\n" . slurp_file($errfile));
   }

   if (@{$meta->{expectasm}} || @{$meta->{expectasmordered}} || @{$meta->{forbidasm}}) {
      my $asm = slurp_file($outfile);
      my $err = require_substrings_result($asm, $meta->{expectasm}, 'assembly');
      return fail_result($err) if defined $err;
      $err = require_ordered_substrings_result($asm, $meta->{expectasmordered}, 'assembly');
      return fail_result($err) if defined $err;
      $err = require_absent_substrings_result($asm, $meta->{forbidasm}, 'assembly');
      return fail_result($err) if defined $err;
   }

   my $stderr = slurp_file($errfile);
   my $ctx = { '@REPO@' => $repo_root, '@TEST_ROOT@' => $test_root, '@FILE@' => $case->{path}, '@FILEDIR@' => dirname($case->{path}), '@TMP@' => dirname($outfile), '@RUNTIME@' => $runtime, '@RUNTIME_INC@' => $runtime_inc };
   my $err = require_substrings_result($stderr, $meta->{expecterr}, 'stderr');
   return fail_result($err) if defined $err;
   $err = require_absent_substrings_result($stderr, $meta->{forbiderr}, 'stderr');
   return fail_result($err) if defined $err;
   $err = require_file_expectations_result($meta, $ctx);
   return fail_result($err) if defined $err;
   return pass_result();
}

sub run_e2e_case {
   my ($case) = @_;
   my $file = $case->{name};
   my $runner_args = $case->{runner_args};
   my $meta = $case->{meta};
   for my $tool ($vcsc_cc1, $vcsc_as, $vcsc_ld, $vcsc_ar, $vcsc_sim, $runtime, $generic_link_cfg) {
      return fail_result("missing required file: $tool") if !-e $tool;
   }

   my $tmp = tempdir("n_e2e_${file}_XXXX", TMPDIR => 1, CLEANUP => 1);
   my $ctx = {
      '@REPO@' => $repo_root,
      '@TEST_ROOT@' => $test_root,
      '@FILE@' => $case->{path},
      '@FILEDIR@' => dirname($case->{path}),
      '@TMP@' => $tmp,
      '@RUNTIME@' => $runtime,
      '@RUNTIME_INC@' => $runtime_inc,
      '@GENERIC_LINK_CFG@' => $generic_link_cfg,
   };
   my @compiled_objects;
   my @archives;

   my ($stem) = $file =~ /^(.*)\.c26$/;
   my $main_s   = File::Spec->catfile($tmp, "$stem.s");
   my $main_o26 = File::Spec->catfile($tmp, "$stem.o26");
   my $hex_path = File::Spec->catfile($tmp, 'out.hex');
   my $map_path = File::Spec->catfile($tmp, 'out.map');

   my $compile_out = File::Spec->catfile($tmp, 'compile.out');
   my $compile_err = File::Spec->catfile($tmp, 'compile.err');
   my @compile_cmd = ($vcsc_cc1, '-quiet', @$runner_args, $case->{path}, '-o', $main_s, '-dumpbase', $file, '-dumpbase-ext', '.c26', '-dumpdir', $tmp);
   my ($compile_exit) = run_cmd(\@compile_cmd, $compile_out, $compile_err);
   my $compile_stderr = slurp_file($compile_err);

   if ($meta->{expectfail}) {
      if ($compile_exit == 0) {
         return fail_result("expected compiler failure but exited 0\n" . join(' ', @compile_cmd));
      }
      my $err = require_substrings_result($compile_stderr, $meta->{expecterr}, 'stderr');
      return fail_result($err) if defined $err;
      return pass_result();
   }

   if ($compile_exit != 0) {
      return fail_result("compiler exit code $compile_exit\n" . join(' ', @compile_cmd) . "\n" . $compile_stderr);
   }

   my @asm_cmd = ($vcsc_as, '-I', $runtime_inc, '-o', $main_o26, $main_s);
   my ($asm_exit) = run_cmd(\@asm_cmd, File::Spec->catfile($tmp, 'main_asm.out'), File::Spec->catfile($tmp, 'main_asm.err'));
   if ($asm_exit != 0) {
      return fail_result("assembler exit code $asm_exit\n" . join(' ', @asm_cmd) . "\n" . slurp_file(File::Spec->catfile($tmp, 'main_asm.err')));
   }
   push @compiled_objects, $main_o26;

   for my $obj_src_name (@{$meta->{object}}) {
      my ($obj, $obj_err) = compile_n_to_object($obj_src_name, $runner_args, $tmp, $file);
      return fail_result($obj_err) if defined $obj_err;
      push @compiled_objects, $obj;
   }

   for my $arc_src_name (@{$meta->{archive}}) {
      my ($stem2) = $arc_src_name =~ /^(.*)\.c26$/;
      my ($o_path, $obj_err) = compile_n_to_object($arc_src_name, $runner_args, $tmp, $file);
      return fail_result($obj_err) if defined $obj_err;
      my $a_path = File::Spec->catfile($tmp, "$stem2.l26");
      my @ncmd = ($vcsc_ar, 'rcs', $a_path, $o_path);
      my ($nexit) = run_cmd(\@ncmd, File::Spec->catfile($tmp, "$stem2.vcsc-ar.out"), File::Spec->catfile($tmp, "$stem2.vcsc-ar.err"));
      if ($nexit != 0) {
         return fail_result("archive creation exit code $nexit\n" . join(' ', @ncmd) . "\n" . slurp_file(File::Spec->catfile($tmp, "$stem2.vcsc-ar.err")));
      }
      push @archives, $a_path;
   }

   if (@{$meta->{archivegroup}}) {
      my %groups;
      for my $entry (@{$meta->{archivegroup}}) {
         my ($group, @members) = @$entry;
         push @{$groups{$group}}, @members;
      }
      for my $group (sort keys %groups) {
         my @group_objects;
         for my $src_name (@{$groups{$group}}) {
            my ($obj, $obj_err) = compile_n_to_object($src_name, $runner_args, $tmp, $file);
            return fail_result($obj_err) if defined $obj_err;
            push @group_objects, $obj;
         }
         my $archive_name = $group;
         $archive_name .= '.l26' if $archive_name !~ /\.l26$/;
         my $a_path = File::Spec->catfile($tmp, $archive_name);
         my @ncmd = ($vcsc_ar, 'rcs', $a_path, @group_objects);
         my ($nexit) = run_cmd(\@ncmd, File::Spec->catfile($tmp, "$group.vcsc-ar.out"), File::Spec->catfile($tmp, "$group.vcsc-ar.err"));
         if ($nexit != 0) {
            return fail_result("archivegroup creation exit code $nexit\n" . join(' ', @ncmd) . "\n" . slurp_file(File::Spec->catfile($tmp, "$group.vcsc-ar.err")));
         }
         push @archives, $a_path;
      }
   }

   my @link_cmd = ($vcsc_ld, '-o', $hex_path, '-Map', $map_path, '-T',
      defined($meta->{linkcfg})
         ? File::Spec->catfile($test_root, $meta->{linkcfg})
         : $generic_link_cfg);
   push @link_cmd, @compiled_objects, @archives, $runtime;
   my $link_out = File::Spec->catfile($tmp, 'link.out');
   my $link_err = File::Spec->catfile($tmp, 'link.err');
   my ($link_exit) = run_cmd(\@link_cmd, $link_out, $link_err);
   my $link_stderr = slurp_file($link_err);
   if ($meta->{expectlinkfail}) {
      if ($link_exit == 0) {
         return fail_result("expected link failure but linker exited 0\n" . join(' ', @link_cmd));
      }
      my $err = require_substrings_result($link_stderr, $meta->{expectlinkerr}, 'link stderr');
      return fail_result($err) if defined $err;
      return pass_result();
   }
   if ($link_exit != 0) {
      return fail_result("linker exit code $link_exit\n" . join(' ', @link_cmd) . "\n" . $link_stderr);
   }

   if (@{$meta->{expectmap}}) {
      my $map_text = slurp_file($map_path);
      my $err = require_substrings_result($map_text, $meta->{expectmap}, 'map');
      return fail_result($err) if defined $err;
   }

   my $sim_out = File::Spec->catfile($tmp, 'sim.out');
   my $sim_err = File::Spec->catfile($tmp, 'sim.err');
   my @sim_cmd = ('stdbuf', '-o0', $vcsc_sim, @{$meta->{simargs}}, $hex_path);
   if (defined $meta->{simcfg}) {
      push @sim_cmd, '-T', File::Spec->catfile($test_root, $meta->{simcfg});
   }
   my ($timed_out, $sim_exit, $sim_sig) = run_cmd_with_timeout(\@sim_cmd, $sim_out, $sim_err, $meta->{timeout});
   my $sim_stdout = slurp_file($sim_out);
   my $sim_stderr = slurp_file($sim_err);

   if (defined $meta->{expectexit}) {
      if ($timed_out) {
         return fail_result("simulator timed out before expected exit $meta->{expectexit}\n" . join(' ', @sim_cmd) . "\n" . $sim_stderr);
      }
      if ($sim_exit != $meta->{expectexit}) {
         return fail_result("simulator exit code $sim_exit signal $sim_sig expected $meta->{expectexit}\n" . join(' ', @sim_cmd) . "\n" . $sim_stderr);
      }
   }
   elsif ($sim_exit != 0) {
      return fail_result("simulator exit code $sim_exit signal $sim_sig\n" . join(' ', @sim_cmd) . "\n" . $sim_stderr);
   }

   my $err = require_substrings_result($sim_stdout, $meta->{expectsim}, 'simulator output');
   return fail_result($err) if defined $err;
   $err = require_substrings_result($sim_stderr, $meta->{expectsimerr}, 'simulator stderr');
   return fail_result($err) if defined $err;
   $err = require_file_expectations_result($meta, $ctx);
   return fail_result($err) if defined $err;
   return pass_result();
}

sub run_generic_case {
   my ($case) = @_;
   my $meta = $case->{meta};
   my $tmp = tempdir("n_generic_XXXX", TMPDIR => 1, CLEANUP => 1);
   my $ctx = {
      '@REPO@' => $repo_root,
      '@TEST_ROOT@' => $test_root,
      '@FILE@' => $case->{path},
      '@FILEDIR@' => dirname($case->{path}),
      '@TMP@' => $tmp,
      '@RUNTIME@' => $runtime,
      '@RUNTIME_INC@' => $runtime_inc,
      '@GENERIC_LINK_CFG@' => $generic_link_cfg,
      '@VCSC_CC1@' => $vcsc_cc1,
      '@VCSC@' => $vcsc,
      '@VCSC_AS@' => $vcsc_as,
      '@VCSC_LD@' => $vcsc_ld,
      '@VCSC_AR@' => $vcsc_ar,
      '@VCSC_SIM@' => $vcsc_sim,
   };
   my @cmd = expand_tokens($case->{runner_words}, $ctx);
   my $out_path = File::Spec->catfile($tmp, 'stdout.txt');
   my $err_path = File::Spec->catfile($tmp, 'stderr.txt');
   my ($timed_out, $exit_code, $signal) = run_cmd_with_timeout(\@cmd, $out_path, $err_path, $meta->{timeout});
   my $stdout = slurp_file($out_path);
   my $stderr = slurp_file($err_path);

   if ($timed_out) {
      return fail_result("command timed out\n" . join(' ', @cmd));
   }

   my $expected_exit = defined($meta->{expectexit}) ? $meta->{expectexit} : 0;
   if ($exit_code != $expected_exit) {
      return fail_result("command exit code $exit_code signal $signal expected $expected_exit\n" . join(' ', @cmd) . "\n" . $stderr);
   }

   my $err = require_substrings_result($stdout, $meta->{expectstdout}, 'stdout');
   return fail_result($err) if defined $err;
   $err = require_ordered_substrings_result($stdout, $meta->{expectstdoutordered}, 'stdout');
   return fail_result($err) if defined $err;
   $err = require_absent_substrings_result($stdout, $meta->{forbidstdout}, 'stdout');
   return fail_result($err) if defined $err;
   $err = check_exact_result($stdout, $meta->{expectstdoutexact}, 'stdout');
   return fail_result($err) if defined $err;
   $err = require_substrings_result($stderr, $meta->{expectstderr}, 'stderr');
   return fail_result($err) if defined $err;
   $err = require_ordered_substrings_result($stderr, $meta->{expectstderrordered}, 'stderr');
   return fail_result($err) if defined $err;
   $err = require_absent_substrings_result($stderr, $meta->{forbidstderr}, 'stderr');
   return fail_result($err) if defined $err;
   $err = check_exact_result($stderr, $meta->{expectstderrexact}, 'stderr');
   return fail_result($err) if defined $err;
   $err = require_file_expectations_result($meta, $ctx);
   return fail_result($err) if defined $err;
   return pass_result();
}

sub load_case {
   my ($path) = @_;
   my $header_lines = read_header_lines($path);
   my $runner_words = parse_runner_from_header($path, $header_lines);
   return undef if !defined $runner_words;
   my $meta = parse_directives($path, $header_lines);
   my $name = File::Spec->abs2rel($path, $test_root);
   my $is_vcsc_source = ($path =~ /\.c26$/);
   my $kind = $is_vcsc_source ? (is_e2e_case($meta) ? 'vcsc-e2e' : 'vcsc-compile') : 'generic';
   my @runner_words_copy = @$runner_words;
   my @runner_args = @runner_words_copy;
   if ($is_vcsc_source && @runner_args && $runner_args[0] eq 'vcsc-cc1') {
      shift @runner_args;
   }
   return {
      path => $path,
      name => $name,
      runner_words => $runner_words,
      runner_args => \@runner_args,
      meta => $meta,
      kind => $kind,
   };
}

sub should_include_case {
   my ($case) = @_;
   my $phase = $case->{meta}->{phase};
   my $is_e2e = ($case->{kind} eq 'vcsc-e2e') || ($case->{kind} eq 'generic' && (!defined($phase) || $phase eq 'e2e'));
   $is_e2e = 0 if defined($phase) && $phase eq 'compile';
   return 0 if $compile_only && $is_e2e;
   return 0 if $e2e_only && !$is_e2e;
   return 1;
}

sub supported_test_filename {
   my ($name) = @_;
   return ($name =~ /\.(?:c26|test)$/);
}

sub resolve_requested_paths {
   my (@args) = @_;
   return () if !@args;
   my @resolved;
   for my $arg (@args) {
      my @candidates;
      push @candidates, abs_path($arg) if -e $arg;
      my $under_test = File::Spec->catfile($test_root, $arg);
      push @candidates, abs_path($under_test) if -e $under_test;
      my %seen;
      @candidates = grep { defined($_) && !$seen{$_}++ } @candidates;
      die "[$FAIL] could not find requested test path: $arg\n" if !@candidates;
      for my $candidate (@candidates) {
         if (-d $candidate) {
            opendir(my $dh, $candidate) or die "[$FAIL] could not open $candidate: $!\n";
            my @names = sort grep { supported_test_filename($_) && -f File::Spec->catfile($candidate, $_) } readdir($dh);
            closedir($dh);
            push @resolved, map { File::Spec->catfile($candidate, $_) } @names;
         }
         else {
            push @resolved, $candidate;
         }
      }
   }
   my %seen;
   return grep { !$seen{$_}++ } @resolved;
}

sub discover_default_paths {
   opendir(my $dh, $test_root) or die "[$FAIL] could not open $test_root: $!\n";
   my @paths = sort map { File::Spec->catfile($test_root, $_) }
      grep { supported_test_filename($_) && -f File::Spec->catfile($test_root, $_) }
      readdir($dh);
   closedir($dh);
   return @paths;
}

sub progress {
   my ($num, $den) = @_;
   my $nubs = int($num * 128 / $den);
   my $terms = 0;
   my $ret = "\x{2595}$GRAY";

   if ($nubs == 0) {
      $nubs = 1;
   }

   while ($nubs >= 8) {
      $ret .= $LINE[8];
      $nubs -= 8;
      $terms += 8;
   }

   if ($nubs) {
      $ret .= $LINE[$nubs];
      $nubs = 0;
      $terms += 8;
   }

   while ($terms < 128) {
      $ret .= $LINE[0];
      $terms += 8;
   }

   $ret .= "$NOCOLOR\x{258F}" . sprintf("%3d%%", int($num * 100 / $den));

   return $ret;
}

my @requested_paths = @ARGV ? resolve_requested_paths(@ARGV) : discover_default_paths();
my @cases;
for my $path (@requested_paths) {
   my $case = load_case($path);
   if (!defined $case) {
      die "[$FAIL] requested file is not a runnable test: " . File::Spec->abs2rel($path, $test_root) . "\n" if @ARGV;
      next;
   }
   next if !should_include_case($case);
   push @cases, $case;
}

die "[$FAIL] no tests selected\n" if !@cases;

my @failures;
my $total = scalar(@cases);
my $index = 0;
my $passed = 0;
my $pre = "";
my $post = "";

if (-t STDOUT) {
   $pre = "\r";
}
else {
   $post = "\n";
}

for my $case (@cases) {
   $index++;
   my $result;
   if ($case->{kind} eq 'vcsc-compile') {
      $result = run_compile_case($case);
   }
   elsif ($case->{kind} eq 'vcsc-e2e') {
      $result = run_e2e_case($case);
   }
   else {
      $result = run_generic_case($case);
   }

   my $progress = progress($index, $total);

   if ($result->{ok}) {
      $passed++;
      printf("$pre%s [%*d/%d] [%s] %s%s$post", $progress, length($total), $index, $total, $PASS, $case->{name}, $CLEAR);
   }
   else {
      push @failures, { name => $case->{name}, message => $result->{message} };
      my $first = $result->{message};
      $first =~ s/\n.*//s;
      printf("$pre%s [%*d/%d] [%s] %s :: %s\n", $progress, length($total), $index, $total, $FAIL, $case->{name}, $first);
   }
   if (-t STDOUT) {
      sleep 0.05;
   }
}

print "\nSummary: $passed passed, " . scalar(@failures) . " failed, $total total\n";
if (@failures) {
   print "Failures:\n";
   for my $failure (@failures) {
      print "- $failure->{name}\n";
      my $msg = $failure->{message};
      $msg =~ s/^/    /mg;
      print "$msg\n";
   }
   exit 1;
}

exit 0;
