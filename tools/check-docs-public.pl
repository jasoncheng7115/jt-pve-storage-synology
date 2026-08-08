#!/usr/bin/perl
# Public documents must not carry the development environment.
#
# Every finding below was real on 2026-08-07: the site and the README named the
# author's own hosts and storage ids, carried the day each measurement happened,
# and used mainland rather than Taiwan wording. None of it means anything to a
# reader, and the hostnames are somebody's infrastructure.
#
# The dates are the subtle one. "Measured on <date>" reads as provenance, but a
# reader cannot act on it and it goes stale in a way the claim itself does not —
# that a thing was measured is the claim. Dates belong in the changelog.
use strict;
use warnings;
use utf8;

# The findings quote Chinese lines back. Without this every one of them
# prints a 'Wide character' warning, and a guard that warns is a guard people
# learn to skim.
binmode(STDOUT, ':encoding(UTF-8)');

my @RULES = (
    [ 'an internal host or storage name',
      qr{\b(?:host-1\d\d|pc-pve\d|syno-nas\d|syno-t\d+)\b},
      'name the role instead: "node A", "<storeid>"' ],
    [ 'a private address',
      qr{\b(?:10|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d+\.\d+\b},
      'use a documentation address such as 192.0.2.10' ],
    [ 'a date',
      qr{\b20\d\d-\d\d-\d\d\b},
      'that it was measured is the claim; the day belongs in the changelog' ],
    # Everything this has ever run on is Proxmox VE 9. A claim of 8 AND 9 in one
    # breath reads as a measurement; the requirements table is allowed to say 8.x
    # is expected to work provided it says in the same sentence that it was never
    # tested, which this pattern does not match.
    [ 'a support claim for Proxmox VE 8, which nothing has run on',
      qr{(?:PVE|Proxmox\s*VE)\s*8\s*(?:/|／)\s*9 | 8\.x\s*(?:/|／)\s*9\.x | 支援\s*(?:PVE|Proxmox\s*VE)\s*8}x,
      'say 9, and say separately that 8.x is expected to work but was never tested' ],
    # strip_code: a term inside backticks is being CITED, not used. The changelog
    # says «`登記簿` reads as mainland usage and is now `驗證紀錄`», and a guard that
    # cannot tell a thing from prose about the thing is the seventh instance of
    # that mistake in this project. A hostname in backticks is still a published
    # hostname, so only this rule gets the exemption.
    [ 'mainland wording',
      qr{登记|登記簿|软件|默认|服务器|回显|回顯|缺省|寻址|优化},
      'Taiwan terminology — see the glossary', 1 ],
    # 量測 is the term; 量過／量到／量了 is the verb used bare, which reads as speech
    # rather than as writing. 「兩半都量過」 shipped on the site.
    [ 'a bare 量 where 量測 is meant',
      qr{量[過到了](?!測)},
      'write 量測過 / 量測到, or say 驗證過', 1 ],
);

# A documentation address is fine, and so is an example in a command block.
my $ALLOW = qr{192\.0\.2\.\d+};

my $fail = 0;
for my $file (@ARGV) {
    open(my $fh, '<:encoding(UTF-8)', $file) or die "cannot read $file: $!\n";
    my $n = 0;
    while (my $line = <$fh>) {
        $n++;
        next if $line =~ /Copyright|Author|作者/;   # the author's own name is not a leak

        # A changelog release heading is where a date BELONGS — this guard's own
        # message says so, and flagging it here would be the guard contradicting
        # its own advice. Exempt that one shape precisely, so a stray date in
        # changelog prose is still caught.
        next if $line =~ /\A##\s*\[[^\]]+\]\s*-\s*20\d\d-\d\d-\d\d\b/;
        for my $r (@RULES) {
            my ($what, $re, $hint, $strip_code) = @$r;
            my $subject = $line;
            # Replaced, never deleted: removing a code span joins the text either
            # side and can manufacture a match that was never there.
            if ($strip_code) {
                $subject =~ s/`[^`]*`/`X`/g;
                # 「」 is this project's citation mark as well as its emphasis, and a
                # historical entry quotes the very wording it reports fixing:
                # 「登記簿值得 先讀一遍」. Same reasoning as the backticks.
                $subject =~ s/「[^」]*」/「X」/g;
            }
            next if $subject !~ $re;
            my $hit = $&;
            next if $hit =~ $ALLOW;
            printf "  %s:%d: %s — %s\n", $file, $n, $what, $hint;
            printf "      %s\n", ($line =~ s/^\s+|\s+$//gr);
            $fail = 1;
        }
    }
    close $fh;
}
if ($fail) {
    print "\nThese are published. A reader cannot act on any of them, and the\n";
    print "hostnames are somebody's infrastructure.\n";
    exit 1;
}
print "  OK: the published documents carry no development environment.\n";
exit 0;
