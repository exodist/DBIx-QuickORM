package DBIx::QuickORM::Role::HasTransactions;
use strict;
use warnings;

use DBIx::QuickORM::Util qw/alias/;

use Role::Tiny;

requires 'connection';

sub TRANSACTIONS() { 'transactions' }

alias 'txn' => 'transaction';
sub txn { my $t = $_[0]->transactions; return undef unless $t && @$t; return $t->[-1] }

alias txns => 'transactions';
sub txns {
    my $txns = $_[0]->{+TRANSACTIONS};

    # Transactions are weak refs in the array, so they may go undef on us.
    pop @$txns while @$txns && !$txns->[-1];

    return $txns;
}

alias in_txn => 'in_transaction';
sub in_txn {
    my $self = shift;

    my $txns = $self->transactions;
    if (my $cnt = @{$txns}) {
        return $cnt;
    }

    # Yes, but not ours
    return -1 if $self->connection->in_external_transaction;

    return 0;
}

1;
