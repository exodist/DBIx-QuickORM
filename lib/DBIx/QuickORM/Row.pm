package DBIx::QuickORM::Row;
use strict;
use warnings;

use Scalar::Util qw/weaken blessed/;
use Sub::Util qw/set_subname/;
use Carp qw/croak/;

use DBIx::QuickORM::Util qw/parse_hash_arg/;

use DBIx::QuickORM::Util::HashBase qw{
    +source
    +table_name
    <from_db
    <inflated
    <dirty
    txn_id
};

sub init {
    my $self = shift;

    my $source = delete $self->{+SOURCE} or croak "'source' is a required attribute";
    croak "'source' must be an instance of 'DBIx::QuickORM::Source'" unless $source->isa('DBIx::QuickORM::Source');
    weaken($source);
    $self->{+SOURCE} = sub { $source };

    $self->{+TXN_ID} = $source->connection->txn_id;
}

sub set_uncached { }

sub source     { $_[0]->{+SOURCE}->() }
sub table      { $_[0]->source->table }
sub connection { $_[0]->source->connection }
sub orm        { $_[0]->source->orm }
sub table_name { $_[0]->{+TABLE_NAME} //= $_[0]->table->name }

sub in_db    { $_[0]->{+FROM_DB} ? 1 : 0 }
sub is_dirty { $_[0]->{+DIRTY}   ? 1 : 0 }

sub primary_key {
    my $self = shift;

    my $pk_fields = $self->table->primary_key;
    return { map {($_ => $self->raw_column($_))} @$pk_fields };
}

sub column_def { $_[0]->table->column($_[1]) }
sub has_column { $_[0]->column_def($_[1]) ? 1 : 0 }

sub _relation_spec {
    my $self = shift;
    my ($accessor, $table, $order_by, %params);

    if (@_ <= 2) {
        ($accessor, $table) = reverse @_;
    }
    elsif (@_ % 2) {
        ($accessor, %params) = @_;
    }

    $order_by //= $params{order_by};
    $table    //= $params{table};

    my $source = $self->source;
    $table //= $self->table;
    $table = $source->orm->table($table) if $table && !blessed($table);

    croak "Could not determine table (or 'table') to use for relation, please specify one" unless $table;

    my $relation = $table->relation($accessor) or croak "'$accessor' is not defined as a relation accessor on this table";
    my $spec     = $relation->get_accessor($table->name, $accessor);

    return {
        %params,
        accessor => $accessor,
        order_by => $order_by,
        relation => $relation,
        source   => $source,
        table     => $table,
        %$spec,
    };
}

sub _relation_query {
    my $self = shift;
    my ($params) = @_;

    my $source = $params->{source};
    my $cols   = $params->{local_columns};
    my $ftable = $params->{foreign_table};
    my $fcols  = $params->{foreign_columns};

    my $source2 = $source->orm->source($ftable);
    my @vals    = map { $self->_raw_col($_) // undef } @$cols;

    return ($source2, {map { ($_ => shift(@vals)) } @$fcols});
}

sub relation {
    my $self = shift;
    my $params = $self->_relation_spec(@_);

    croak "Reference accessor '$params->{accessor}' is not a foreign key on this table, use relations() instead" unless $params->{foreign_key};
    croak "order by is not supported in relation()" if $params->{order_by};

    my ($source, $query) = $self->_relation_query($params);
    return $source->find(%$query);
}

sub relations {
    my $self = shift;
    my $params = $self->_relation_spec(@_);

    croak "Reference accessor '$params->{accessor}' is a foreign key on this table, use relation() instead" if $params->{foreign_key};

    my ($source, $query) = $self->_relation_query($params);

    return $source->select($query, $params->{order_by} ? $params->{order_by} : ());
}

sub generate_relation_accessor {
    my $self = shift;
    my ($accessor, $alias) = @_;

    $alias //= $accessor;

    my $source   = $self->source;
    my $table    = $source->table;
    my $relation = $table->relation($accessor) or croak "'$accessor' is not defined as a relation accessor on this table";
    my $spec     = $relation->get_accessor($table->name, $accessor);

    my ($cols, $ftable, $fcols, $fk) = @$spec;

    my $meth = $fk ? 'find' : 'select';

    return set_subname $alias => sub {
        my $self = shift;

        my $source2 = $self->source->orm->source($ftable);
        my @vals    = map { $self->_raw_col($_) // undef } @$cols;

        return $source2->$meth(map { ($_ => shift(@vals)) } @$fcols);
    };
}

sub column {
    my $self = shift;
    my ($col, $val) = @_;

    croak "No such column '$col'" unless $self->has_column($col);

    if (@_ > 1) {
        $self->{+DIRTY}->{$col} = $val;
        delete $self->{+INFLATED}->{$col};
    }

    return $self->_inflated_col($col) // $self->_dirty_col($col) // $self->_from_db_col($col);
}

sub generate_column_accessor {
    my $self = shift;
    my ($col, $alias) = @_;

    croak "No such column '$col'" unless $self->has_column($col);

    $alias //= $col;

    return set_subname $alias => sub {
        my $self = shift;

        if (@_) {
            my ($val) = @_;
            $self->{+DIRTY}->{$col} = $val;
            delete $self->{+INFLATED}->{$col};
        }

        return $self->_inflated_col($col) // $self->_dirty_col($col) // $self->_from_db_col($col);
    };
}

sub raw_column      { croak "No such column '$_[1]'" unless $_[0]->has_column($_[1]); $_[0]->_raw_col($_[1]) }
sub dirty_column    { croak "No such column '$_[1]'" unless $_[0]->has_column($_[1]); $_[0]->_dirty_col($_[1]) }
sub stored_column   { croak "No such column '$_[1]'" unless $_[0]->has_column($_[1]); $_[0]->_from_db_col($_[1]) }
sub inflated_column { croak "No such column '$_[1]'" unless $_[0]->has_column($_[1]); $_[0]->_inflated_col($_[1]) }

sub _raw_col     { $_[0]->_dirty_col($_[1]) // $_[0]->_from_db_col($_[1]) // undef }
sub _dirty_col   { $_[0]->{+DIRTY}   ? $_[0]->{+DIRTY}->{$_[1]}   // undef : undef }
sub _from_db_col { $_[0]->{+FROM_DB} ? $_[0]->{+FROM_DB}->{$_[1]} // undef : undef }

sub _inflated_col {
    my $self = shift;
    my ($col) = @_;

    $self->{+INFLATED} //= {};
    return $self->{+INFLATED}->{$col} if exists $self->{+INFLATED}->{$col};
    return $self->{+INFLATED}->{$col} = $self->_inflate($col);
}

sub _inflate {
    my $self = shift;
    my ($col) = @_;

    my $def      = $self->column_def($col) or return undef;
    my $conflate = $def->conflate          or return undef;

    for my $loc (DIRTY(), FROM_DB()) {
        next unless exists $self->{$loc}->{$col};
        my $val = $self->{$loc}->{$col};
        return $conflate->inflate($val);
    }

    return undef;
}

# Update data form db, but do not reset dirty stuff
sub refresh {
    my $self = shift;
    my ($data) = @_;

    $data //= $self->source->fetch($self->primary_key);
    $self->{+FROM_DB} = $data;

    my $dirty = $self->{+DIRTY} // {};
    delete $self->{+INFLATED}->{$_} for grep { !$dirty->{$_} } keys %$data;

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

    croak "Object is not yet in the database, use insert or save" unless $self->{+FROM_DB};

    $row_data = { %{delete($self->{+DIRTY}) // {}}, %$row_data };

    my $primary_key = $self->primary_key;

    my $source = $self->source;
    my $table  = $source->table;
    my $tname  = $table->name;
    my @cols   = $table->column_names;
    my $con    = $source->connection;
    my $ret    = $con->db->update_returning_supported;

    my ($stmt, @bind) = $con->sqla->update($tname, $row_data, $primary_key, $ret ? {returning => \@cols} : ());

    my $dbh = $con->dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    my $data;
    if ($ret) {
        $data = $sth->fetchrow_hashref;
    }
    else {
        # An update could theoretically update the primary key values, so get
        # new ones
        my ($stmt, @bind) = $con->sqla->select($tname, \@cols, $self->primary_key);
        my $sth = $dbh->prepare($stmt);
        $sth->execute(@bind);
        $data = $sth->fetchrow_hashref;
    }

    return $self->refresh($data);
}

sub delete {
    my $self = shift;

    croak "Object is not yet in the database, use insert or save" unless $self->{+FROM_DB};

    my $primary_key = $self->primary_key;

    my $source = $self->source;
    my $table  = $source->table;
    my $tname  = $table->name;
    my @cols   = $table->column_names;
    my $con    = $source->connection;
    my $ret    = $con->db->update_returning_supported;

    my ($stmt, @bind) = $con->sqla->delete($tname, $primary_key);

    my $dbh = $con->dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    $self->{+DIRTY} = { %{delete $self->{+FROM_DB}}, %{$self->{+DIRTY} // {}} };

    return $con->uncache_source_row($source, $self);

    return $self;
}

# Clear dirty stuff
sub reset  {
    my $self = shift;

    delete $self->{+DIRTY};
    delete $self->{+INFLATED};

    return $self;
}

# refresh and reset
sub reload {
    my $self = shift;

    $self->refresh;
    $self->reset;

    return $self;
}

1;
