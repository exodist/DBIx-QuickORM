package DBIx::QuickORM::RowManager::Transactional;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/weaken/;

use DBIx::QuickORM::Affinity();

use parent 'DBIx::QuickORM::RowManager::Cached';
use DBIx::QuickORM::Util::HashBase;

sub does_txn { 1 }

sub do_cache_lookup {
    my $self = shift;

    my $row = $self->SUPER::do_cache_lookup(@_);
    $self->fix_row_post_txn($row) if $row && $row->{transaction} && defined $row->{transaction}->{result};

    return $row;
}

sub cache {
    my $self = shift;

    my $row = $self->SUPER::cache(@_);
    $self->fix_row_post_txn($row) if $row && $row->{transaction} && defined $row->{transaction}->{result};

    return $row;
}

sub uncache {
    my $self = shift;

    my $row = $self->SUPER::cache(@_);
    $self->fix_row_post_txn($row) if $row && $row->{transaction} && defined $row->{transaction}->{result};

    return $row;
}

sub touch_row_txn {
    my $self = shift;
    my ($con, $row, %params) = @_;

    return unless $row;

    my $txn = $con->current_txn;
    my $state = $row->{transaction_state};

    # Nothing has changed
    return unless $txn || ($state && $state->{latest});

    $state //= $row->{transaction_state} //= {};
    my $last_txn = $state->{latest};

    return if $txn && $last_txn && $last_txn == $txn;

    my $txns = $state->{all} //= {};

    if ($txn) {
        confess "Attempt to update row using a completed transaction" if defined $txn->result;

        # Always update these
        $state->{latest} = $txn;
        $state->{insert} = $txn if $params{insert};
        $txns->{$txn} //= [$txn, $row->primary_key_hashref];
    }

    use DBIx::QuickORM::Util qw/debug/;
    my @todo = sort { $a->[0]->id <=> $b->[0]->id } values %$txns;
    while (my $set = shift @todo) {
        my ($x, $pk) = @$set;
        my $res = $x->result // last; # No result, then it is still open
        delete $txns->{$x};

        my $remaining = scalar @todo;
        my $insert_txn = delete $state->{insert};

        if ($res) {    # Commited
            if ($remaining && $insert_txn) {
                my $y   = $todo[-1]->[0];
                my $yid = $y->id;

                $state->{insert} = $insert_txn->id > $yid ? $y : $insert_txn;
            }
        }
        else {         # Rolled back
            if ($insert_txn && $insert_txn->id >= $x->id) {
                delete $state->{insert};

                # Row is not in storage
                my $data = delete $row->{stored};
                $row->{pending} = { %{$data // {}}, %{$row->{pending} // {}} };
                $row->{invalid} = 1;
                $self->uncache($row->sqla_source, $row);
            }
            else {
                delete $row->{pending};
                $row->{stored} = $pk;
            }
        }
    }

    delete $row->{transaction_state} unless $txn;

    return scalar @todo;
}

1;
