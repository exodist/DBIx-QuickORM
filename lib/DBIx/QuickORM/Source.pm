package DBIx::QuickORM::Source;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed weaken/;
use DBIx::QuickORM::Util qw/parse_hash_arg/;

use DBIx::QuickORM::Source::Join;
use DBIx::QuickORM::Row;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <schema
    <table
    <orm
    <ignore_cache
};

use DBIx::QuickORM::Util::Has qw/Created Plugins/;

sub init {
    my $self = shift;

    my $table = $self->{+TABLE} or croak "The 'table' attribute must be provided";
    croak "The 'table' attribute must be an instance of 'DBIx::QuickORM::Table'" unless $table->isa('DBIx::QuickORM::Table');

    my $schema = $self->{+SCHEMA} or croak "The 'schema' attribute must be provided";
    croak "The 'schema' attribute must be an instance of 'DBIx::QuickORM::Schema'" unless $schema->isa('DBIx::QuickORM::Schema');

    my $connection = $self->{+CONNECTION} or croak "The 'connection' attribute must be provided";
    croak "The 'connection' attribute must be an instance of 'DBIx::QuickORM::Connection'" unless $connection->isa('DBIx::QuickORM::Connection');

    weaken($self->{+CONNECTION});
    weaken($self->{+ORM});

    $self->{+IGNORE_CACHE} //= 0;
}

sub uncached {
    my $self = shift;
    my ($callback) = @_;

    if ($callback) {
        local $self->{+IGNORE_CACHE} = 1;
        return $callback->($self);
    }

    return $self->clone(IGNORE_CACHE => 1);
}

sub transaction {
    my $self = shift;
    $self->{+CONNECTION}->transaction(@_);
}

sub clone {
    my $self   = shift;
    my %params = @_;
    my $class  = blessed($self);

    unless ($params{+CREATED}) {
        my @caller = caller();
        $params{+CREATED} = "$caller[1] line $caller[2]";
    }

    return $class->new(
        %$self,
        %params,
    );
}

sub update_or_insert {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);

    unless ($self->{+IGNORE_CACHE}) {
        if (my $cached = $self->{+CONNECTION}->from_cache($self, $row_data)) {
            $cached->update($row_data);
            return $cached;
        }
    }

    my $row = $self->transaction(sub {
        if (my $row = $self->find($row_data)) {
            $row->update($row_data);
            return $row;
        }

        return $self->insert($row_data);
    });

    $row->set_txn_id($self->{+CONNECTION}->txn_id);

    return $self->{+CONNECTION}->cache_source_row($self, $row) unless $self->{+IGNORE_CACHE};
    return $row;
}

sub find_or_insert {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);

    unless ($self->{+IGNORE_CACHE}) {
        if (my $cached = $self->{+CONNECTION}->from_cache($self, $row_data)) {
            $cached->update($row_data);
            return $cached;
        }
    }

    my $row = $self->transaction(sub { $self->find($row_data) // $self->insert($row_data) });

    $row->set_txn_id($self->{+CONNECTION}->txn_id);

    return $self->{+CONNECTION}->cache_source_row($self, $row) unless $self->{+IGNORE_CACHE};
    return $row;
}

sub _parse_find_and_fetch_args {
    my $self = shift;

    return {@_} unless @_ == 1;
    return $_[0] if ref($_[0]) eq 'HASH';

    my $pk = $self->{+TABLE}->primary_key;
    croak "Cannot pass in a single value for find() or fetch() when table has no primary key"         unless $pk && @$pk;
    croak "Cannot pass in a single value for find() or fetch() when table has a compound primary key" unless @$pk == 1;
    return {$pk->[0] => $_[0]};
}

sub select {
    my $self  = shift;
    my ($where, $order) = @_;

    $where = $self->_parse_find_and_fetch_args($where);

    my $con   = $self->{+CONNECTION};
    my $table = $self->{+TABLE};
    my $tname = $table->name;

    my ($stmt, @bind) = $con->sqla->select($tname, [$table->column_names], $where);
    my $sth = $con->dbh->prepare($stmt);
    $sth->execute(@bind);

    my @out;
    while (my $data = $sth->fetchrow_hashref) {
        if ($self->{+IGNORE_CACHE}) {
            push @out => DBIx::QuickORM::Row->new(from_db => $data, source => $self);
        }
        else {
            if (my $cached = $con->from_cache($self, $data)) {
                $cached->refresh($data);
                push @out => $cached;
            }
            else {
                push @out => $con->cache_source_row(
                    $self,
                    DBIx::QuickORM::Row->new(from_db => $data, source => $self),
                );
            }
        }
    }

    return \@out;
}

sub find {
    my $self  = shift;
    my $where = $self->_parse_find_and_fetch_args(@_);

    my $con = $self->{+CONNECTION};

    # See if there is a cached copy with the data we have
    unless ($self->{+IGNORE_CACHE}) {
        my $cached = $con->from_cache($self, $where);
        return $cached if $cached;
    }

    my $data = $self->fetch($where) or return;

    # Look for a cached copy now that we have all the data
    unless ($self->{+IGNORE_CACHE}) {
        if (my $cached = $con->from_cache($self, $data)) {
            $cached->refresh($data);
            return $cached;
        }
    }

    my $row = DBIx::QuickORM::Row->new(from_db => $data, source => $self);

    return $row if $self->{+IGNORE_CACHE};
    return $con->cache_source_row($self, $row);
}

# Get hashref data for one object (no cache)
sub fetch {
    my $self  = shift;
    my $where = $self->_parse_find_and_fetch_args(@_);

    my $con   = $self->{+CONNECTION};
    my $table = $self->{+TABLE};
    my $tname = $table->name;

    my ($stmt, @bind) = $con->sqla->select($tname, [$table->column_names], $where);
    my $sth = $con->dbh->prepare($stmt);
    $sth->execute(@bind);

    my $data = $sth->fetchrow_hashref or return;
    my $extra = $sth->fetchrow_hashref;

    croak "Multiple rows returned for fetch/find operation" if $extra;

    return $data;
}

sub insert_row {
    my $self = shift;
    my ($row) = @_;

    croak "Row already exists in the database" if $row->from_db;

    my $row_data = $row->dirty;

    my $data = $self->_insert($row_data);

    $row->refresh($data);

    my $con = $self->{+CONNECTION};

    return $row if $self->{+IGNORE_CACHE};
    return $con->cache_source_row($self, $row);
}

sub insert {
    my $self     = shift;
    my $row_data = $self->parse_hash_arg(@_);

    my $data = $self->_insert($row_data);
    my $row  = DBIx::QuickORM::Row->new(from_db => $data, source => $self);

    my $con = $self->{+CONNECTION};
    return $row if $self->{+IGNORE_CACHE};
    return $con->cache_source_row($self, $row);
}

sub _insert {
    my $self = shift;
    my ($row_data) = @_;

    my $con   = $self->{+CONNECTION};
    my $ret   = $con->db->insert_returning_supported;
    my $table = $self->{+TABLE};
    my $tname = $table->name;


    my ($stmt, @bind) = $con->sqla->insert($tname, $row_data, $ret ? {returning => [$table->column_names]} : ());

    my $dbh = $con->dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    my $data;
    if ($ret) {
        $data = $sth->fetchrow_hashref;
    }
    else {
        my $pk_fields = $self->{+TABLE}->primary_key;

        my $where;
        if (@$pk_fields > 1) {
            $where = {map { my $v = $row_data->{$_} or croak "Auto-generated compound primary keys are not supported for databses that do not support 'returning' functionality"; ($_ => $v) } @$pk_fields};
        }
        else {
            my $kv = $dbh->last_insert_id(undef, undef, $tname);
            $where = {$pk_fields->[0] => $kv};
        }

        my ($stmt, @bind) = $con->sqla->select($tname, [$table->column_names], $where);
        my $sth = $dbh->prepare($stmt);
        $sth->execute(@bind);
        $data = $sth->fetchrow_hashref;
    }

    return $data;
}

sub vivify {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);
    return DBIx::QuickORM::Row->new(dirty => $row_data, source => $self);
}

sub DESTROY {
    my $self = shift;

    my $con = $self->{+CONNECTION} or return;
    $con->remove_source_cache($self);

    return;
}

1;
