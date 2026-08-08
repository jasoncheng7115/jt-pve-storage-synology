#!/usr/bin/perl
# The two halves of a bilingual pair must make the same claim.
#
# docs/index.html says everything twice, in a <span class="lang-en"> immediately
# followed by a <span class="lang-zh">, and only one of them is on screen at a
# time. So a correction applied to one half is invisible in the other, and a
# reader of the other language sees the version that was wrong.
#
# That is not hypothetical. The requirements table was corrected from
# "8.x / 9.x" to "9.x, which is what it has been run on" in the English half
# and left saying 「8.x／9.x」 in the Chinese one, and it survived a sweep because
# the sweep's grep output was truncated before it reached the Chinese half.
#
# The comparison this makes is the one that catches that class of error without
# needing to understand either language: the FIGURES either half carries. A
# version, a count, a percentage or a size that appears in one half and not the
# other is either a divergence or a translation that dropped a fact.
#
# Numbers legitimately differ in one direction only — a Chinese half may spell a
# small number as a word (「兩台」 for 2) where the English uses a digit — so a
# digit missing from the Chinese side is reported, and the reverse is reported
# too, but a spelled-out Chinese numeral suppresses the finding for that value.
use strict;
use warnings;
use utf8;

binmode(STDOUT, ':encoding(UTF-8)');

# 一二三四五六七八九十 as the digits they stand for, so 「兩台機型」 does not read
# as a missing 2.
my %WORD = (
    0 => '零|zero|zeros', 1 => '一|one', 2 => '兩|二|two', 3 => '三|three',
    4 => '四|four', 5 => '五|five', 6 => '六|six', 7 => '七|seven',
    8 => '八|eight', 9 => '九|nine', 10 => '十|ten',
    16 => '十六|sixteen', 256 => '二百五十六', 128 => '一百二十八',
);

my $findings = 0;

for my $file (@ARGV) {
    open(my $fh, '<:encoding(UTF-8)', $file) or die "cannot read $file: $!\n";
    my $line_no = 0;
    while (my $line = <$fh>) {
        $line_no++;

        # A pair is an English span immediately followed by a Chinese one. Anything
        # else — a lone span, a span carrying only an image — is not a claim pair.
        while ($line =~ m{
            <span \s+ class="lang-en"> (.*?) </span>
            \s*
            <span \s+ class="lang-zh"> (.*?) </span>
        }gsx) {
            my ($en, $zh) = ($1, $2);

            # Markup and entities are not content. A code span's contents are, so
            # only the tags go.
            for ($en, $zh) {
                s{<[^>]*>}{ }g;
                s{&[a-z]+;|&\#\d+;}{ }g;
            }

            my %seen_en = map { $_ => 1 } _figures($en);
            my %seen_zh = map { $_ => 1 } _figures($zh);

            for my $v (sort keys %seen_en) {
                next if $seen_zh{$v};
                next if _spelled($v, $zh);
                $findings++;
                print "$file:$line_no: the English half carries '$v' and the Chinese half does not\n";
                print "  en: " . _trim($en) . "\n";
                print "  zh: " . _trim($zh) . "\n";
            }
            for my $v (sort keys %seen_zh) {
                next if $seen_en{$v};
                next if _spelled($v, $en);
                $findings++;
                print "$file:$line_no: the Chinese half carries '$v' and the English half does not\n";
                print "  en: " . _trim($en) . "\n";
                print "  zh: " . _trim($zh) . "\n";
            }
        }
    }
    close($fh);
}

if ($findings) {
    print "\nFAIL: $findings bilingual pair(s) disagree about a figure.\n";
    print "A correction applied to one half is invisible in the other.\n";
    exit 1;
}
print "  OK: both halves of every bilingual pair carry the same figures.\n";
exit 0;

# Every figure worth comparing: a dotted version, a number with a unit, a plain
# integer or decimal. Deliberately NOT every digit in a URL or an identifier.
sub _figures {
    my ($t) = @_;
    my @out;

    # A URL's digits are addressing, not a claim.
    $t =~ s{https?://\S+}{ }g;

    # Versions first, so 7.1.1 is one figure rather than 7.1 and 1.
    while ($t =~ /(\d+(?:\.\d+){1,3})/g) { push @out, $1 }
    $t =~ s/\d+(?:\.\d+){1,3}/ /g;

    while ($t =~ /(\d+(?:\.\d+)?)/g) { push @out, $1 }
    return @out;
}

sub _spelled {
    my ($v, $other) = @_;
    return 0 if $v =~ /\./;                 # a version is never spelled out
    my $w = $WORD{$v + 0};
    return 0 if !defined $w;
    return $other =~ /$w/i ? 1 : 0;
}

sub _trim {
    my ($t) = @_;
    $t =~ s/\s+/ /g;
    $t =~ s/^\s+|\s+$//g;
    return length($t) > 150 ? substr($t, 0, 147) . '...' : $t;
}
