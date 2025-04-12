package DBIx::QuickORM::Connection;
use strict;
use warnings;
use feature qw/state/;

our $VERSION = '0.000005';

use Carp qw/confess croak cluck/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/load_class debug/;

use DBIx::QuickORM::SQLAbstract;
use DBIx::QuickORM::Select;
use DBIx::QuickORM::Source;
use DBIx::QuickORM::Connection::Transaction;

use DBIx::QuickORM::Util::HashBase qw{
    <orm
    <dbh
    <dialect
    <pid
    <schema
    +sqla
    <transactions
    +_savepoint_counter
    +_txn_counter
    <manager
    +internal_transactions
};

sub enable_internal_transactions  { $_[0]->{+INTERNAL_TRANSACTIONS} = 1 }
sub disable_internal_transactions { $_[0]->{+INTERNAL_TRANSACTIONS} = 0 }
sub internal_transactions_enabled { $_[0]->{+INTERNAL_TRANSACTIONS} ? 1 : 0 }

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
    $self->{+_TXN_COUNTER} = 1;

    $self->{+PID} //= $$;

    $self->{+DBH} = $db->new_dbh;

    $self->{+DIALECT} = $db->dialect->new(dbh => $self->{+DBH}, db_name => $db->db_name);

    $self->{+INTERNAL_TRANSACTIONS} //= 1;

    my $txns = $self->{+TRANSACTIONS} //= [];
    my $manager = $self->{+MANAGER} // 'DBIx::QuickORM::RowManager::Cached';
    if (blessed($manager)) {
        $manager->set_connection($self);
        $manager->set_transactions($txns);
    }
    else {
        my $class = load_class($manager) or die $@;
        $self->{+MANAGER} = $class->new(transactions => $txns, connection => $self);
    }

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

    if (ref($source) eq 'SCALAR') {
        die "FIXME";
    }

    return DBIx::QuickORM::Source->new(
        connection  => $self,
        sqla_source => $self->schema->table($source),
    );
}

sub _internal_txn {
    my $self = shift;
    my ($cb) = @_;

    # No txn if internal txns are disabled
    return $cb->() unless $self->{+INTERNAL_TRANSACTIONS};

    # Already inside a qorm txn
    return $cb->() if $self->{+TRANSACTIONS} && @{$self->{+TRANSACTIONS}};

    # Already inside a non qorm txn
    return $cb->() if $self->dialect->in_txn;

    # Need a txn!
    return $self->txn(@_);
}

{
    no warnings 'once';
    *transaction = \&txn;
}
sub txn {
    my $self = shift;

    my $txns = $self->{+TRANSACTIONS};

    my $cb = (@_ && ref($_[0]) eq 'CODE') ? shift : undef;
    my %params = @_;
    $cb //= $params{action};

    croak "You must provide an 'action' coderef, either as the first argument to txn, or under the 'action' key in a parameterized list"
        unless $cb;

    my $id = $self->{+_TXN_COUNTER}++;

    my $dialect = $self->dialect;

    my $sp;
    if (@$txns) {
        $sp = "SAVEPOINT_${$}_" . $self->{+_SAVEPOINT_COUNTER}++;
        $dialect->create_savepoint($sp);
    }
    elsif ($self->dialect->in_txn) {
        croak "A transaction is already open, but it is not controlled by DBIx::QuickORM";
    }
    else {
        $dialect->start_txn;
    }

    my $txn = DBIx::QuickORM::Connection::Transaction->new(
        id            => $id,
        savepoint     => $sp,
        on_fail       => $params{on_fail},
        on_success    => $params{on_success},
        on_completion => $params{on_completion},
    );

    push @{$txns} => $txn;

    local $@;
    my $ok = eval {
        QORM_TRANSACTION: {
            $cb->($txn);
        }

        1;
    };
    my $err = $ok ? [] : [$@];

    croak "Internal Error: Transaction stack mismatch"
        unless @$txns && $txns->[-1] == $txn;

    pop @$txns;

    my $rolled_back = $txn->rolled_back;
    my $res         = $ok && !$rolled_back;

    if ($sp) {
        if   ($res) { $dialect->commit_savepoint($sp) }
        else        { $dialect->rollback_savepoint($sp) }
    }
    else {
        if   ($res) { $dialect->commit_txn }
        else        { $dialect->rollback_txn }
    }

    my ($ok2, $err2) = $txn->terminate($res, $err);
    unless ($ok2) {
        $ok = 0;
        push @$err => @$err2;
    }

    die join "\n" => @$err unless $ok;
    return $txn;
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

sub _resolve_source {
    my $self = shift;
    my ($s) = @_;

    confess "Source name is required" unless defined $s && length $s;

    if (blessed($s)) {
        return $s if $s->DOES('DBIx::QuickORM::Role::SQLASource');
        croak "'$s' does not implement the 'DBIx::QuickORM::Role::SQLASource' role";
    }

    croak "Not sure how to get an sqla_source from '$s'" if ref($s);
    return $self->schema->table($s),
}

sub vivify {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    $self->pid_check;
    my ($data) = @_;

    return $self->{+MANAGER}->vivify(
        sqla_source => $sqla_source,
        connection => $self,
        fetched    => $data,
    );
}

sub insert {
    my $self        = shift;
    my $sqla_source = $self->_resolve_source(shift);
    $self->pid_check;
    my ($in) = @_;

    my ($data, $row);
    if (blessed($in)) {
        if ($in->isa('DBIx::QuickORM::Row')) {
            croak "Cannot insert a row that is already stored" if $in->{stored};
            $data = $in->{pending} // {};
            $row  = $in;
        }
        else {
            croak "Not sure how to insert '$in'";
        }
    }
    else {
        $data = $in;
    }

    croak "Refusing to insert an empty row" unless keys %$data;

    my $dialect = $self->dialect;
    my $ret     = $dialect->supports_returning_insert;

    for my $col ($sqla_source->columns) {
        my $def  = $col->perl_default or next;
        my $name = $col->name;

        $data->{$name} = $def->() unless exists $data->{$name};
    }

    my $orig_data = { %$data };
    $data = $self->format_insert_and_update_data($data);

    my $fetched;
    my $do_it = sub {
        my ($stmt, $bind) = $self->sqla->qorm_insert($sqla_source, $data, $ret ? {returning => $sqla_source->fields_to_fetch} : ());
        my $sth = $self->_make_sth($sqla_source, $stmt, $bind);
        $fetched = $sth->fetchrow_hashref if $ret;
    };

    if ($ret) {
        $do_it->();
    }
    else {
        my $pk_fields = $sqla_source->primary_key;
        if ($pk_fields && @$pk_fields) {
            croak "Auto-generated compound primary keys are not supported for databases that do not support 'returning on insert' functionality" if @$pk_fields > 1;

            $self->_internal_txn(sub {
                $do_it->();

                my $kv = $self->dbh->last_insert_id(undef, undef, $sqla_source->sqla_db_name);
                my $where = {$pk_fields->[0] => $kv};

                my $sth = $self->_execute_select($sqla_source, {where => $where, fields => $sqla_source->fields_to_fetch});
                $fetched = $sth->fetchrow_hashref;
            });
        }
        else {
            $do_it->();
            $fetched = $orig_data;
        }
    }

    return $self->{+MANAGER}->insert(
        sqla_source => $sqla_source,
        connection  => $self,
        fetched     => $fetched,
        row         => $row,
    );
}

sub _make_sth {
    my $self        = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($stmt, $bind) = @_;

    my $dialect   = $self->dialect;
    my $quote_bin = $dialect->quote_binary_data;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($stmt);
    for (my $i = 0; $i < @$bind; $i++) {
        my ($field, $val) = @{$bind->[$i]};

        my @args;
        if ($field) {
            my $affinity = $sqla_source->field_affinity($field, $dialect);

            if (blessed($val) && $val->DOES('DBIx::QuickORM::Role::Type')) {
                $val = $val->qorm_deflate($affinity);
            }
            elsif (my $type = $sqla_source->field_type($field)) {
                $val = $type->qorm_deflate($val, $affinity);
            }

            if ($quote_bin && $affinity eq 'binary') {
                @args = ($quote_bin);
            }
        }

        $sth->bind_param(1 + $i, $val, @args);
    }

    $sth->execute();

    return $sth;
}

{ no warnings 'once'; *search = \&select }

sub select {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    $self->pid_check;

    croak "Not enough arguments" unless @_;

    my %params;
    if (@_) {
        if (ref($_[0]) eq 'HASH') {
            $params{where}    = shift;
            $params{order_by} = shift;
            $params{limit}    = shift;

            croak "Too many parameters" if @_;
        }
        else {
            %params = @_;
        }
    }

    return DBIx::QuickORM::Select->new(%params, connection => $self, sqla_source => $sqla_source);
}

sub _execute_select {
    my $self        = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $query       = shift;

    $self->pid_check;

    my $dbh     = $self->dbh;
    my $dialect = $self->dialect;

    $self->normalize_query($sqla_source, $query, @_);

    my ($stmt, $bind) = $self->sqla->qorm_select($sqla_source, $query->{fields}, $query->{where}, $query->{order_by});
    if (my $limit = $query->{limit}) {
        $stmt .= " LIMIT ?";
        push @$bind => [undef, $limit];
    }

    return $self->_make_sth($sqla_source, $stmt, $bind);
}

sub normalize_query {
    my $self = shift;
    my ($sqla_source, $query, %mixin) = @_;

    unless ($query->{where}) {
        if (my $row = $query->{row}) {
            $query->{where} = $row->primary_key_hashref;
        }
        else {
            confess "It looks like a query hash was passed in, but neither the 'where' or 'row' fields are present:\n" . debug($query)
                if grep { exists $query->{$_} } qw/limit order_by fields omit/;

            my $where = { %$query };
            %$query = (where => $where);
        }
    }

    %$query = (%$query, %mixin);

    my $fields = $query->{fields} //= $sqla_source->fields_to_fetch;

    return $query unless ref($fields) eq 'ARRAY';

    my $pk_fields = $sqla_source->primary_key;

    my $omit = $query->{omit};
    if ($omit) {
        my $r = ref($omit);
        if    ($r eq 'HASH')  { }
        elsif ($r eq 'ARRAY') { $omit = map { ($_ => 1) } @$omit }
        elsif (!$r)           { $omit = {$omit => 1} }
        else                  { croak "$omit is not a valid 'omit' value" }

        if ($pk_fields) {
            for my $field (@$pk_fields) {
                next unless $omit->{$field};
                croak "Cannot omit primary key field '$field'";
            }
        }
    }

    if ($pk_fields || $omit) {
        my %seen;
        $fields = [grep { !$seen{$_}++ && !($omit && $omit->{$_}) } @{$pk_fields // []}, @$fields];
    }

    $query->{fields} = $fields;

    if ($omit) { $query->{omit} = $omit }
    else       { delete $query->{omit} }

    return $query;
}

sub count {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($query) = @_;

    $query->{fields} = 'COUNT(*) AS cnt';

    my $sth  = $self->_execute_select($query);
    my $data = $sth->fetchrow_hashref or return 0;
    return $data->{cnt};
}

sub delete {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($query) = @_;

    my $row;
    if (blessed($query) && $query->isa('DBIx::QuickORM::Row')) {
        $row = $query;
        $query = {
            row => $row,
            where => $row->primary_key_hashref,
        };
    }
    $row //= $query->{row};

    croak "delete() with a 'limit' clause is not currently supported"     if $query->{limit};
    croak "delete() with an 'order_by' clause is not currently supported" if $query->{order_by};

    $self->normalize_query($sqla_source, $query);

    my $dialect  = $self->dialect;
    my $do_cache = $self->{+MANAGER}->does_cache;
    my $ret      = $do_cache && $dialect->supports_returning_delete;

    my $pk_fields = $sqla_source->primary_key;

    my $deleted_keys;
    my $do_it = sub {
        my $where = shift // $query->{where};
        my ($stmt, $bind) = $self->sqla->qorm_delete($sqla_source, $where, $ret ? $pk_fields : ());
        my $sth = $self->_make_sth($sqla_source, $stmt, $bind);
        $deleted_keys = $sth->fetchall_arrayref({}) if $ret;
    };

    # If we are either not managing cache, or if we can use 'returning' then we
    # can do the easy way, no txn.
    if ($ret || !$do_cache || $row) {
        $do_it->();
        $deleted_keys //= [$row->primary_key_hashref] if $row;
    }
    else {
        $self->_internal_txn(sub {
            my $where;
            ($deleted_keys, $where) = $self->_get_keys($sqla_source, $query->{where});
            $do_it->($where);
        });
    }

    if ($do_cache && $deleted_keys && @$deleted_keys) {
        $self->{+MANAGER}->delete(%$query, sqla_source => $sqla_source, connection => $self, old_primary_key => $_) for @$deleted_keys;
    }

    return;
}

sub format_insert_and_update_data {
    my $self = shift;
    my ($data) = @_;

    $data = { map { $_ => {'-value' => $data->{$_}}} keys %$data };

    return $data;
}

sub update {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $query = shift;

    my ($changes, $row);

    if (blessed($query) && $query->isa('DBIx::QuickORM::Row')) {
        $row = $query;
        $query = {where => $row->primary_key_hashref};
    }

    while (@_) {
        my $r = ref($_[0]) or last;
        my $it = shift;
        if (blessed($it) && $it->isa('DBIx::QuickORM::Row')) {
            croak "Cannot provide more than 1 row" if $row;
            $row = $it;
        }
        elsif ($r eq 'HASH') {
            croak "Cannot provide multiple changes hashrefs" if $changes;
            $changes = $it;
        }
    }

    my %params = @_;
    if ($params{changes}) {
        croak "changes provided in multiple ways" if $changes;
        $changes = $params{changes};
    }

    if ($params{row}) {
        croak "row provided in multiple ways" if $row;
        $row = $params{row};
    }

    $changes //= $row->pending_data if $row;

    $self->normalize_query($sqla_source, $query);

    croak "update() with a 'limit' clause is not currently supported"     if $query->{limit};
    croak "update() with an 'order_by' clause is not currently supported" if $query->{order_by};
    croak "No changes for update"            unless $changes;
    croak "Changes must be a hashref"        unless ref($changes) eq 'HASH';
    croak "Changes hashref may not be empty" unless keys %$changes;

    my $pk_fields         = $sqla_source->primary_key;
    my $changes_pk_fields = grep { $changes->{$_} } @$pk_fields;

    my $dialect  = $self->dialect;
    my $do_cache = $self->{+MANAGER}->does_cache;
    my $ret      = $do_cache && $dialect->supports_returning_update;

    $changes = $self->format_insert_and_update_data($changes);

    # No cache, or not cachable, just do the update
    unless ($do_cache && $pk_fields && @$pk_fields) {
        my ($stmt, $bind) = $self->sqla->qorm_update($sqla_source, $changes, $query->{where});
        my $sth = $self->_make_sth($sqla_source, $stmt, $bind);

        return $sth->rows;
    }

    my $fields;
    my $updated;
    my $do_it = sub {
        my $where = shift // $query->{where};
        my ($stmt, $bind) = $self->sqla->qorm_update($sqla_source, $changes, $where, $ret ? {returning => $fields} : ());
        my $sth = $self->_make_sth($sqla_source, $stmt, $bind);
        $updated = $sth->fetchall_arrayref({}) if $ret;
    };

    # Simple case, updating a single row, or not updating any pks
    if ($row || !$changes_pk_fields) {
        my %seen;
        $fields = [grep { !$seen{$_}++ } @{$pk_fields // []}, keys %$changes];

        if ($ret) {
            $do_it->();
        }
        else {
            $self->_internal_txn(sub {
                my ($keys, $where) = $self->_get_keys($sqla_source, $query->{where});

                $do_it->($where);

                my ($stmt, $bind) = $self->sqla->qorm_select($sqla_source, $fields, $where);
                my $sth = $self->_make_sth($sqla_source, $stmt, $bind);
                $updated = $sth->fetchall_arrayref({});
            });
        }

        $self->{+MANAGER}->update(%$query, sqla_source => $sqla_source, connection => $self, fetched => $_) for @$updated;

        return scalar(@$updated);
    }

    # Not returning anything.
    $ret = 0;

    # Crap, we are changing pk's, possibly multiple, and no way to associate the before and after...
    my ($keys, $where);
    $self->_internal_txn(sub {
        ($keys, $where) = $self->_get_keys($sqla_source, $query->{where});
        $do_it->($where);
    });

    $self->{+MANAGER}->invalidate(%$query, old_primary_key => $_) for @$keys;

    return;
}

sub _get_keys {
    my $self = shift;
    my ($sqla_source, $where) = @_;

    my $pk_fields = $sqla_source->primary_key or croak "No primary key";

    my ($stmt, $bind) = $self->sqla->qorm_select($sqla_source, $pk_fields, $where);
    my $sth = $self->_make_sth($sqla_source, $stmt, $bind);
    my $keys = $sth->fetchall_arrayref({});
    $where = @$pk_fields > 1 ? {'-or' => $keys} : {$pk_fields->[0] => {'-in' => [map { $_->{$pk_fields->[0]} } @$keys]}};

    return ($keys, $where);
}

sub all {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $sth = $self->_execute_select($sqla_source, @_);

    my @out;
    while (my $fetched = $sth->fetchrow_hashref) {
        push @out => $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
    }

    return \@out;
}

sub data_all {
    my $self = shift;
    my $sth = $self->_execute_select(@_);
    return $sth->fetchall_arrayref({});
}

sub iterate {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($query, $cb) = @_;

    my $sth = $self->_execute_select($sqla_source, $query);

    while (my $fetched = $sth->fetchrow_hashref) {
        my $row = $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
        $cb->($row);
    }

    return;
}

sub data_iterate {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($query, $cb) = @_;

    my $sth = $self->_execute_select($sqla_source, $query);

    while (my $fetched = $sth->fetchrow_hashref) {
        $cb->($fetched);
    }

    return;
}

sub iterator {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $sth = $self->_execute_select($sqla_source, @_);

    return DBIx::QuickORM::Iterator->new(sub {
        my $fetched = $sth->fetchrow_hashref or return;
        return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
    });
}

sub data_iterator {
    my $self = shift;
    my $sth = $self->_execute_select(@_);

    return DBIx::QuickORM::Iterator->new(sub { $sth->fetchrow_hashref });
}

sub any {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $fetched = $self->data_any($sqla_source, @_);
    return unless $fetched;
    return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
}

sub data_any {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $query = shift;

    $self->normalize_query($sqla_source, $query, @_);
    $query = {%$query, order_by => undef, limit => 1};

    my $sth = $self->_execute_select(@_);
    return $sth->fetchrow_hashref;
}

sub first {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $fetched = $self->data_first($sqla_source, @_);
    return unless $fetched;
    return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
}

sub data_first {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $query = shift;

    $self->normalize_query($sqla_source, $query, @_);
    $query = {%$query, limit => 1};

    my $sth = $self->_execute_select($sqla_source, $query);
    return $sth->fetchrow_hashref;
}

sub one {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $fetched = $self->data_one($sqla_source, @_);
    return unless $fetched;
    return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
}

sub data_one {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $query = shift;

    $self->normalize_query($sqla_source, $query, @_);
    $query = {%$query, limit => 2};

    my $sth = $self->_execute_select($sqla_source, $query);
    my $fetched = $sth->fetchrow_hashref;
    croak "Expected only 1 row, but got more than one" if $sth->fetchrow_hashref;
    return $fetched;
}

sub find_or_insert {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($data) = @_;

    my $row;

    $self->_internal_txn(sub {
        my $sth = $self->_execute_select($sqla_source, {where => $data, limit => 2});

        if (my $fetched = $sth->fetchrow_hashref) {
            croak "Multiple existing rows match the specification passed to find_or_insert" if $sth->fetchrow_hashref;
            $row = $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
        }
        else {
            $row = $self->insert($sqla_source, $data);
        }
    });

    return $row;
}

1;
