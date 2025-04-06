package DBIx::QuickORM::Connection;
use strict;
use warnings;
use feature qw/state/;

our $VERSION = '0.000005';

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/load_class/;

use DBIx::QuickORM::SQLAbstract;
use DBIx::QuickORM::Source;
use DBIx::QuickORM::Select;
use DBIx::QuickORM::Cache;

use DBIx::QuickORM::Util::HashBase qw{
    <orm
    <dbh
    <dialect
    <pid
    <cache
    <schema
    +sqla
    <transactions
    +_savepoint_counter
};

sub sqla {
    my $self = shift;
    return $self->{+SQLA}->() if $self->{+SQLA};

    my $sqla = DBIx::QuickORM::SQLAbstract->new(bindtype => 'columns');

    $self->{+SQLA} = sub { $sqla };

    return $sqla;
}

sub db { $_[0]->{+ORM}->db }

sub init {
    my $self = shift;

    my $orm = $self->{+ORM} or croak "An orm is required";
    my $db = $orm->db;

    $self->{+_SAVEPOINT_COUNTER} = 1;

    $self->{+PID} //= $$;

    $self->{+DBH} = $db->new_dbh;

    $self->{+DIALECT} = $db->dialect->new(dbh => $self->{+DBH}, db_name => $db->db_name);

    if (my $autofill = $orm->autofill) {
        my $schema = $self->{+DIALECT}->build_schema_from_db(autofill => $autofill);

        if (my $schema2 = $orm->schema) {
            $self->{+SCHEMA} = $schema->merge($schema2);
        }
        else {
            $self->{+SCHEMA} = $schema->clone;
        }
    }
    else {
        $self->{+SCHEMA} = $orm->schema->clone;
    }

    $self->{+CACHE} = DBIx::QuickORM::Cache->new
        unless exists $self->{+CACHE};
}

sub pid_check {
    my $self = shift;
    confess "Connections cannot be used across multiple processes, you must reconnect post-fork" unless $$ == $self->{+PID};
    return 1;
}

sub source {
    my $self = shift;
    croak "Not enough arguments" unless @_;
    my ($source) = @_;

    my %params;
    if (ref($source) eq 'SCALAR') {
        $params{sqla_source} = DBIx::QuickORM::SQLSource->new($source);
    }
    else {
        $params{sqla_source} = $self->schema->table($source);
    }

    $params{connection} = $self;
    return DBIx::QuickORM::Source->new(%params);
}

sub select {
    my $self = shift;
    $self->pid_check;

    croak "Not enough arguments" unless @_;

    my $source = shift;

    my ($where, $order_by, $limit);

    if (@_) {
        if (ref($_[0]) eq 'HASH') {
            $where    = shift;
            $order_by = shift;
            $limit    = shift;
        }
        else {
            my %params = @_;
            $where    = delete $params{where};
            $order_by = delete $params{order_by};
            $limit    = delete $params{limit};

            my @bad = sort keys %params;
            croak "Invalid parameters: " . join(", " => @bad) if @bad;
        }
    }

    croak "no source provided" unless $source;

    my %params;

    if (ref($source) eq 'SCALAR') {
        croak "Using a string reference as a source is not yet supported"; # FIXME
    }
    else {
        $params{sqla_source} = $self->schema->table($source);
    }

    $params{where}    = $where // {};
    $params{order_by} = $order_by if $order_by;
    $params{limit}    = $limit    if $limit;
    $params{connection} = $self;

    return DBIx::QuickORM::Select->new(%params);
}

sub build_row {
    my $self = shift;
    my %params = @_;

    my $row_class   = delete $params{row_class}   or croak "A row_class is required";
    my $sqla_source = delete $params{sqla_source} or croak "An sqla_source is required";
    my $row_data    = delete $params{row_data}    or croak "row_data is required";
    my $updated     = delete $params{updated};
    my $inserted    = delete $params{inserted};
    my $no_desync   = delete $params{no_desync} // $updated // $inserted;
    my $row         = delete $params{row};

    $row_data = $sqla_source->fields_remap_db_to_orm($row_data);
    delete $row_data->{__REMAPPED_DB_TO_ORM};

    my $cache = $self->cache;

    my $txn = $self->current_txn;

    $row //= $cache->lookup($sqla_source, $row_data) if $cache;
    if ($row) {
        $row->update_from_db_data($row_data, no_desync => $no_desync // 1, updated => $updated, transaction => $txn);
        $cache->update($row) if $cache; # Move to new cache key if pk changed
        return $row;
    }

    state $LOADED = {};
    unless ($LOADED->{$row_class}) {
        load_class($row_class) or die $@;
        $LOADED->{$row_class} = 1;
    }

    $row = $row_class->new(
        stored      => $row_data,
        sqla_source => $sqla_source,
        connection  => $self,
        transaction => $txn,
    );

    $cache->store($row) if $cache;

    return $row;
}

{
    no warnings 'once';
    *transaction = \&txn;
}
sub txn {
    my $self = shift;

    my $txns = $self->{+TRANSACTIONS} //= [];

    my $cb = (@_ && ref($_[0]) eq 'CODE') ? shift : undef;
    my %params = @_;

    my $txn = DBIx::QuickORM::Transaction->new(%params, started => 0, result => undef, connection => $self);

    if (@$txns) {
        my $sp = "SAVEPOINT_${$}_" . $self->{+_SAVEPOINT_COUNTER}++;
        $self->dialect->create_savepoint($sp);
        $txn->set_savepoint($sp);
        $txn->set_started(1);
    }
    elsif ($self->dialect->in_txn) {
        croak "A transaction is already open, but it is not controlled by DBIx::QuickORM";
    }
    else {
        $self->dialect->start_txn;
    }

    push @{$txns} => $txn;

    my $out;
    my $ok = eval { $out = $cb->($txn); 1 };
    my $err = $@;

    # End the transaction, and any nested ones
    while (my $x = pop @{$txns}) {
        $txn->terminate($ok, $err);
        last if $x == $txn;
    }

    die $err unless $ok;
    return $out;
}

{
    no warnings 'once';
    *in_transaction = \&in_txn;
}
sub in_txn {
    my $self = shift;
    return $self->current_txn // $self->dialect->in_txn;
}

{
    no warnings 'once';
    *current_transaction = \&current_txn;
}
sub current_txn {
    my $self = shift;

    if (my $txns = $self->{+TRANSACTIONS}) {
        return $txns->[-1] if @$txns;
    }

    return undef;
}

1;
