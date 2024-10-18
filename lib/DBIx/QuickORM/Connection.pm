package DBIx::QuickORM::Connection;
use strict;
use warnings;

use Carp qw/confess croak cluck/;
use Scalar::Util qw/blessed weaken isweak/;
use DBIx::QuickORM::Util qw/alias/;

require DBIx::QuickORM::SQLAbstract;
require DBIx::QuickORM::Util::SchemaBuilder;
require DBIx::QuickORM::Connection::Cache;
require DBIx::QuickORM::Connection::Transaction;

use DBIx::QuickORM::Util::HashBase qw{
    <db
    +dbh
    <pid
    <transactions
    <column_type_cache
    <sqla
    <row_cache
    +async
    +side
    <created
};

##############
# DB Proxies #
##############

sub tables      { my $self = shift; $self->{+DB}->tables($self->dbh, @_) }
sub table       { my $self = shift; $self->{+DB}->table($self->dbh, @_) }
sub db_keys     { my $self = shift; $self->{+DB}->db_keys($self->dbh, @_) }
sub db_version  { my $self = shift; $self->{+DB}->db_version($self->dbh, @_) }
sub indexes     { my $self = shift; $self->{+DB}->indexes($self->dbh, @_) }
sub column_type { my $self = shift; $self->{+DB}->column_type($self->dbh, $self->{+COLUMN_TYPE_CACHE}, @_) }
sub columns     { my $self = shift; $self->{+DB}->columns($self->dbh, $self->{+COLUMN_TYPE_CACHE}, @_) }

sub create_temp_view     { my $self = shift; $self->{+DB}->create_temp_view($self->dbh, @_) }
sub create_temp_table    { my $self = shift; $self->{+DB}->create_temp_table($self->dbh, @_) }
sub temp_table_supported { my $self = shift; $self->{+DB}->temp_table_supported($self->dbh, @_) }
sub temp_view_supported  { my $self = shift; $self->{+DB}->temp_view_supported($self->dbh, @_) }

sub load_schema_sql { my $self = shift; $self->{+DB}->load_schema_sql($self->dbh, @_) }

sub supports_uuid     { my $self = shift; $self->{+DB}->supports_uuid($self->dbh, @_) }
sub supports_json     { my $self = shift; $self->{+DB}->supports_json($self->dbh, @_) }
sub supports_datetime { my $self = shift; $self->{+DB}->supports_datetime($self->dbh, @_) }

##############
# DB Proxies #
##############

#################
# INIT and MISC #
#################

sub init {
    my $self = shift;

    croak "A database is required"        unless $self->{+DB};
    croak "A database handle is required" unless $self->{+DBH};

    $self->{+PID}  //= $$;
    $self->{+SQLA} //= DBIx::QuickORM::SQLAbstract->new();

    $self->{+COLUMN_TYPE_CACHE} //= {};

    $self->{+TRANSACTIONS} = {stack => [], lookup => {}};

    $self->{+ROW_CACHE} = DBIx::QuickORM::Connection::Cache->new(transactions => $self->{+TRANSACTIONS});
}

sub dbh {
    my $self = shift;

    if ($$ != $self->{+PID}) {
        if ($self->{+DBH} && $self->in_transaction) {
            warn "Go through cache, do txn revert, only way to be sure recovery is actually possible";
            confess "Forked while inside a transaction"
        }

        $self->{+DBH} = $self->db->connect(dbh_only => 1);
    }
    elsif (!($self->{+DBH}) || !($self->{+ASYNC} || eval { $self->{+DBH}->ping })) {
        if ($self->in_transaction) {
            warn "Go through cache, do txn revert, only way to be sure recovery is actually possible";
            croak "Lost database connection during transaction"
        }
        warn "Lost db connection, reconnecting...\n";
        $self->{+DBH} = $self->db->connect(dbh_only => 1);
    }

    return $self->{+DBH};
}

sub generate_schema {
    my $self = shift;
    return DBIx::QuickORM::Util::SchemaBuilder->generate_schema($self);
}

sub generate_table_schema {
    my $self = shift;
    my ($name) = @_;

    my $table = $self->table($name, details => 1);
    return DBIx::QuickORM::Util::SchemaBuilder->generate_table($self, $table);
}

#################
# INIT and MISC #
#################

#################
# Async / Aside #
#################

sub supports_async  { my $self = shift; $self->{+DB}->supports_async($self->dbh, @_) }
sub async_query_arg { my $self = shift; $self->{+DB}->async_query_arg($self->dbh, @_) }
sub async_ready     { my $self = shift; $self->{+DB}->async_ready($self->dbh, @_) }
sub async_result    { my $self = shift; $self->{+DB}->async_result($self->dbh, @_) }
sub async_cancel    { my $self = shift; $self->{+DB}->async_cancel($self->dbh, @_) }

sub async_start {
    my $self = shift;
    croak "Already engaged in an async query" if $self->{+ASYNC};
    $self->{+ASYNC} = 1;
}

sub async_stop {
    my $self = shift;
    delete $self->{+ASYNC} or croak "Not currently engaged in an async query";
}

sub async_started { $_[0]->{+ASYNC} ? 1 : 0 }

sub busy { $_[0]->{+ASYNC} ? 1 : 0 }

sub add_side_connection { $_[0]->{+SIDE}++ }
sub pop_side_connection { $_[0]->{+SIDE}-- }
sub has_side_connection { $_[0]->{+SIDE} }

#################
# Async / Aside #
#################

################
# Transactions #
################

sub _commit_txn         { my $self = shift; $self->{+DB}->commit_txn($self->dbh, @_) }
sub _rollback_txn       { my $self = shift; $self->{+DB}->rollback_txn($self->dbh, @_) }
sub _commit_savepoint   { my $self = shift; $self->{+DB}->commit_savepoint($self->dbh, @_) }
sub _rollback_savepoint { my $self = shift; $self->{+DB}->rollback_savepoint($self->dbh, @_) }

sub _create_savepoint{
    my $self = shift;

    croak "Cannot start a transaction while an async query is running"
        if $self->{+ASYNC};

    croak 'Cannot start a transaction while side connections have active queries (use $sel->ignore_transactions() to bypass)'
        if $self->{+SIDE};

    croak 'Connection is already inside a transaction, but it is not controlled by DBIx::QuickORM'
        if $self->in_transaction < 0;

    $self->{+DB}->create_savepoint($self->dbh, @_);
}

sub _start_txn {
    my $self = shift;

    croak "Cannot start a transaction while an async query is running"
        if $self->{+ASYNC};

    croak 'Cannot start a transaction while side connections have active queries (use $sel->ignore_transactions() to bypass)'
        if $self->{+SIDE};

    croak 'Connection is already inside a transaction, but it is not controlled by DBIx::QuickORM'
        if $self->in_transaction < 0;

    $self->{+DB}->start_txn($self->dbh, @_)
}

{
    no warnings 'once';
    *transaction = \&txn;
    *in_transaction = \&in_txn;
    *start_transaction = \&start_txn;
    *transaction_do = \&txn_do;
}

sub in_txn {
    my $self = shift;

    my $txns = $self->{+TRANSACTIONS};
    if (my $cnt = @{$txns->{stack} //= []}) {
        return $cnt;
    }

    # Yes, but not ours
    return -1 if $self->{+DB}->in_txn($self->dbh);

    return 0;
}

sub txn { my $t = $_[0]->{+TRANSACTIONS}; return undef unless $t->{stack} && @{$t->{stack}}; return $t->{stack}->[-1] }

sub txn_do {
    my $self = shift;
    my ($cb) = @_;
    croak "txn_do takes a coderef as its only argument" unless $cb && ref($cb) eq 'CODE';

    my $txn = $self->start_txn();

    my $out;
    my $ok = eval { $out = $cb->($txn); 1 };
    my $err = $@;

    my $force = 0;
    if ($ok) {
        $ok &&= eval { $txn->commit; 1 };
        $err = $@;
        return $out if $ok;

        $force = "commit failed: $err" unless $ok;
    }

    unless ($ok) {
        eval { $txn->rollback; 1 } or $force = "rollback failed: $@";
    }

    $self->stop_txn($txn, force => $force)
        if $force;

    die $err;
}

sub start_txn {
    my $self = shift;

    my $txns = $self->{+TRANSACTIONS};
    my $stack = $txns->{stack} //= [];
    my $lookup = $txns->{lookup} //= {};

    my $sp;
    if (my $depth = @$stack) {
        $sp = "SAVEPOINT" . $depth;
        $self->create_savepoint($sp);
    }
    else {
        $sp = undef;
        $self->start_txn;
    }

    my $txn = DBIx::QuickORM::Connection::Transaction->new(
        connection => $self,
        savepoint => $sp,
    );

    push @$stack => $txn;
    $lookup->{"$txn"} = @$stack;

    weaken($stack->[-1]);

    return $txn;
}

sub stop_txn {
    my $self = shift;
    my ($txn, %params) = @_;

    my $txns = $self->{+TRANSACTIONS};
    my $stack = $txns->{stack} //= [];
    my $lookup = $txns->{lookup} //= {};

    # Already gone
    return unless $lookup->{$txn};

    confess "Attempt to stop transactions/savepoints out of order!" unless @$stack && $stack->[-1] == $txn;

    # Should be 'commit' or 'rollback'
    my $finalized = $txn->finalized;

    unless ($finalized) {
        confess "Attempt to stop a transaction that has not been commited or rolled back" unless $params{force};
        cluck "A transaction was forcefully stopped, $params{force}";
        $finalized = 'corrupt';
    }

    delete $txns->{lookup};
    pop @$stack;

    $self->{+ROW_CACHE}->pop_transaction($txn, $finalized);

    return 1;
}

################
# Transactions #
################

1;
