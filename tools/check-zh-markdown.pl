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

# WITHOUT THIS the literal 。 、 —— in the character class below are BYTES, while
# the input is decoded to characters — so the pattern can never match and the
# check passes on files that are full of the artefact it looks for. Rule 1 was
# unaffected only because it spells its ranges as \x{...} escapes, which is
# exactly the kind of partial success that makes a broken guard look like a
# working one. Jason found the artefact on a rendered page while this script
# was reporting OK.
use utf8;

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
        $probe =~ s/`[^`]*`/X/g;         # replaced, not deleted — see rule 3
        $probe =~ s/\*\*//g;             # bold is fine
        if ($probe =~ /\*([^*\s][^*]{0,60})\*/) {
            complain($file, $n, "italic emphasis '*$1*'",
                "italics are English typography. Use **bold** or 「」.");
        }

        # 3. A space after full-width punctuation.
        #
        # Emphasis markers are stripped FIRST. 「程式碼。** 下面」 renders with a
        # visible space just as 「程式碼。 下面」 does, but the ** sits between the
        # two and the first version of this check looked straight past it —
        # which is how Jason found the artefact on a rendered page again.
        my $punct_probe = $bare;
        $punct_probe =~ s/\*\*//g;
        # A code span is replaced, NOT deleted. Deleting it joined the text on
        # either side and manufactured the very pattern being looked for:
        # 「、`::Target` 附」 became 「、 附」, a space after 、 that is not in the
        # source. A guard that invents findings is worse than one that misses
        # them, because the fix for a phantom is to damage real text.
        $punct_probe =~ s/`[^`]*`/X/g;
        if ($punct_probe =~ /($PUNCT) (\S)/) {
            complain($file, $n, "a space after the full-width '$1'",
                "full-width punctuation already separates; the space is an"
                . " un-wrapping artefact.");
        }

        # 4. A bold run that cannot close, so it renders as literal asterisks.
        #
        # CommonMark: a `**` run preceded by Unicode punctuation is right-flanking
        # ONLY if it is also followed by whitespace or punctuation. A Chinese
        # character is a letter, so 「…是錯的。**只有」 has a closer that is not
        # right-flanking — the emphasis never ends and the reader sees the asterisks.
        #
        # This is rule 3's own doing, which is why the two live next to each other.
        # Rule 3 says no space after full-width punctuation; removing the space from
        # 「…是錯的。** 只有」 produces exactly the broken form. **116 of these had
        # shipped** across four files before Jason spotted them on a rendered page —
        # the fourth time this project has been caught by something invisible in a
        # diff and obvious in a browser.
        #
        # The fix is to move the punctuation OUT of the emphasis:
        # 「**…是錯的**。只有」 — the closer then follows a letter, and the
        # punctuation is still followed directly by text, so rule 3 holds too.
        #
        # Runs are counted IN ORDER because an opening `**` in the same position is
        # perfectly legal: 「，**錯誤 402**」 opens after a comma and is fine. A
        # check that could not tell an opener from a closer reported 213 findings
        # where there were 116.
        # The code span's CONTENTS are replaced but its BACKTICKS are kept.
        #
        # Rule 3 replaces a whole span with X so the text either side does not join.
        # Doing that here produced eleven false positives, because a backtick IS
        # Unicode punctuation: 「…被拒絕。**`docs/…`」 has a closer that follows
        # punctuation AND is followed by punctuation, so it is right-flanking and
        # closes perfectly. Substituting X made the next character a word character
        # and the rule condemned correct markup.
        #
        # Third time in this project that a placeholder changed the meaning of what
        # surrounded it. The lesson is narrower than "replace, don't delete": the
        # placeholder has to belong to the same character class as what it replaces
        # AT THE BOUNDARIES the rule looks at.
        my $emph_probe = $bare;
        $emph_probe =~ s/`[^`]*`/`X`/g;
        my @runs;
        my $off = 0;
        while ($emph_probe =~ /\*\*/g) { push @runs, pos($emph_probe) - 2 }
        for my $i (0 .. $#runs) {
            next if $i % 2 == 0;          # this one opens
            my $pos = $runs[$i];
            my $before = $pos > 0 ? substr($emph_probe, $pos - 1, 1) : '';
            my $after  = length($emph_probe) > $pos + 2
                       ? substr($emph_probe, $pos + 2, 1) : ' ';
            next if $before !~ /$PUNCT|[\x{FF09}\x{300D}\x{300F}\x{3011}\x{300B}\x{3009}]/;
            next if $after =~ /\s/ || $after !~ /\w/;
            complain($file, $n,
                "a bold run closing after '$before' cannot close",
                "CommonMark needs a closing ** to be followed by whitespace or"
                . " punctuation when it follows punctuation. Move the mark out:"
                . " **…$before** becomes **…**$before");
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

        # Only <em> INSIDE the Chinese span, not anywhere on a line that happens to
        # contain one. The first version asked both questions of the whole line, so
        # a line carrying an English span and a Chinese span together was condemned
        # for an <em> that belonged to the English one — where italics are correct
        # typography and removing them would damage the text.
        #
        # It found no false positive for weeks only because the existing markup put
        # each language on its own line. The first line written with both spans
        # together tripped it, and the tempting fix was to mangle correct English.
        #
        # A guard whose remedy is to damage right text is worse than no guard: this
        # project has now met that in check-zh's own code-span handling, in
        # t/07-imports.t, in t/12-reap.t and here.
        for my $span ($line =~ /class="lang-zh">(.*?)<\/span>/g) {
            complain('docs/index.html', $n, '<em> inside a Chinese span',
                'italics are English typography. Use <strong> or 「」.')
                if $span =~ /<em>/;
        }
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
