package DBIx::QuickORM::Row;
use strict;
use warnings;

use Scalar::Util qw/weaken blessed/;
use Carp qw/croak confess/;

use DBIx::QuickORM::Util qw/parse_hash_arg mask unmask masked/;

require DBIx::QuickORM::Row::DataStack;

use DBIx::QuickORM::Util::HashBase qw{
    +source
    +table
    +table_name
    +data
    <fetched_relations
    <uncached
};

sub init {
    my $self = shift;

    my $source = delete $self->{+SOURCE} or croak "'source' is a required attribute";
    croak "'source' must be an instance of 'DBIx::QuickORM::Source'" unless $source->isa('DBIx::QuickORM::Source');

    $source = mask($source, weaken => 1) if blessed($source) && !masked($source);
    $self->{+SOURCE} = $source;

    my $fdb = delete $self->{from_db};
    my $dty = delete $self->{dirty};
    my $inf = delete $self->{inflated};
    my $txn = delete $self->{txn};

    if ($self->{+DATA}) {
        croak "Cannot initialize with a populated data array AND 'from_db', 'dirty', 'inflated', or 'txn' fields"
            if $fdb || $dty || $inf || $txn;
    }
    else {
        croak "Cannot have references in the from_db data" if $fdb && grep { ref($_) } values %$fdb;
        croak "Cannot have references in the dirty data"   if $dty && grep { ref($_) } values %$dty;

        my $set = {};
        $set->{from_db}     = $fdb if $fdb;
        $set->{dirty}       = $dty if $dty;
        $set->{transaction} = $txn if $txn;
        $set->{inflated}    = $inf if $inf;
        $set->{types} = $self->column_compare_types;

        $self->{+DATA} = DBIx::QuickORM::Row::DataStack->new($set);
    }
}

sub column_compare_types {
    my $self = shift;

    my $table = $self->table;
    my $cols = $table->columns;

    my $out = {};

    for my $name (keys %$cols) {
        my $col = $cols->{$name};
        $out->{$name} = $col->compare_type($self->column_type($name));
    }

    return $out;
}

sub column_type { $_[0]->connection->column_type($_[0]->table_name, $_[1]) }

sub _update_fetched_relations {
    my $self = shift;
    my ($relations) = @_;

    $self->{+FETCHED_RELATIONS} = { %{$self->{+FETCHED_RELATIONS} // {}}, %$relations };
}

sub uncache {
    my $self = shift;

    return if $self->{+UNCACHED}++;

    my $con = $self->connection;
    $con->uncache_source_row($self->source, $self);

    $self->{+TABLE} //= $self->table;

    delete $self->{+FETCHED_RELATIONS};
    delete $self->{+SOURCE};

    $self->{+DATA}->uncache;

    return;
}

sub source {
    my $self = shift;

    croak "This row has been 'uncached' and can no longer interact with the database. You need to fetch the row from the database again"
        if $self->{+UNCACHED};

    my $source = $self->{+SOURCE} or croak "The row has no source!";
    return $source if blessed($source) && $source->isa('DBIx::QuickORM::Source');

    confess($source->{error}) if ref($source) eq 'HASH' && $source->{error};

    require Data::Dumper;
    confess "Something is wrong with the source: " . Data::Dumper::Dumper($source);
}

sub real_source { unmask($_[0]->source) }
sub connection  { $_[0]->source->connection }
sub db          { $_[0]->source->connection->db }
sub orm         { $_[0]->source->orm }
sub table       { $_[0]->{+TABLE} // $_[0]->source->table }
sub table_name  { $_[0]->{+TABLE_NAME} //= $_[0]->table->name }

sub is_tainted { $_[0]->{+DATA}->is_tainted }
sub is_stored  { $_[0]->{+DATA}->is_stored  }
sub is_dirty   { $_[0]->{+DATA}->is_dirty   }

sub primary_key {
    my $self = shift;

    my $pk_fields = $self->table->primary_key;
    my $data = $self->{+DATA};
    return { map {($_ => $data->raw($_))} @$pk_fields };
}

sub column_def   { $_[0]->table->column($_[1]) }
sub relation_def { $_[0]->table->relation($_[1]) }

sub has_column   { $_[0]->column_def($_[1])   ? 1 : 0 }
sub has_relation { $_[0]->relation_def($_[1]) ? 1 : 0 }

sub relation {
    my $self = shift;
    my ($name, %params) = @_;

    my $rel = $self->table->relation($name) or croak "'$name' is not a relation on this rows table (" . $self->table_name . ")";
    croak "Relation '$name' can return multiple items, use \$row->relations('$name') instead" unless $rel->gets_one;
    croak "order_by is not supported in relation()" if $params{order_by};

    return $self->{+FETCHED_RELATIONS}->{$name} if $self->{+FETCHED_RELATIONS}->{$name};

    my $source = $self->orm->source($rel->table);

    my $on = $rel->on;
    my %query = map {("me.$on->{$_}" => $self->_raw_col($_))} keys %$on;

    my $row = $source->find(%query) or return undef;

    return $self->{+FETCHED_RELATIONS}->{$name} = $row;
}

sub relations {
    my $self = shift;
    my ($name, %params) = @_;

    my $rel = $self->table->relation($name) or croak "'$name' is not a relation on this rows table (" . $self->table_name . ")";
    croak "Relation '$name' returns a single row, use \$row->relation('$name') instead" unless $rel->gets_many;

    my $source = $self->orm->source($rel->table);

    my $on = $rel->on;
    my %query = map {("me.$on->{$_}" => $self->_raw_col($_))} keys %$on;

    return $source->select(
        where => \%query,
        map { $params{$_} ? ($_ => $params{$_}) : () } qw/order_by limit prefetch/,
    );
}

sub column {
    my $self = shift;
    my ($col, $val) = @_;

    croak "No such column '$col'" unless $self->has_column($col);

    my $data = $self->{+DATA};

    if (@_ > 1) {
        my ($raw, $inflated);

        my $def = $self->column_def($col) or croak "No such column '$col'";

        if (my $conf = $def->conflate) {
            ($raw, $inflated) = $conf->qorm_inflate(column => $def, value => $val, type => $self->column_type($col));
        }

        $raw //= $val;

        $data->set($col, $raw, $inflated);
    }

    return $data->val($col);
}

sub raw_column      { croak "No such column '$_[1]'" unless $_[0]->has_column($_[1]); $_[0]->{+DATA}->raw($_[0]) }
sub dirty_column    { croak "No such column '$_[1]'" unless $_[0]->has_column($_[1]); $_[0]->{+DATA}->dirty($_[0]) }
sub stored_column   { croak "No such column '$_[1]'" unless $_[0]->has_column($_[1]); $_[0]->{+DATA}->stored($_[0]) }

sub inflated_column {
    my $self = shift;
    my ($col) = @_;

    croak "No such column 'col'" unless $self->has_column($col);

    my $data = $self->{+DATA};

    my $inf = $data->inflated($col);
    return $inf if $inf;

    my $def      = $self->column_def($col) or return undef;
    my $conflate = $def->conflate          or return undef;

    my $raw = $data->raw($col);

    $inf = $conflate->qorm_inflate(column => $def, value => $raw, type => $self->connection->column_type($self->table_name, $col));

    $data->set_inflated($col, $inf) if $inf;

    return $inf;
}

# Update data form db, but do not reset dirty stuff
sub refresh { $_[0]->_refresh() }

sub _refresh {
    my $self = shift;
    my ($new_data) = @_;

    my $source = $self->source;

    $new_data //= $source->fetch($self->primary_key);

    my $txn = $source->transaction;
    my $data = $self->{+DATA};
    $data->refresh(from_db => $new_data, transaction => $txn);

    return $self;
}

# update or insert
sub save {
    my $self = shift;

    return $self->update if $self->from_db;
    return $self->insert;
}

sub insert { $_[0]->source->insert_row($_[0]) }

sub update {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);

    my $data = $self->{+DATA};

    croak "Object is not yet in the database, use insert or save" unless $data->is_stored;

    my $source = $self->real_source;

    $row_data = $source->deflate_row_data(%{$data->dirty // {}}, %$row_data);

    my $primary_key = $self->primary_key;

    my $table  = $source->table;
    my $tname  = $self->name;
    my @cols   = $table->column_names;
    my $con    = $source->connection;
    my $ret    = $con->db->update_returning_supported;

    my ($stmt, @bind) = $con->sqla->update($tname, $row_data, $primary_key, $ret ? {returning => \@cols} : ());

    my $dbh = $con->dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    my $new_data;
    if ($ret) {
        $new_data = $sth->fetchrow_hashref;
    }
    else {
        # An update could theoretically update the primary key values, so get
        # new ones
        my ($stmt, $bind) = $source->build_select_sql($tname, \@cols, $self->primary_key);
        my $sth = $dbh->prepare($stmt);
        $sth->execute(@$bind);
        $new_data = $sth->fetchrow_hashref;
    }

    return $self->_refresh($new_data);
}

sub delete {
    my $self = shift;

    my $data = $self->{+DATA};

    croak "Object is not yet in the database, use insert or save" unless $data->is_stored;

    my $primary_key = $self->primary_key;

    my $source = $self->real_source;
    my $table  = $source->table;
    my $tname  = $table->name;
    my @cols   = $table->column_names;
    my $con    = $source->connection;
    my $ret    = $con->db->update_returning_supported;

    my ($stmt, @bind) = $con->sqla->delete($tname, $primary_key);

    my $dbh = $con->dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    $self->uncache;

    return $self;
}

# Clear dirty stuff
sub reset { $_[0]->{+DATA}->reset }

# refresh and reset
sub reload {
    my $self = shift;

    $self->refresh;
    $self->reset;

    return $self;
}

1;
