package DBIx::QuickORM::Connection;
use strict;
use warnings;
use feature qw/state/;

our $VERSION = '0.000005';

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/load_class/;

use DBIx::QuickORM::SQLAbstract;
use DBIx::QuickORM::SQLASource;
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
};

sub sqla {
    my $self = shift;
    return $self->{+SQLA}->() if $self->{+SQLA};

    my $sqla = DBIx::QuickORM::SQLAbstract->new;

    $self->{+SQLA} = sub { $sqla };

    return $sqla;
}

sub db { $_[0]->{+ORM}->db }

sub init {
    my $self = shift;

    my $orm = $self->{+ORM} or croak "An orm is required";
    my $db = $orm->db;

    $self->{+PID} //= $$;

    $self->{+DBH} = $db->new_dbh;

    $self->{+DIALECT} = $db->dialect->new(dbh => $self->{+DBH}, db_name => $db->db_name);

    if ($orm->autofill) {
        my $schema = $self->{+DIALECT}->build_schema_from_db;

        if (my $schema2 = $orm->schema) {
            $self->{+SCHEMA} = $schema->merge($schema2);
        }
        else {
            $self->{+SCHEMA} = $schema;
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
        $params{sqla_source} = DBIx::QuickORM::SQLASource->new($source);
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

    my $row_class   = $params{row_class}   or croak "A row_class is required";
    my $sqla_source = $params{sqla_source} or croak "An sqla_source is required";
    my $row_data    = $params{row_data}    or croak "row_data is required";

    my $cache = $self->cache;

    my $row;
    if ($row = $params{row}) {
        $cache->update($row, $row_data) if $cache; # Move to new cache key if pk changed
        $row->update_from_db_data($row_data, no_desync => 1);
        return $row;
    }

    if ($cache) {
        if ($row = $cache->lookup($sqla_source, $row_data)) {
            $row->update_from_db_data($row_data, no_desync => 0);
            return $row;
        }
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
    );

    $cache->store($row) if $cache;

    return $row;
}

1;
