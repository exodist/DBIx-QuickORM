package DBIx::QuickORM::Transaction;
use strict;
use warnings;

use Carp qw/croak carp cluck/;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <orm
    <savepoint
    <finalized
    <transactions
    <index
    <name
    <caller
    +debug
};

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::HasTransactions';

sub init {
    my $self = shift;

    croak "The 'connection' is required"         unless $self->{+CONNECTION};
    croak "The 'transactions' stack is required" unless $self->{+TRANSACTIONS};
    croak "The 'index' attribute is required"    unless defined $self->{+INDEX};
}

sub debug {
    my $self = shift;

    return $self->{+DEBUG} if $self->{+DEBUG};

    my $name = $self->{+NAME} // 'UNNAMED';
    $name = "<$name>";

    my $caller = $self->{+CALLER} or return $self->{+DEBUG} = $name;
    my $trace = "(started at file $caller->[1] line $caller->[2])";

    return $self->{+DEBUG} = "$name $trace";
}

sub _can_finalize {
    my $self = shift;
    my ($action) = @_;

    if (my $f = $self->{+FINALIZED}) {
        my $debug = $self->debug;
        croak "Transaction $debug has already closed via '$f'";
    }

    my $top = $self->transaction or die "Internal Error: No transactions in stack";

    if ($top != $self) {
        my $debug = $self->debug;

        my @stack;
        for my $txn (reverse @{$self->transactions}) {
            next unless $txn;
            last if $txn == $self;
            push @stack => $txn->debug;
        }

        my $stack = join "\n" => reverse @stack;

        croak "Attempt to finalize transaction $debug via $action(), but these deeper transactions are still open:\n$stack\n";
    }

    return 1;
}

sub commit {
    my $self = shift;

    $self->_can_finalize('commit');

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

    $self->_can_finalize('rollback');

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

    my $debug = $self->debug;

    cluck "Unfinalized transaction $debug has gone out of scope, will attempt to roll back";

    local $@;
    eval { $self->rollback() };
}

1;
