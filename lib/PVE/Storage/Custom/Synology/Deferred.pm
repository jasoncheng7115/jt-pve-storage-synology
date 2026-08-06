package PVE::Storage::Custom::Synology::Deferred;

# A scope guard: run something on every exit from a scope, including an early
# `return` and a `die`.
#
# Perl has no `finally`, and the alternative is repeating the cleanup at every
# exit point and losing one of them. That is not hypothetical here —
# `on_delete_hook` did exactly that. It removed the storage's targets from the NAS
# and returned early when the NAS could not be reached, and the early return left
# the stored DSM credential on disk for a storage that no longer existed. Nothing
# used it and nobody was looking after it.
#
# The guards below are the same four that `API::DESTROY` needs, for the same
# reasons, and they are duplicated rather than shared because a scope guard that
# depends on another module is a scope guard that can fail while it is cleaning up
# after that module.

use strict;
use warnings;

sub new {
    my ($class, $code) = @_;
    die __PACKAGE__ . ": a deferred action needs a code reference\n"
        if ref $code ne 'CODE';
    return bless { code => $code, pid => $$ }, $class;
}

# For the caller that completed successfully and no longer wants the cleanup.
sub cancel {
    my ($self) = @_;
    delete $self->{code};
    return;
}

sub DESTROY {
    my ($self) = @_;

    # At interpreter shutdown whatever the cleanup touches may already be gone,
    # and the failure would be an error from inside a module the operator has
    # never heard of.
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    my $code = delete $self->{code} or return;

    # PVE forks workers. A child inheriting the guard and running it on exit would
    # clean up state the PARENT is still using.
    return if $self->{pid} != $$;

    # `local $@` because a guard often runs on ordinary scope exit while the
    # caller is between an `eval` and its `if ($@)`, and `eval` because a die in
    # a destructor becomes a warning at best.
    local $@;
    eval { $code->() };
    warn __PACKAGE__ . ": a deferred cleanup failed: $@" if $@;
    return;
}

1;
