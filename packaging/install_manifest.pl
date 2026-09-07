#!/usr/bin/env perl
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Spec;
use Getopt::Long qw(GetOptions);

my $manifest = 'packaging/install.manifest';
my $source_root = '.';
my $dest_root;
my @scopes;
my $vcsc_name = 'vcsc';
my $help;
GetOptions(
    'manifest=s'    => \$manifest,
    'source-root=s' => \$source_root,
    'dest-root=s'   => \$dest_root,
    'scope=s@'      => \@scopes,
    'vcsc-name=s'   => \$vcsc_name,
    'help'          => \$help,
) or die "usage: $0 <install|uninstall|verify> --scope NAME --dest-root DIR [options]\n";

my $action = shift @ARGV // '';
if ($help || $action !~ /\A(?:install|uninstall|verify)\z/ || !@scopes || !defined $dest_root) {
    die "usage: $0 <install|uninstall|verify> --scope NAME [--scope NAME ...] --dest-root DIR [--source-root DIR] [--vcsc-name NAME]\n";
}

my %wanted = map { $_ => 1 } @scopes;
open my $fh, '<', $manifest or die "$manifest: $!\n";
my @entries;
my $line_no = 0;
while (my $line = <$fh>) {
    ++$line_no;
    chomp $line;
    $line =~ s/\r\z//;
    next if $line =~ /^\s*(?:#|$)/;
    my @f = split /\t/, $line, -1;
    die "$manifest:$line_no: expected 5 tab-separated fields\n" unless @f == 5;
    my ($scope, $kind, $mode, $source, $dest) = @f;
    next unless $wanted{$scope};
    die "$manifest:$line_no: unknown kind '$kind'\n" unless $kind =~ /\A(?:file|tree|examples)\z/;
    die "$manifest:$line_no: absolute destination is forbidden\n" if File::Spec->file_name_is_absolute($dest);
    die "$manifest:$line_no: destination may not contain '..'\n" if grep { $_ eq '..' } File::Spec->splitdir($dest);
    push @entries, { scope => $scope, kind => $kind, mode => $mode, source => $source, dest => $dest, line => $line_no };
}
close $fh;
for my $scope (@scopes) {
    die "$manifest: no entries for scope '$scope'\n" unless grep { $_->{scope} eq $scope } @entries;
}

sub src_path { File::Spec->catfile($source_root, split m{/}, $_[0]) }
sub dst_path {
    my ($rel) = @_;
    return $dest_root if $rel eq '.';
    return File::Spec->catfile($dest_root, split m{/}, $rel);
}
sub rel_files {
    my ($root, $filter) = @_;
    return () unless -d $root;
    my @out;
    find({ no_chdir => 1, wanted => sub {
        return if -d $_;
        my $p = $File::Find::name;
        my $rel = File::Spec->abs2rel($p, $root);
        $rel =~ s{\\}{/}g;
        return if $filter && !$filter->($rel, $p);
        push @out, $rel;
    }}, $root);
    return sort @out;
}
sub copy_tree {
    my ($src, $dst) = @_;
    die "missing source tree: $src\n" unless -d $src;
    make_path($dst);
    find({ no_chdir => 1, wanted => sub {
        my $p = $File::Find::name;
        return if $p eq $src;
        my $rel = File::Spec->abs2rel($p, $src);
        my $to = File::Spec->catfile($dst, $rel);
        my @st = lstat($p);
        die "lstat $p: $!\n" unless @st;
        if (-d _) {
            make_path($to);
            chmod($st[2] & 07777, $to) or die "chmod $to: $!\n";
        } elsif (-l _) {
            my $target = readlink($p);
            die "readlink $p: $!\n" unless defined $target;
            make_path(dirname($to));
            unlink $to if -e $to || -l $to;
            symlink($target, $to) or die "symlink $to: $!\n";
        } elsif (-f _) {
            make_path(dirname($to));
            copy($p, $to) or die "copy $p -> $to: $!\n";
            chmod($st[2] & 07777, $to) or die "chmod $to: $!\n";
        } else {
            die "unsupported manifest tree entry: $p\n";
        }
    }}, $src);
}
sub clean_examples {
    my ($root) = @_;
    find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        my $p = $File::Find::name;
        if ($p =~ /\.(?:bin|hex|o26|map|sym|lst)\z/) {
            unlink $p or die "unlink $p: $!\n";
            return;
        }
        return unless $p =~ m{(?:^|/)Makefile\z};
        open my $in, '<', $p or die "$p: $!\n";
        local $/;
        my $text = <$in>;
        close $in;
        # Release/install examples may spell the source-tree compiler path either
        # through $(ROOT) or directly with ../../../driver/vcsc.  Preserve the
        # relative prefix and replace only the source-tree driver component.
        $text =~ s{driver/vcsc(?:\.exe)?}{bin/$vcsc_name}g;
        open my $out, '>', $p or die "$p: $!\n";
        print {$out} $text;
        close $out or die "$p: $!\n";
    }}, $root);
}
sub prune_empty_parents {
    my ($path) = @_;
    my $base = File::Spec->rel2abs($dest_root);
    my $cur = File::Spec->rel2abs(dirname($path));
    while ($cur ne $base && index($cur, $base . '/') == 0) {
        last unless rmdir $cur;
        $cur = dirname($cur);
    }
}
sub expected_tree_files {
    my ($src, $examples) = @_;
    return rel_files($src, sub {
        my ($rel) = @_;
        return 0 if $examples && $rel =~ /\.(?:bin|hex|o26|map|sym|lst)\z/;
        return 1;
    });
}
sub assert_same_list {
    my ($label, $expected, $actual) = @_;
    my %e = map { $_ => 1 } @$expected;
    my %a = map { $_ => 1 } @$actual;
    my @missing = grep { !$a{$_} } @$expected;
    my @extra = grep { !$e{$_} } @$actual;
    if (@missing || @extra) {
        print STDERR "$label inventory mismatch\n";
        print STDERR "  missing: $_\n" for @missing;
        print STDERR "  extra: $_\n" for @extra;
        exit 1;
    }
}

if ($action eq 'install') {
    for my $e (@entries) {
        my $src = src_path($e->{source});
        my $dst = dst_path($e->{dest});
        if ($e->{kind} eq 'file') {
            die "missing manifest source: $src\n" unless -f $src;
            make_path(dirname($dst));
            copy($src, $dst) or die "copy $src -> $dst: $!\n";
            chmod(oct($e->{mode}), $dst) or die "chmod $dst: $!\n";
        } elsif ($e->{kind} eq 'tree') {
            remove_tree($dst) if -e $dst;
            copy_tree($src, $dst);
        } else {
            make_path($dst);
            copy_tree($src, $dst);
            clean_examples($dst);
        }
    }
    exit 0;
}

if ($action eq 'uninstall') {
    for my $e (reverse @entries) {
        my $dst = dst_path($e->{dest});
        if ($e->{kind} eq 'file') {
            unlink $dst if -e $dst || -l $dst;
            prune_empty_parents($dst);
        } else {
            die "refusing to remove unsafe destination root '$dst'\n" if !defined($dst) || $dst eq '' || $dst eq '/';
            remove_tree($dst) if -e $dst;
        }
    }
    exit 0;
}

for my $e (@entries) {
    my $src = src_path($e->{source});
    my $dst = dst_path($e->{dest});
    if ($e->{kind} eq 'file') {
        die "manifest verification: missing $dst\n" unless -f $dst;
    } else {
        die "manifest verification: missing tree $dst\n" unless -d $dst;
        my @expected = expected_tree_files($src, $e->{kind} eq 'examples');
        my @actual = rel_files($dst);
        assert_same_list("$e->{scope}:$e->{dest}", \@expected, \@actual);
        if ($e->{kind} eq 'examples') {
            for my $mk (grep { /(?:^|\/)Makefile\z/ } @actual) {
                my $p = File::Spec->catfile($dst, split m{/}, $mk);
                open my $in, '<', $p or die "$p: $!\n";
                local $/;
                my $text = <$in>;
                close $in;
                die "manifest verification: source-tree driver path survived in $p\n"
                    if $text =~ m{(?:^|/)driver/vcsc(?:\.exe)?(?:\s|$)}m;
            }
        }
    }
}

if ($wanted{libraries}) {
    my $prefix = 'libraries/vcs/';
    my @expected = sort map { substr($_->{dest}, length($prefix)) }
        grep { $_->{scope} eq 'libraries' && index($_->{dest}, $prefix) == 0 } @entries;
    my @actual = rel_files(File::Spec->catdir($dest_root, 'libraries', 'vcs'));
    assert_same_list('libraries:vcs', \@expected, \@actual);
}

exit 0;
