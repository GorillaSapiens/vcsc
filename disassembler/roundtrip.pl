#!/usr/bin/env perl
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex);
use File::Basename qw(basename dirname);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long qw(GetOptions);
use IPC::Open3;
use Symbol qw(gensym);

sub usage {
    my ($fh) = @_;
    print {$fh} "usage: $0 [--stella STELLA] [--stella-strict] INPUT_DIR OUTPUT_DIR\n";
}

my $stella;
my $stella_strict = 0;
GetOptions(
    'stella=s'       => \$stella,
    'stella-strict!' => \$stella_strict,
) or do { usage(*STDERR); exit 2; };
@ARGV == 2 or do { usage(*STDERR); exit 2; };
$stella_strict && !defined($stella)
    and die "--stella-strict requires --stella\n";
my ($input_arg, $output_arg) = @ARGV;
-d $input_arg or die "$input_arg: input directory does not exist\n";

if (!-e $output_arg) {
    make_path($output_arg) or die "could not create $output_arg\n";
}
-d $output_arg or die "$output_arg: output path is not a directory\n";

my $input_dir = abs_path($input_arg);
my $output_dir = abs_path($output_arg);
defined $input_dir && defined $output_dir or die "could not resolve directories\n";
$input_dir ne $output_dir or die "input and output directories must be different\n";

my $script_dir = abs_path(dirname(__FILE__));
my $repo = abs_path(File::Spec->catdir($script_dir, File::Spec->updir()));
my $disas = File::Spec->catfile($script_dir, 'vcsc-disas');
my $assembler = File::Spec->catfile($repo, 'assembler', 'vcsc-as');
-x $disas or die "$disas: build vcsc-disas first\n";
-x $assembler or die "$assembler: build vcsc-as first\n";

opendir(my $dh, $input_dir) or die "$input_dir: $!\n";
my @files = sort grep {
    /\.bin\z/i && -f File::Spec->catfile($input_dir, $_)
} readdir($dh);
closedir($dh);
@files or die "$input_dir: no .bin files found\n";

sub slurp_raw {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "$path: $!\n";
    local $/;
    my $data = <$fh>;
    defined $data or $data = '';
    close($fh) or die "$path: close failed: $!\n";
    return $data;
}


sub capture_command {
    my (@cmd) = @_;
    my $err = gensym;
    my $pid = open3(my $in, my $out, $err, @cmd);
    close($in);
    local $/;
    my $stdout = <$out>;
    my $stderr = <$err>;
    $stdout = '' if !defined($stdout);
    $stderr = '' if !defined($stderr);
    waitpid($pid, 0);
    return ($? >> 8, $? & 127, $stdout, $stderr);
}

sub vcsc_mapper_from_source {
    my ($path) = @_;
    my $source = slurp_raw($path);
    $source =~ /^;\s*mapper:\s*(.+?)\s*\(/m
        or die "$path: generated source has no mapper header\n";
    my $mapper = $1;
    if ($mapper =~ /^unbanked\s+(2K|4K)\z/i) {
        return uc($1);
    }
    $mapper =~ /^([A-Za-z0-9+]+)\z/
        or die "$path: cannot normalize mapper header '$mapper'\n";
    return uc($1);
}

sub stella_mapper_for_rom {
    my ($exe, $path, $expected_md5) = @_;
    local $ENV{SDL_AUDIODRIVER} = 'dummy' if !defined($ENV{SDL_AUDIODRIVER});
    local $ENV{SDL_VIDEODRIVER} = 'dummy' if !defined($ENV{SDL_VIDEODRIVER});
    my ($rc, $sig, $stdout, $stderr) = capture_command($exe, '-rominfo', $path);
    $sig == 0 or die "Stella -rominfo terminated by signal $sig\n";
    $rc == 0 or die "Stella -rominfo failed (status $rc): $stderr";
    my $text = $stdout . $stderr;
    $text =~ /^\s*Cart MD5:\s*([0-9A-Fa-f]{32})\s*$/m
        or die "Stella -rominfo did not report Cart MD5\n";
    my $reported_md5 = lc($1);
    $reported_md5 eq lc($expected_md5)
        or die "Stella MD5 $reported_md5 does not match local MD5 $expected_md5\n";
    $text =~ /^\s*Bankswitch Type:\s*([^\s(]+).*$/m
        or die "Stella -rominfo did not report Bankswitch Type\n";
    my $mapper = uc($1);
    $mapper =~ s/\*+\z//;
    return $mapper;
}

sub ihex_to_bin {
    my ($hex_path, $bin_path, $expected_size) = @_;
    open(my $fh, '<', $hex_path) or die "$hex_path: $!\n";
    my %mem;
    my $base = 0;
    my $eof = 0;
    my $lineno = 0;
    while (my $line = <$fh>) {
        ++$lineno;
        $line =~ s/[\r\n]+\z//;
        $line =~ /^:([0-9A-Fa-f]+)\z/
            or die "$hex_path:$lineno: malformed Intel HEX record\n";
        my $raw = pack('H*', $1);
        length($raw) >= 5 or die "$hex_path:$lineno: short Intel HEX record\n";
        my @b = unpack('C*', $raw);
        my $count = $b[0];
        length($raw) == $count + 5
            or die "$hex_path:$lineno: Intel HEX length mismatch\n";
        my $sum = 0;
        $sum = ($sum + $_) & 0xff for @b;
        $sum == 0 or die "$hex_path:$lineno: Intel HEX checksum mismatch\n";
        my $addr = ($b[1] << 8) | $b[2];
        my $type = $b[3];
        my @data = @b[4 .. 3 + $count];
        if ($type == 0x00) {
            for my $i (0 .. $#data) {
                my $absolute = $base + $addr + $i;
                exists $mem{$absolute}
                    and die "$hex_path:$lineno: overlapping output address $absolute\n";
                $mem{$absolute} = $data[$i];
            }
        }
        elsif ($type == 0x01) {
            $count == 0 or die "$hex_path:$lineno: malformed EOF record\n";
            $eof = 1;
            last;
        }
        elsif ($type == 0x02) {
            $count == 2 or die "$hex_path:$lineno: malformed segment-base record\n";
            $base = (($data[0] << 8) | $data[1]) << 4;
        }
        elsif ($type == 0x04) {
            $count == 2 or die "$hex_path:$lineno: malformed linear-base record\n";
            $base = (($data[0] << 8) | $data[1]) << 16;
        }
        elsif ($type == 0x03 || $type == 0x05) {
            # Start-address metadata has no bearing on cartridge bytes.
        }
        else {
            die "$hex_path:$lineno: unsupported Intel HEX record type $type\n";
        }
    }
    close($fh) or die "$hex_path: close failed: $!\n";
    $eof or die "$hex_path: missing Intel HEX EOF record\n";

    my $out = '';
    for my $address (0 .. $expected_size - 1) {
        exists $mem{$address}
            or die "$hex_path: output address $address is missing\n";
        $out .= chr($mem{$address});
    }
    for my $address (keys %mem) {
        $address < $expected_size
            or die "$hex_path: unexpected output byte at address $address\n";
    }
    open(my $outfh, '>:raw', $bin_path) or die "$bin_path: $!\n";
    print {$outfh} $out or die "$bin_path: write failed: $!\n";
    close($outfh) or die "$bin_path: close failed: $!\n";
}

my ($passed, $failed) = (0, 0);
my ($stella_matches, $stella_mismatches, $stella_errors) = (0, 0, 0);
for my $name (@files) {
    my $input = File::Spec->catfile($input_dir, $name);
    (my $stem = $name) =~ s/\.bin\z//i;
    my $s26 = File::Spec->catfile($output_dir, "$stem.s26");
    my $rebuilt = File::Spec->catfile($output_dir, $name);
    my $hex = File::Spec->catfile($output_dir, ".$stem.roundtrip.$$.hex");
    unlink($s26, $rebuilt, $hex);

    my $ok = eval {
        my $original = slurp_raw($input);
        length($original) > 0 or die "$input: empty cartridge image\n";
        system {$disas} $disas, '-o', $s26, $input;
        $? == 0 or die "vcsc-disas failed (status " . ($? >> 8) . ")\n";
        -f $s26 or die "vcsc-disas did not create $s26\n";

        system {$assembler} $assembler, "--hex=$hex", $s26;
        $? == 0 or die "vcsc-as failed (status " . ($? >> 8) . ")\n";
        -f $hex or die "vcsc-as did not create $hex\n";
        ihex_to_bin($hex, $rebuilt, length($original));
        unlink($hex);

        my $new = slurp_raw($rebuilt);
        my $md5_original = md5_hex($original);
        my $md5_new = md5_hex($new);
        print "$name: original md5=$md5_original reconstructed md5=$md5_new\n";
        $md5_original eq $md5_new or die "MD5 mismatch\n";
        length($original) == length($new) or die "size mismatch\n";
        $original eq $new or die "byte mismatch\n";

        if (defined($stella)) {
            my $vcsc_mapper = vcsc_mapper_from_source($s26);
            my $stella_mapper = eval { stella_mapper_for_rom($stella, $input, $md5_original) };
            if (!defined($stella_mapper)) {
                ++$stella_errors;
                my $error = $@ || "unknown Stella comparison failure\n";
                $error =~ s/[\r\n]+\z//;
                print STDERR "STELLA-ERROR $name: $error\n";
            }
            elsif ($vcsc_mapper eq $stella_mapper) {
                ++$stella_matches;
                print "$name: mapper vcsc=$vcsc_mapper stella=$stella_mapper MATCH\n";
            }
            else {
                ++$stella_mismatches;
                print "$name: mapper vcsc=$vcsc_mapper stella=$stella_mapper MISMATCH\n";
            }
        }
        1;
    };
    if ($ok) {
        ++$passed;
        print "PASS $name\n";
    }
    else {
        ++$failed;
        my $error = $@ || "unknown failure\n";
        $error =~ s/[\r\n]+\z//;
        print STDERR "FAIL $name: $error\n";
        unlink($hex);
    }
}

print "Summary: $passed passed, $failed failed, " . ($passed + $failed) . " total\n";
if (defined($stella)) {
    my $compared = $stella_matches + $stella_mismatches;
    print "Stella mapper comparison: $stella_matches match, $stella_mismatches mismatch, " .
          "$stella_errors errors, $compared compared\n";
}
exit($failed || $stella_errors || ($stella_strict && $stella_mismatches) ? 1 : 0);
