#!/usr/bin/perl

# Guards for the Traditional Chinese documents, all three of them earned by
# Jason spotting the result on a rendered page rather than in a diff.
#
#   1. A soft line break between two Chinese characters renders as a VISIBLE
#      SPACE on GitHub. Hard-wrapping a Chinese paragraph therefore produces
#      「登記簿值得 先讀一遍」 in the reader's browser while looking perfectly
#      tidy in the editor. Chinese paragraphs are not wrapped.
#
#   2. `*text*` is italic emphasis, which is English typography. Chinese uses
#      bold, 「」 or a 著重號 — never italics. The same applies to `<em>` inside a
#      Chinese span on the documentation site.
#
#   3. A space after full-width punctuation (、。，；：——) is an artefact, not
#      typography. It is what a careless un-wrapping leaves behind.
#
# Run by `make check-zh`, which `make test` and `make release-check` include.

use strict;
use warnings;

# The findings quote Chinese characters back at the reader, so the handle has to
# be told. Without this every message arrives with a "Wide character" warning
# attached, which is noise on top of a real finding.
binmode(STDOUT, ':encoding(UTF-8)');

my @files = @ARGV;
@files = (glob('*_zh-TW.md'), glob('docs/*_zh-TW.md')) if !@files;

my $fail = 0;

sub complain {
    my ($file, $line, $what, $why) = @_;
    print "  $file:$line: $what\n";
    print "      $why\n";
    $fail = 1;
}

# A Chinese ideograph. Deliberately not "any non-ASCII": full-width punctuation
# is handled separately, because a break next to one of those needs no space.
my $IDEO  = qr/[\x{3400}-\x{4dbf}\x{4e00}-\x{9fff}\x{f900}-\x{faff}]/;
# Sentence punctuation only. The middle dots `·` and `‧` are deliberately NOT
# here: they are used as separators — 「[English](…) · [繁體中文](…)」 — where the
# spaces around them are correct. Including them made that line a false
# positive, which is how a guard trains people to ignore it.
my $PUNCT = qr/[、。，；：！？（）「」『』【】《》〈〉—–…　]/;

for my $file (@files) {
    open(my $fh, '<:encoding(UTF-8)', $file) or die "cannot read $file: $!\n";
    my @lines = <$fh>;
    close($fh);
    chomp @lines;

    my $in_fence = 0;

    for my $i (0 .. $#lines) {
        my $line = $lines[$i];
        my $n    = $i + 1;
        my $bare = $line;
        $bare =~ s/^(?:>\s*)+//;

        if ($bare =~ /^```/) { $in_fence = !$in_fence; next }
        next if $in_fence;
        next if $bare =~ /^\s*$/;
        next if $bare =~ /^[#|]/;                       # heading or table row

        # 1. A wrap between two ideographs. Checked against the NEXT line,
        #    because that is where the rendered space appears.
        if ($i < $#lines) {
            my $next = $lines[$i + 1];
            my $nbare = $next;
            $nbare =~ s/^(?:>\s*)+//;
            if ($nbare !~ /^\s*$/ && $nbare !~ /^[#|`]/ && $nbare !~ /^\s*[-*+]\s/
                    && $nbare !~ /^\s*\d+\.\s/) {
                my ($a) = $line  =~ /($IDEO)\s*$/;
                my ($b) = $nbare =~ /^($IDEO)/;
                if (defined $a && defined $b) {
                    complain($file, $n,
                        "a Chinese paragraph is wrapped here",
                        "GitHub renders this break as a visible space: '$a $b'."
                        . " Keep Chinese paragraphs on one line.");
                }
            }
        }

        # 2. Italic emphasis.
        my $probe = $bare;
        $probe =~ s/`[^`]*`//g;          # code spans are not emphasis
        $probe =~ s/\*\*//g;             # bold is fine
        if ($probe =~ /\*([^*\s][^*]{0,60})\*/) {
            complain($file, $n, "italic emphasis '*$1*'",
                "italics are English typography. Use **bold** or 「」.");
        }

        # 3. A space after full-width punctuation.
        if ($bare =~ /($PUNCT) (\S)/) {
            complain($file, $n, "a space after the full-width '$1'",
                "full-width punctuation already separates; the space is an"
                . " un-wrapping artefact.");
        }
    }
}

# The documentation site carries both languages in one file, so <em> inside a
# Chinese span is the same mistake as rule 2 in a different syntax.
if (-e 'docs/index.html') {
    open(my $fh, '<:encoding(UTF-8)', 'docs/index.html') or die "$!\n";
    my $n = 0;
    while (my $line = <$fh>) {
        $n++;
        next if $line !~ /class="lang-zh"/;
        complain('docs/index.html', $n, '<em> inside a Chinese span',
            'italics are English typography. Use <strong> or 「」.')
            if $line =~ /<em>/;
    }
    close($fh);
}

if ($fail) {
    print "\nThese render wrongly for a Chinese reader while looking correct in\n";
    print "the editor, which is why they are checked rather than remembered.\n";
    exit 1;
}

print "  OK: Chinese documents are unwrapped, italic-free and cleanly punctuated.\n";
exit 0;
