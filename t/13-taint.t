#!/usr/bin/perl

# Taint mode, run for real.
#
# `pvedaemon` is `#!/usr/bin/perl -T`, and NOTHING in this project ever ran under
# it: every hardware test was driven from `qm`, `pvesm` or `pvesh`, all three of
# which are plain `#!/usr/bin/perl`. Two rounds of verification passed while the
# web interface went on failing — and the second round claimed to be testing
# "the API path", using `pvesh`, which runs the handler in-process with no -T at
# all. The same mistake twice in one afternoon, the second time inside the fix
# for the first.
#
# The cases live in t/taint-child.pl, which this runs with an explicit `-T` on
# the command line. See that file for why the switch is not left to a shebang.

use strict;
use warnings;
use Test::More;
use lib 'lib';

my $child = 't/taint-child.pl';
plan skip_all => "$child is missing" if !-f $child;

# -T on the command line, not merely in the child's shebang: this is the whole
# fixture, so it is stated explicitly at the point of invocation.
my $pid = open(my $fh, '-|', $^X, '-T', '-Ilib', $child)
    or plan skip_all => "cannot run $child: $!";

my @lines = <$fh>;
close($fh);
my $rc = $?;

is($rc, 0, "$child exited cleanly") or diag("exit status $rc");
ok(scalar @lines, 'it reported some results')
    or BAIL_OUT("no output from the -T child — the switch or the harness is wrong");

for my $line (@lines) {
    chomp $line;
    my ($verdict, $rest) = $line =~ /\A(not ok|ok) (.*)\z/ or next;
    my ($name, $why) = split(/\t/, $rest, 2);
    ok($verdict eq 'ok', $name) or diag($why // '(no detail)');
}

done_testing();
