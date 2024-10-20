package DBIx::QuickORM::Connection;
use strict;
use warnings;

use Carp qw/confess croak/;

require DBIx::QuickORM::SQLAbstract;

use DBIx::QuickORM::Util::HashBase qw{
    <db
    +dbh
    <pid
    <transaction
    <column_type_cache
    <sqla
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

    $self->{+TRANSACTION} //= 0;
}

sub dbh {
    my $self = shift;

    if ($$ != $self->{+PID}) {
        confess "Forked while inside a transaction" if $self->in_transaction;
        delete $self->{+ASYNC};
        return $self->{+DBH} = $self->db->connect(dbh_only => 1);
    }

    if (!($self->{+DBH}) || !($self->{+ASYNC} || eval { $self->{+DBH}->ping })) {
        delete $self->{+DBH};

        my @fatal;
        push @fatal => "transaction" if $self->in_transaction;
        push @fatal => "async query" if $self->{+ASYNC};

        die "Lost database connection during " . join(' and ', @fatal) if @fatal;

        warn "Lost database connection, reconnecting...\n";
        return $self->{+DBH} = $self->db->connect(dbh_only => 1);
    }

    return $self->{+DBH};
}

sub disconnect {
    my $self = shift;

    croak "Attempt to disconnect inside a transaction" if $self->in_transaction;
    croak "Attempt to disconnect with a pending async query" if $self->{+ASYNC};

    my $dbh = delete $self->{+DBH} or return;
    $dbh->disconnect or croak $dbh->errstr;

    return $self;
}

sub reconnect {
    my $self = shift;

    $self->disconnect;
    $self->dbh;

    return $self;
}

sub generate_schema {
    my $self = shift;
    require DBIx::QuickORM::Util::SchemaBuilder;
    return DBIx::QuickORM::Util::SchemaBuilder->generate_schema($self);
}

sub generate_table_schema {
    my $self = shift;
    my ($name) = @_;

    my $table = $self->table($name, details => 1);
    require DBIx::QuickORM::Util::SchemaBuilder;
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

sub commit_savepoint   { my $self = shift; $self->{+DB}->commit_savepoint($self->dbh, @_) }
sub rollback_savepoint { my $self = shift; $self->{+DB}->rollback_savepoint($self->dbh, @_) }

sub create_savepoint {
    my $self = shift;

    my $in_txn = $self->in_transaction;

    croak 'Connection is already inside a transaction, but it is not controlled by DBIx::QuickORM'
        if $in_txn < 0;

    croak 'Connection is not inside a transaction, cannot use create_savepoint outside of one'
        unless $in_txn;

    croak "Cannot start a transaction while an async query is running"
        if $self->{+ASYNC};

    croak 'Cannot start a transaction while side connections are active (use $sel->ignore_transactions() to bypass)'
        if $self->{+SIDE};

    $self->{+DB}->create_savepoint($self->dbh, @_);
}

sub commit_txn   { my $self = shift; $self->{+DB}->commit_txn($self->dbh, @_);   $self->{+TRANSACTION} = 0 }
sub rollback_txn { my $self = shift; $self->{+DB}->rollback_txn($self->dbh, @_); $self->{+TRANSACTION} = 0 }

sub start_txn {
    my $self = shift;

    my $in_txn = $self->in_transaction;

    croak 'Connection is already inside a transaction, but it is not controlled by DBIx::QuickORM'
        if $in_txn < 0;

    croak 'Already inside a transaction, create_savepoint() should be used instead'
        if $in_txn;

    croak "Cannot start a transaction while an async query is running"
        if $self->{+ASYNC};

    croak 'Cannot start a transaction while side connections are active (use $sel->ignore_transactions() to bypass)'
        if $self->{+SIDE};

    $self->{+DB}->start_txn($self->dbh, @_);

    $self->{+TRANSACTION} = 1;
}

sub in_transaction {
    my $self = shift;

    return 1 if $self->{+TRANSACTION};
    return -1 if $self->in_external_transaction;
}

sub in_external_transaction { $_[0]->{+DB}->in_txn($_[0]->dbh) ? 1 : 0 }

################
# Transactions #
################

1;

__END__


1;
