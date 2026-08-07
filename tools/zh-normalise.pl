#!/usr/bin/perl

# Un-wrap a Chinese Markdown paragraph safely.
#
# WHY THIS FILE EXISTS AS A FILE. The normalisation was being done ad hoc, and the
# ad hoc version was:
#
#     s/(PUNCT)(\*\*)? +(?=\S)/$1$2/g
#
# which strips the space in 「…是錯的。** 只有」 and produces 「…是錯的。**只有」 —
# a closing `**` that CommonMark cannot close, because a run preceded by punctuation
# is right-flanking only if it is also followed by whitespace or punctuation. The
# emphasis then never ends and the reader sees literal asterisks.
#
# It shipped 116 times across four files before Jason saw it on a rendered page.
# The tool that was supposed to enforce the house style was manufacturing the defect
# the house style exists to prevent, and it did so invisibly in a diff.
#
# So: when removing the space would break the emphasis, the punctuation is moved OUT
# of the emphasis instead. Both rules then hold — the closer follows a letter, and
# the punctuation is still followed directly by text.
#
# `tools/check-zh-markdown.pl` rule 4 is the guard for the same thing. This is the
# fixer; that is the check. Neither replaces the other.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

my $PUNCT   = qr/[、。，；：！？（）「」『』【】《》〈〉…—–　]/;
my $MOVABLE = qr/[、。，；：！？]/;   # may sit outside an emphasis run

die "usage: $0 <file>...\n" if !@ARGV;

for my $file (@ARGV) {
    open(my $in, '<:encoding(UTF-8)', $file) or die "$file: $!\n";
    my @lines = <$in>;
    close($in);

    my $fence = 0;
    my $changed = 0;
    for my $line (@lines) {
        chomp(my $body = $line);
        if ($body =~ /^\s*>?\s*```/) { $fence = !$fence; next }
        next if $fence;

        my $orig = $body;

        # A space after full-width punctuation is an un-wrapping artefact — but if
        # a closing ** sits between them, moving the mark is what keeps the emphasis
        # working. The middle dot is excluded: its spaces are correct, because it is
        # a separator rather than a terminator.
        $body =~ s/($MOVABLE)(\*\*) +(?=\S)/$2$1/g;   # 。** 只 -> **。只
        $body =~ s/($PUNCT) +(?=\S)/$1/g;             # 。 只    -> 。只

        # AND REPAIR what is already broken.
        #
        # The rule above only avoids CREATING the fault — it needs a space to
        # remove. It cannot touch 「。**版」, which is the fault itself. That gap
        # was found the honest way: an ad hoc regex produced the broken form in
        # CHANGELOG_zh-TW.md, this tool was run over it, and check-zh still
        # reported it. A fixer that can only prevent is half a fixer.
        #
        # Only a CLOSING run is moved, so the runs are counted in order — 「，**錯誤
        # 402**」 opens after a comma and is perfectly legal.
        my @runs;
        while ($body =~ /\*\*/g) { push @runs, pos($body) - 2 }
        for my $i (reverse 0 .. $#runs) {
            next if $i % 2 == 0;                     # this one opens
            my $pos = $runs[$i];
            next if $pos == 0;
            my $before = substr($body, $pos - 1, 1);
            my $after  = length($body) > $pos + 2 ? substr($body, $pos + 2, 1) : ' ';
            next if $before !~ /$MOVABLE/;
            next if $after =~ /\s/ || $after !~ /\w/;
            substr($body, $pos - 1, 3) = '**' . $before;
        }

        if ($body ne $orig) { $line = "$body\n"; $changed++ }
    }

    if ($changed) {
        open(my $out, '>:encoding(UTF-8)', $file) or die "$file: $!\n";
        print $out @lines;
        close($out);
        print "  $file: $changed line(s) normalised\n";
    }
}
