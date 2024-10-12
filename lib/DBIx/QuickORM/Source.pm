package DBIx::QuickORM::Source;
use strict;
use warnings;

use Carp qw/croak confess/;
use List::Util qw/min zip/;
use Scalar::Util qw/blessed weaken/;
use DBIx::QuickORM::Util qw/parse_hash_arg mod2file/;

use DBIx::QuickORM::Row;
use DBIx::QuickORM::Select;
use DBIx::QuickORM::Select::Async;

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <schema
    <table
    <orm
    <ignore_cache
    +row_class
};

use DBIx::QuickORM::Util::Has qw/Created Plugins/;

sub db { $_[0]->{+CONNECTION}->db }

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

sub set_row_class {
    my $self = shift;
    my ($class) = @_;

    require(mod2file($class));

    return $self->{+ROW_CLASS} = $class;
}

sub row_class {
    my $self = shift;
    return $self->{+ROW_CLASS} if $self->{+ROW_CLASS};

    my $class = $self->{+TABLE}->row_class or return $self->{+ROW_CLASS} = 'DBIx::QuickORM::Row';

    require(mod2file($class));

    return $self->{+ROW_CLASS} = $class;
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
    if (ref($_[0]) eq 'HASH') {
        return $_[0] if $_[0]->{where};
        return { where => $_[0] };
    }

    my $pk = $self->{+TABLE}->primary_key;
    croak "Cannot pass in a single value for find() or fetch() when table has no primary key"         unless $pk && @$pk;
    croak "Cannot pass in a single value for find() or fetch() when table has a compound primary key" unless @$pk == 1;
    return {where => {$pk->[0] => $_[0]}};
}

sub select_async {
    my $self = shift;
    my %params = @_;

    croak "Cannot use async select inside a transaction (use `ignore_transaction => 1` to do it anyway, knowing that the async select will not see any uncommited changes)"
        if $self->{+CONNECTION}->in_transaction && !$params{ignore_transaction};

    my $params;
    if (ref($_[0]) eq 'HASH') {
        $params = $self->_parse_find_and_fetch_args(shift(@_));
        $params->{order_by} = shift(@_) if @_ == 1;
    }

    $params = {%{$params // {}}, @_} if @_;

    return DBIx::QuickORM::Select::Async->new(source => $self, %$params);
}

sub select {
    my $self = shift;

    # {where}
    # {where}, order
    # where => ..., order => ..., ...
    # {where => { ... }, order => ..., ...}
    my $params;
    if (ref($_[0]) eq 'HASH') {
        $params = $self->_parse_find_and_fetch_args(shift(@_));
        $params->{order_by} = shift(@_) if @_ == 1;
    }

    $params = {%{$params // {}}, @_} if @_;

    return DBIx::QuickORM::Select->new(source => $self, %$params);
}

sub count_select {
    my $self = shift;
    my ($params) = @_;

    my $where = $params->{where};

    my $table = $self->{+TABLE};
    my $con = $self->{+CONNECTION};

    my $source = $table->sqla_source;
    $source = \"$source AS me" unless ref($source);
    my ($stmt, $bind) = $self->build_select_sql($source, ['count(*)'], $where);

    my $sth = $con->dbh->prepare($stmt);
    $sth->execute(@$bind);

    my ($count) = $sth->fetchrow_array;

    $count //= 0;

    if (my $limit = $params->{limit}) {
        $count = min($count, $limit);
    }

    return $count;
}

sub do_select {
    my $self = shift;
    my ($params) = @_;

    my $where = $params->{where};
    my $order = $params->{order_by};

    my $con = $self->{+CONNECTION};

    my ($source, $cols, $relmap) = $self->_source_and_cols($params->{prefetch});
    my ($stmt, $bind) = $self->build_select_sql($source, $cols, $where, $order ? $order : ());

    if (my $limit = $params->{limit}) {
        $stmt .= " LIMIT ?";
        push @$bind => $limit;
    }

    my $sth = $con->dbh->prepare($stmt);
    $sth->execute(@$bind);

    my @out;
    while (my $data = $sth->fetchrow_arrayref) {
        my $row = {};
        @{$row}{@$cols} = @$data;
        $self->expand_relations($row, $relmap);
        push @out => $self->_expand_row($row);
    }

    return \@out;
}

sub find {
    my $self  = shift;
    my $params = $self->_parse_find_and_fetch_args(@_);
    my $where = $params->{where};

    my $con = $self->{+CONNECTION};

    # See if there is a cached copy with the data we have
    unless ($self->{+IGNORE_CACHE}) {
        my $cached = $con->from_cache($self, $where);
        return $cached if $cached;
    }

    my $data = $self->fetch($params) or return;

    return $self->_expand_row($data);
}

# Get hashref data for one object (no cache)
sub fetch {
    my $self  = shift;
    my $params = $self->_parse_find_and_fetch_args(@_);
    my $where = $params->{where};

    my $con = $self->{+CONNECTION};

    my ($source, $cols, $relmap) = $self->_source_and_cols($params->{prefetch});
    my ($stmt, $bind) = $self->build_select_sql($source, $cols, $where);
    my $sth = $con->dbh->prepare($stmt);
    $sth->execute(@$bind);

    my $data = $sth->fetchrow_arrayref or return undef;
    my $extra = $sth->fetchrow_arrayref;
    croak "Multiple rows returned for fetch/find operation" if $extra;

    my $row = {};

    if ($relmap) {
        @{$row}{@$cols} = @$data;
        $self->expand_relations($row, $relmap);
    }
    else {
        s/^me\.// for @$cols;
        @{$row}{@$cols} = @$data;
    }


    return $row;
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
    my $row  = $self->row_class->new(from_db => $data, source => $self);

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

    $row_data = $self->deflate_row_data($row_data);

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

        my ($stmt, $bind) = $self->build_select_sql($table->sqla_source, $table->sqla_columns, $where);
        my $sth = $dbh->prepare($stmt);
        $sth->execute(@$bind);
        $data = $sth->fetchrow_hashref;
    }

    return $data;
}

sub build_select_sql {
    my $self = shift;
    my ($stmt, $bind, $bind_names) = $self->{+CONNECTION}->sqla->select(@_);

    die "Internal error: Length mistmatch between bind elements and bind names (" . @$bind . " vs " . @$bind_names . ")"
        unless @$bind == @$bind_names;

    my @new_bind = map { $self->deflate_column_data(@{$_}) } zip($bind_names, $bind);

    return ($stmt, \@new_bind);
}

sub deflate_row_data {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);

    my $new_data = {map {($_ => $self->deflate_column_data($_, $row_data->{$_}))} keys %$row_data};

    return $new_data;
}

sub deflate_column_data {
    my $self = shift;
    my ($col, $val) = @_;

    my $table = $self->{+TABLE};
    my $tname = $table->name;
    $col =~ s/^\S+\.// if index($col, '.');
    my $def = $table->column($col) or confess "Table '$tname' does not have a column '$col'";

    if (my $conf = $def->{conflate}) {
        return $conf->qorm_deflate(quote_bin => $self->{+CONNECTION}, source => $self, column => $def, value => $val, type => $self->{+CONNECTION}->column_type($tname, $col));
    }

    if (blessed($val) && $val->can('qorm_deflate')) {
        return $val->qorm_deflate(quote_bin => $self->{+CONNECTION}, source => $self, column => $def, value => $val, type => $self->{+CONNECTION}->column_type($tname, $col));
    }

    return $val;
}

sub vivify {
    my $self = shift;
    my $row_data = $self->parse_hash_arg(@_);
    return $self->row_class->new(dirty => $row_data, source => $self);
}

sub DESTROY {
    my $self = shift;

    my $con = $self->{+CONNECTION} or return;
    $con->remove_source_cache($self);

    return;
}

sub _expand_row {
    my $self = shift;
    my ($data) = @_;

    my %relations;

    for my $key (keys %$data) {
        my $row = $data->{$key} or next;
        next unless ref($row) eq 'HASH';

        my $rel = $self->{+TABLE}->relation($key);
        my $source = $self->{+ORM}->source($rel->table);

        $relations{$key} = $source->_expand_row(delete $data->{$key});
    }

    return $self->row_class->new(from_db => $data, source => $self, fetched_relations => \%relations)
        if $self->{+IGNORE_CACHE};

    my $con = $self->{+CONNECTION};

    if (my $cached = $con->from_cache($self, $data)) {
        $cached->refresh($data);
        $cached->update_fetched_relations(\%relations);
        return $cached;
    }

    return $con->cache_source_row(
        $self,
        $self->row_class->new(from_db => $data, source => $self, fetched_relations => \%relations),
    );
}

sub _source_and_cols {
    my $self = shift;
    my ($prefetch) = @_;

    my $table = $self->{+TABLE};
    my $prefetch_sets = $table->prefetch_relations($prefetch);

    unless (@$prefetch_sets) {
        my $source = $table->sqla_source;
        my $cols = $table->sqla_columns;

        return ($source, $cols) if ref($source);

        return (\"$source AS me", [map { "me.$_" } @$cols]);
    }

    my $source = $table->sqla_source . " AS me";
    my @cols   = map { "me.$_" } @{$table->sqla_columns};

    my %relmap;
    my @todo = map {[@{$_}, 'me'] } @$prefetch_sets;

    while (my $item = shift @todo) {
        my ($as, $rel, @path) = @$item;
        my ($from) = @path;

        confess "Multiple relations requested the alias (AS) '$as', please specify an alternate name for one"
            if $relmap{$as};

        my $ftable = $rel->table;

        $relmap{$as} = [@path, $as];

        my $ts = $self->orm->source($ftable);
        my $t2 = $ts->table;

        my $s2 = $t2->sqla_source;
        my $c2 = $t2->sqla_columns;

        $source .= " JOIN $s2 AS $as";
        $source .= " ON(" . $rel->on_sql($from, $as) . ")";

        push @cols => map { "${as}.$_" } @$c2;
        push @todo => map { [@{$_}, @path] } @{$t2->prefetch_relations};
    }

    return (\$source, \@cols, \%relmap);
}

sub expand_relations {
    my $self = shift;
    my ($data, $relmap) = @_;

    $relmap //= {};

    for my $key (keys %$data) {
        next unless $key =~ m/^(.+)\.(.+)$/;
        my ($rel, $col) = ($1, $2);
        if ($rel eq 'me') {
            $data->{$col} = delete $data->{$key};
            next;
        }

        my $path = $relmap->{$rel} or die "No relmap path for '$key'";

        my $p = $data;
        for my $pt (@$path) {
            next if $pt eq 'me';
            $p = $p->{$pt} //= {};
        }

        $p->{$col} = delete $data->{$key};
    }

    return $data;
}

1;
