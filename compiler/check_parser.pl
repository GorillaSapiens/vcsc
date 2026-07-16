#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

# check_actions.pl — verify that each action uses all $n for NONTERMINALS in its visible RHS.
# Assumptions:
#   * ALL-CAPS identifiers are terminals.
#   * Single-quoted character literals are terminals.
#   * %empty contributes no symbols (no $n required).
#   * Mid-rule actions are supported; they create a synthetic nonterminal that is NOT required.
# Output:
#   file:line: unused $N in action for rule 'LHS' (alternative starts here)

my $errors = 0;

# ---- Load file ---------------------------------------------------------------
my $file = shift @ARGV or die "Usage: $0 grammar.y\n";
open my $fh, "<:raw", $file or die "Cannot open $file: $!\n";
local $/;
my $src = <$fh>;
close $fh;

# ---- Find grammar section and establish line offset --------------------------
my $i1 = index($src, "%%");
$i1 >= 0 or die "No '%%' section delimiter found.\n";
my $i2 = index($src, "%%", $i1 + 2);
$i2 >= 0 or die "Only one '%%' delimiter found; need two.\n";

my $GRAMMAR_START = $i1 + 2;                      # byte offset where grammar slice starts
my $LINE_OFFSET   = (() = substr($src, 0, $GRAMMAR_START) =~ /\n/g);  # lines before grammar

my $grammar = substr($src, $GRAMMAR_START, $i2 - $GRAMMAR_START);

# ---- Helpers -----------------------------------------------------------------
sub line_of_pos {
    my ($s, $p) = @_;
    $p = 0 if $p < 0;
    $p = length($s) if $p > length($s);
    my $c = (() = substr($s, 0, $p) =~ /\n/g);
    return $c + 1 + $LINE_OFFSET;                 # adjust to file-absolute line numbers
}

sub is_terminal_id {
    my ($id) = @_;
    return $id =~ /^[A-Z][A-Z0-9_]*$/;
}

# Parse single-quoted character token at $pos; returns (new_pos, literal_text)
sub parse_char_token_at {
    my ($start) = @_;
    my $p = $start;
    my $len = length($grammar);
    die "Internal: parse_char_token_at not at quote\n" unless substr($grammar, $p, 1) eq "'";
    $p++; # consume opening '
    my $esc = 0;
    while ($p < $len) {
        my $ch = substr($grammar, $p, 1);
        $p++;
        if ($esc) { $esc = 0; next; }
        if ($ch eq "\\") { $esc = 1; next; }
        if ($ch eq "'") {
            my $text = substr($grammar, $start, $p - $start);
            return ($p, $text);
        }
    }
    my $line = line_of_pos($grammar, $start);
    die "Unterminated character literal at line $line\n";
}

# Parse a { ... } action block at $pos (on '{'); returns (new_pos, code_wo_outer_braces, start_line_abs)
sub parse_action_at {
    my ($start) = @_;
    my $p   = $start;
    my $len = length($grammar);
    die "Internal: parse_action_at not at '{'\n" unless substr($grammar, $p, 1) eq '{';
    my $start_line = line_of_pos($grammar, $p);

    my $code  = '{';
    my $depth = 1;     # we are ON the first '{'
    my $in_sl = 0;     # //
    my $in_ml = 0;     # /* */
    my $in_sq = 0;     # '...'
    my $in_dq = 0;     # "..."
    my $esc   = 0;

    $p++;

    while ($p < $len) {
        my $ch = substr($grammar, $p, 1);
        my $n2 = ($p + 1 < $len) ? substr($grammar, $p, 2) : '';
        $code .= $ch;
        $p++;

        # inside single-line comment
        if ($in_sl) { $in_sl = 0 if $ch eq "\n"; next; }
        # inside multi-line comment
        if ($in_ml) { if ($n2 eq '*/') { $code .= '/'; $p++; $in_ml = 0; } next; }
        # inside char literal
        if ($in_sq) { if ($ch eq "\\" && !$esc){ $esc=1; next } if ($ch eq "'" && !$esc){ $in_sq=0 } $esc=0; next; }
        # inside string literal
        if ($in_dq) { if ($ch eq "\\" && !$esc){ $esc=1; next } if ($ch eq '"' && !$esc){ $in_dq=0 } $esc=0; next; }

        # starting comments/strings
        if ($n2 eq '//') { $code .= '/'; $p++; $in_sl = 1; next; }
        if ($n2 eq '/*') { $code .= '*'; $p++; $in_ml = 1; next; }
        if ($ch eq "'")  { $in_sq = 1; next; }
        if ($ch eq '"')  { $in_dq = 1; next; }

        # braces (only when not in comment/string)
        if ($ch eq '{') { $depth++; next; }
        if ($ch eq '}') {
            $depth--;
            if ($depth == 0) {
                (my $raw = $code) =~ s/^\{//s;
                $raw =~ s/\}$//s;
                return ($p, $raw, $start_line);
            }
            next;
        }
    }
    die "Unterminated action block starting at line $start_line\n";
}

# ---- Tokenizer ---------------------------------------------------------------
my $pos = 0;
pos($grammar) = 0;
my @look = ();

sub peek_token {
    my $t = next_token();
    unshift @look, $t if defined $t;
    return $t;
}

sub next_token {
    return shift @look if @look;

    my $len = length($grammar);

    # Skip whitespace and comments
    while ($pos < $len) {
        pos($grammar) = $pos;
        if ($grammar =~ /\G[ \t\r\f]+/gc) { $pos = pos($grammar); next; }
        if ($grammar =~ /\G\n/gc)          { $pos = pos($grammar); next; }
        if ($grammar =~ /\G\/\/[^\n]*/gc)  { $pos = pos($grammar); next; }
        if ($grammar =~ /\G\/\*.*?\*\//gcs){ $pos = pos($grammar); next; }
        last;
    }
    return undef if $pos >= $len;

    my $start_line = line_of_pos($grammar, $pos);

    # Punctuation
    my $ch = substr($grammar, $pos, 1);
    if ($ch eq ':' or $ch eq '|' or $ch eq ';') {
        $pos++;
        return { type => ($ch eq ':' ? 'colon' : $ch eq '|' ? 'bar' : 'semi'), line => $start_line };
    }

    # %empty keyword
    pos($grammar) = $pos;
    if ($grammar =~ /\G%empty\b/gc) {
        my $tok = { type => 'empty', line => $start_line };
        $pos = pos($grammar);
        return $tok;
    }

    # %prec override
    pos($grammar) = $pos;
    if ($grammar =~ /\G%prec\b/gc) {
        my $tok = { type => 'prec', line => $start_line };
        $pos = pos($grammar);
        return $tok;
    }

    # Single-quoted char token (terminal)
    if ($ch eq "'") {
        my ($newpos, $text) = parse_char_token_at($pos);
        my $tok = { type => 'term_char', text => $text, line => $start_line };
        $pos = $newpos;
        return $tok;
    }

    # Action block
    if ($ch eq '{') {
        my ($newpos, $code, $aline) = parse_action_at($pos);
        my $tok = { type => 'action', code => $code, line => $aline };
        $pos = $newpos;
        return $tok;
    }

    # Identifier
    pos($grammar) = $pos;
    if ($grammar =~ /\G([A-Za-z_][A-Za-z_0-9]*)/gc) {
        my $id = $1;
        $pos = pos($grammar);
        return { type => 'id', value => $id, line => $start_line };
    }

    # Fallback: advance one char to avoid infinite loop
    $pos++;
    return next_token();
}

# ---- Parser & Checker --------------------------------------------------------
# Grammar: LHS ':' alt ('|' alt)* ';'
# For each action (mid-rule or final), check that all NONTERMINALS among visible RHS items
# have their $n referenced in the action. Synthetic mid-rule placeholders are excluded.
# %empty adds nothing to the visible sequence.

while (defined (my $tok = next_token())) {
    next unless $tok->{type} eq 'id';
    my $lhs = $tok->{value};

    my $colon = next_token();
    next unless $colon && $colon->{type} eq 'colon';

    ALT: while (1) {
        my @seq = (); # items so far in this alternative

        while (defined (my $t = next_token())) {
            if ($t->{type} eq 'empty') {
                # %empty contributes no symbols; nothing to push.
                next;
            }
            if ($t->{type} eq 'prec') {
                my $prec_tok = next_token();
                die "Expected identifier after %prec at line $t->{line}
"
                    unless $prec_tok && $prec_tok->{type} eq 'id';
                next;
            }
            if ($t->{type} eq 'id') {
                my $is_term = is_terminal_id($t->{value});
                push @seq, { type => ($is_term ? 'terminal' : 'nonterminal'), synthetic => 0 };
                next;
            }
            if ($t->{type} eq 'term_char') {
                push @seq, { type => 'terminal', synthetic => 0 };
                next;
            }
            if ($t->{type} eq 'action') {
                my $after = peek_token();
                my $is_final = ($after && ($after->{type} eq 'bar' || $after->{type} eq 'semi')) ? 1 : 0;

                my $visible = scalar(@seq);
                my %expected;
                for my $i (1..$visible) {
                    my $sym = $seq[$i-1];
                    next unless $sym->{type} eq 'nonterminal';
                    next if $sym->{synthetic};
                    $expected{$i} = 1;
                }

                my %used;
                my $code = $t->{code} // '';
                while ($code =~ /\$(\d+)/g) {
                    my $n = $1 + 0;
                    $used{$n} = 1 if $n >= 1 && $n <= $visible;
                }

                for my $n (sort { $a <=> $b } keys %expected) {
                    next if $used{$n};
                    $errors++;
                    printf "%s:%d: unused \$%d in action for rule '%s' (alternative starts here)\n",
                        $file, $t->{line}, $n, $lhs;
                }

                # Mid-rule action: synthesize a placeholder nonterminal
                if (!$is_final) {
                    push @seq, { type => 'nonterminal', synthetic => 1 };
                }
                next;
            }
            if ($t->{type} eq 'bar') { next ALT; }
            if ($t->{type} eq 'semi') { last ALT; }
            # else ignore unknown
        }
        last ALT; # safety
    }
}

exit ($errors ? -1 : 0) ;
