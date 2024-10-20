package DBIx::QuickORM::Transaction;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/weaken blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <savepoint
    <finalized
    <transactions
    <index
};

sub init {
    my $self = shift;

    croak "The 'connection' is required"         unless $self->{+CONNECTION};
    croak "The 'transactions' stack is required" unless $self->{+TRANSACTIONS};
    croak "The 'index' attribute is required"    unless defined $self->{+INDEX};

    weaken($self->{+CONNECTION});
}

sub commit {
    my $self = shift;
    return if $self->{+FINALIZED};

    if (my $sp = $self->{+SAVEPOINT}) {
        $self->{+CONNECTION}->commit_savepoint($sp);
    }
    else {
        $self->{+CONNECTION}->commit_txn;
    }

    $self->{+CONNECTION}->stop_txn($self);

    return $self->{+FINALIZED} = 'commit';
}

sub rollback {
    my $self = shift;
    return if $self->{+FINALIZED};

    if (my $sp = $self->{+SAVEPOINT}) {
        $self->{+CONNECTION}->rollback_savepoint($sp);
    }
    else {
        $self->{+CONNECTION}->rollback_txn;
    }

    $self->{+CONNECTION}->stop_txn($self);

    return $self->{+FINALIZED} = 'rollback';
}

sub DESTROY {
    my $self = shift;
    return if $self->{+FINALIZED};
    return unless $self->{+CONNECTION}; # Cannot do anything without this, likely in cleanup
    $self->rollback();
}

1;
