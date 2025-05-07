package DBIx::QuickORM::Connection;
use strict;
use warnings;
use feature qw/state/;

our $VERSION = '0.000010';

use Carp qw/confess croak cluck/;
use List::Util qw/mesh/;
use Importer 'List::Util' => ('first' => { -as => 'lu_first' });
use Scalar::Util qw/blessed weaken/;
use DBIx::QuickORM::Util qw/load_class debug/;
use Cpanel::JSON::XS;

use POSIX();
use Scope::Guard();

use DBIx::QuickORM::Row::Async;
use DBIx::QuickORM::SQLAbstract;
use DBIx::QuickORM::Query;
use DBIx::QuickORM::Select;
use DBIx::QuickORM::Source;
use DBIx::QuickORM::Connection::Transaction;
use DBIx::QuickORM::Connection::Async;
use DBIx::QuickORM::Connection::Aside;
use DBIx::QuickORM::Connection::Fork;
use DBIx::QuickORM::Iterator;

use DBIx::QuickORM::Connection::RowData qw{
    STORED
    PENDING
    DESYNC
    TRANSACTION
    ROW_DATA
};

use DBIx::QuickORM::Role::Query ':ALL' => {-prefix => 'QUERY_'};
#    QUERY_SQLA_SOURCE
#    QUERY_WHERE
#    QUERY_ORDER_BY
#    QUERY_LIMIT
#    QUERY_FIELDS
#    QUERY_OMIT
#    QUERY_ASYNC
#    QUERY_ASIDE
#    QUERY_FORKED
#    QUERY_ROW

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
    <in_async
    <asides
    <forks
};

sub clear_async {
    my $self = shift;
    my ($async) = @_;

    croak "Not currently running an async query" unless $self->{+IN_ASYNC};

    croak "Mismatch, we are in an async query, but not the one we are trying to clear"
        unless $async == $self->{+IN_ASYNC};

    delete $self->{+IN_ASYNC};
}

sub clear_aside {
    my $self = shift;
    my ($aside) = @_;

    croak "Not currently running that aside query" unless $self->{+ASIDES}->{$aside};

    delete $self->{+ASIDES}->{$aside};
}

sub clear_fork {
    my $self = shift;
    my ($fork) = @_;

    croak "Not currently running that fork query" unless $self->{+FORKS}->{$fork};

    delete $self->{+FORKS}->{$fork};
}

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

    $self->{+ASIDES} = {};
    $self->{+FORKS}  = {};

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

#####################
# {{{ SANITY CHECKS #
#####################

sub pid_check {
    my $self = shift;
    confess "Connections cannot be used across multiple processes, you must reconnect post-fork" unless $$ == $self->{+PID};
    return 1;
}

sub async_check {
    my $self = shift;

    my $async = $self->{+IN_ASYNC} or return 1;
    confess "There is currently an async query running, it must be completed before you run another query" unless $async->done;
    delete $self->{+IN_ASYNC};
    return 1;
}

#####################
# }}} SANITY CHECKS #
#####################

########################
# {{{ SIMPLE ACCESSORS #
########################

sub db { $_[0]->{+ORM}->db }

sub sqla {
    my $self = shift;
    return $self->{+SQLA}->() if $self->{+SQLA};

    my $sqla = DBIx::QuickORM::SQLAbstract->new(bindtype => 'columns');

    $self->{+SQLA} = sub { $sqla };

    return $sqla;
}

########################
# }}} SIMPLE ACCESSORS #
########################

#####################
# {{{ STATE CHANGES #
#####################

sub reconnect {
    my $self = shift;

    my $dbh = delete $self->{+DBH};
    $dbh->{InactiveDestroy} = 1 unless $self->{+PID} == $$;
    $dbh->disconnect;

    $self->{+PID} = $$;
    $self->{+DBH} = $self->{+ORM}->db->new_dbh;
}

#####################
# }}} STATE CHANGES #
#####################

###########################
# {{{ TRANSACTION METHODS #
###########################

sub enable_internal_transactions  { $_[0]->{+INTERNAL_TRANSACTIONS} = 1 }
sub disable_internal_transactions { $_[0]->{+INTERNAL_TRANSACTIONS} = 0 }
sub internal_transactions_enabled { $_[0]->{+INTERNAL_TRANSACTIONS} ? 1 : 0 }

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
    $self->pid_check;

    my $txns = $self->{+TRANSACTIONS};

    my $cb = (@_ && ref($_[0]) eq 'CODE') ? shift : undef;
    my %params = @_;
    $cb //= $params{action};

    croak "Cannot start a transaction while there is an active async query" if $self->{+IN_ASYNC} && !$self->{+IN_ASYNC}->done;

    unless ($params{force}) {
        unless ($params{ignore_aside}) {
            my $count = grep { $_ && !$_->done } values %{$self->{+ASIDES} // {}};
            croak "Cannot start a transaction while there is an active aside query (unless you use ignore_aside => 1, or force => 1)" if $count;
        }

        unless ($params{ignore_forks}) {
            my $count = grep { $_ && !$_->done } values %{$self->{+FORKS} // {}};
            croak "Cannot start a transaction while there is an active forked query (unless you use ignore_forked => 1, or force => 1)" if $count;
        }
    }

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

    my ($root, $parent) = @$txns ? (@{$txns}[0,-1]) : ($txn, $txn);

    $parent->add_fail_callback($params{'on_parent_fail'})             if $params{on_parent_fail};
    $parent->add_success_callback($params{'on_parent_success'})       if $params{on_parent_success};
    $parent->add_completion_callback($params{'on_parent_completion'}) if $params{on_parent_completion};
    $root->add_fail_callback($params{'on_root_fail'})                 if $params{on_root_fail};
    $root->add_success_callback($params{'on_root_success'})           if $params{on_root_success};
    $root->add_completion_callback($params{'on_root_completion'})     if $params{on_root_completion};

    push @{$txns} => $txn;

    local $@;
    my $ok = eval {
        QORM_TRANSACTION: { $cb->($txn) };
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
    $self->pid_check;

    if (my $txns = $self->{+TRANSACTIONS}) {
        return $txns->[-1] if @$txns;
    }

    return undef;
}

sub auto_retry_txn {
    my $self = shift;
    $self->pid_check;
    $self->async_check;

    my $count;
    my %params;

    if (!@_) {
        croak "Not enough arguments";
    }
    elsif (@_ == 1 && ref($_[0]) eq 'CODE') {
        $count = 1;
        $params{action} = $_[0];
    }
    elsif (@_ == 2) {
        my $ref = ref($_[1]);
        if ($ref eq 'CODE') {
            $count = $_[0];
            $params{action} = $_[1];
        }
        elsif ($ref eq 'HASH') {
            $count  = $_[0];
            %params = %{$_[1]};
        }
        else {
            croak "Not sure what to do with second argument '$_[0]'";
        }
    }
    else {
        %params = @_;
        $count  = delete $params{count};
    }

    $count ||= 1;

    $self->auto_retry($count => sub { $self->txn(%params) });
}

###########################
# }}} TRANSACTION METHODS #
###########################

#######################
# {{{ UTILITY METHODS #
#######################

sub auto_retry {
    my $self  = shift;
    my $cb    = pop;
    my $count = shift || 1;
    $self->pid_check;
    $self->async_check;

    croak "Cannot use auto_retry inside a transaction" if $self->in_txn;

    my ($ok, $out);
    for (0 .. $count) {
        $ok = eval { $out = $cb->(); 1 };
        last if $ok;
        warn "Error encountered in auto-retry, will retry...\n Exception was: $@\n";
        $self->reconnect unless $self->{+DBH} && $self->{+DBH}->ping;
    }

    croak "auto_retry did not succeed (attempted " . ($count + 1) . " times)"
        unless $ok;

    return $out;
}

sub source {
    my $self = shift;
    $self->pid_check;
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

sub _resolve_source_and_query {
    my $self = shift;
    my ($source, $query, @extra) = @_;

    $source = $self->_resolve_source($source);
    $query  = $self->_resolve_query($query, $source);

    return ($source, $query, @extra);
}

sub _resolve_query {
    my $self = shift;
    my ($query, $sqla_source) = @_;

    return DBIx::QuickORM::Query->new(QUERY_WHERE() => {}, QUERY_SQLA_SOURCE() => $sqla_source)
        unless $query;

    if (blessed($query)) {
        return $query if $query->DOES('DBIx::QuickORM::Role::Query');

        return DBIx::QuickORM::Query->new(QUERY_WHERE() => $query->primary_key_hashref, QUERY_ROW() => $query, QUERY_SQLA_SOURCE() => $sqla_source)
            if $query->isa('DBIx::QuickORM::Row');
    }

    croak "'$query' is not a valid query" unless ref($query) eq 'HASH';

    if (lu_first { $query->{$_} } QUERY_WHERE(), QUERY_ORDER_BY(), QUERY_LIMIT(), QUERY_FIELDS(), QUERY_OMIT(), QUERY_ASYNC(), QUERY_ASIDE(), QUERY_FORKED(), QUERY_ROW()) {
        return DBIx::QuickORM::Query->new(%$query, QUERY_SQLA_SOURCE() => $sqla_source);
    }

    return DBIx::QuickORM::Query->new(QUERY_WHERE() => $query, QUERY_SQLA_SOURCE() => $sqla_source);
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
    return $self->schema->table($s),;
}

sub _make_sth {
    my $self        = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($stmt, $bind, $query, $prepare_args) = @_;

    $self->pid_check;
    $self->async_check;

    my $dialect   = $self->dialect;
    my $quote_bin = $dialect->quote_binary_data;

    my $dbh = $self->dbh;
    if ($query && ($query->{+QUERY_ASYNC} || $query->{+QUERY_ASIDE})) {
        croak "Dialect '" . $dialect->dialect_name . "' does not support async" unless $dialect->async_supported;
        $prepare_args //= {};
        %$prepare_args = (%$prepare_args, $dialect->async_prepare_args);

        $dbh = $self->{+ORM}->db->new_dbh if $query->{+QUERY_ASIDE};
    }

    my ($pid, $rh, $wh, $guard);
    if ($query && $query->{+QUERY_FORKED}) {
        pipe($rh, $wh) or die "Could not create pipe: $!";
        $pid = fork // die "Could not fork: $!";

        if ($pid) { # Parent
            close($wh);

            my $fork = DBIx::QuickORM::Connection::Fork->new(
                connection  => $self,
                sqla_source => $sqla_source,
                pid         => $pid,
                pipe        => $rh,
            );

            $self->{+FORKS}->{$fork} = $fork;
            weaken($self->{+FORKS}->{$fork});

            return $fork;
        }

        # Child
        $guard = Scope::Guard->new(sub {
            print STDERR "Escaped Scope in forked query";
            POSIX::_exit(255);
        });
        close($rh);

        $dbh = $self->{+ORM}->db->new_dbh;
    }

    my $sth = $dbh->prepare($stmt, $prepare_args);
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

    my $res = $sth->execute();

    return $sth unless $query && ($query->{+QUERY_ASYNC} || $query->{+QUERY_ASIDE} || $query->{+QUERY_FORKED});

    my $ready = 0;

    if ($query->{+QUERY_FORKED}) {
        my $json = Cpanel::JSON::XS->new->utf8(1)->convert_blessed(1)->allow_nonref(1);
        eval {
            print $wh $json->encode({result => $res}), "\n";
            while (my $row = $sth->fetchrow_hashref) {
                print $wh $json->encode($row), "\n";
            }
            close($wh);
            1;
        } or warn $@;
        $guard->dismiss();
        POSIX::_exit(0);
    }
    elsif ($query->{+QUERY_ASYNC}) {
        my $async = DBIx::QuickORM::Connection::Async->new(
            connection  => $self,
            sqla_source => $sqla_source,
            dbh         => $dbh,
            sth         => $sth,
        );

        $self->{+IN_ASYNC} = $async;
        weaken($self->{+IN_ASYNC});

        return $async;
    }
    elsif ($query->{+QUERY_ASIDE}) {
        my $aside = DBIx::QuickORM::Connection::Aside->new(
            connection  => $self,
            sqla_source => $sqla_source,
            dbh         => $dbh,
            sth         => $sth,
        );

        $self->{+ASIDES}->{$aside} = $aside;
        weaken($self->{+ASIDES}->{$aside});

        return $aside;
    }

    croak "This should not be reachable";
}

sub _execute_select {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    my ($prepare_args) = @extra;

    my $dbh     = $self->dbh;
    my $dialect = $self->dialect;

    my ($stmt, $bind) = $self->sqla->qorm_select($sqla_source, $query->{+QUERY_FIELDS}, $query->{+QUERY_WHERE}, $query->{+QUERY_ORDER_BY});
    if (my $limit = $query->{+QUERY_LIMIT}) {
        $stmt .= " LIMIT ?";
        push @$bind => [undef, $limit];
    }

    return $self->_make_sth($sqla_source, $stmt, $bind, $query, $prepare_args);
}

sub _format_insert_and_update_data {
    my $self = shift;
    my ($data) = @_;

    $data = { map { $_ => {'-value' => $data->{$_}} } keys %$data };

    return $data;
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

#######################
# }}} UTILITY METHODS #
#######################

##############################
# {{{ ROW/QUERY MANIPULATION #
##############################

{
    no warnings 'once';
    *search = \&select;
    *sync   = \&select;
}

sub async  { shift->select(@_)->async }
sub aside  { shift->select(@_)->aside }
sub forked { shift->select(@_)->forked }

sub vivify {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($data) = @_;
    $self->pid_check;

    return $self->{+MANAGER}->vivify(
        sqla_source => $sqla_source,
        connection => $self,
        fetched    => $data,
    );
}

sub insert {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($in) = @_;
    $self->pid_check;
    $self->async_check;

    my ($data, $row);
    if (blessed($in)) {
        if ($in->isa('DBIx::QuickORM::Row')) {
            croak "Cannot insert a row that is already stored" if $in->{stored};
            $data = $in->row_data->{+PENDING} // {};
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
    $data = $self->_format_insert_and_update_data($data);

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

sub update {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    $self->pid_check;
    $self->async_check;

    croak "update() cannot be used asynchronously" if $query->{+QUERY_ASYNC} || $query->{+QUERY_ASIDE} || $query->{+QUERY_FORKED};

    my $row = $query->{+QUERY_ROW};
    my $changes;
    while (@extra) {
        my $r = ref($extra[0]) or last;
        my $it = shift @extra;
        if (blessed($it) && $it->isa('DBIx::QuickORM::Row')) {
            croak "Cannot provide more than 1 row" if $row;
            $row = $it;
        }
        elsif ($r eq 'HASH') {
            croak "Cannot provide multiple changes hashrefs" if $changes;
            $changes = $it;
        }
    }

    my %params = @extra;
    if ($params{changes}) {
        croak "changes provided in multiple ways" if $changes;
        $changes = $params{changes};
    }

    if ($params{row}) {
        croak "row provided in multiple ways" if $row;
        $row = $params{row};
    }

    $changes //= $row->pending_data if $row;

    croak "update() with a 'limit' clause is not currently supported"     if $query->{+QUERY_LIMIT};
    croak "update() with an 'order_by' clause is not currently supported" if $query->{+QUERY_ORDER_BY};
    croak "No changes for update"            unless $changes;
    croak "Changes must be a hashref"        unless ref($changes) eq 'HASH';
    croak "Changes hashref may not be empty" unless keys %$changes;

    my $pk_fields         = $sqla_source->primary_key;
    my $changes_pk_fields = grep { $changes->{$_} } @$pk_fields;

    my $dialect  = $self->dialect;
    my $do_cache = $self->{+MANAGER}->does_cache;
    my $ret      = $do_cache && $dialect->supports_returning_update;

    $changes = $self->_format_insert_and_update_data($changes);

    # No cache, or not cachable, just do the update
    unless ($do_cache && $pk_fields && @$pk_fields) {
        my ($stmt, $bind) = $self->sqla->qorm_update($sqla_source, $changes, $query->{+QUERY_WHERE});
        my $sth = $self->_make_sth($sqla_source, $stmt, $bind, $query);

        return $sth->rows;
    }

    my $fields;
    my $updated;
    my $do_it = sub {
        my $where = shift // $query->{+QUERY_WHERE};
        my ($stmt, $bind) = $self->sqla->qorm_update($sqla_source, $changes, $where, $ret ? {returning => $fields} : ());
        my $sth = $self->_make_sth($sqla_source, $stmt, $bind, $query);
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
                my ($keys, $where) = $self->_get_keys($sqla_source, $query->{+QUERY_WHERE});

                $do_it->($where);

                my ($stmt, $bind) = $self->sqla->qorm_select($sqla_source, $fields, $where);
                my $sth = $self->_make_sth($sqla_source, $stmt, $bind, $query);
                $updated = $sth->fetchall_arrayref({});
            });
        }

        $self->{+MANAGER}->update($query->query_pairs, sqla_source => $sqla_source, connection => $self, fetched => $_) for @$updated;

        return scalar(@$updated);
    }

    # Not returning anything.
    $ret = 0;

    # Crap, we are changing pk's, possibly multiple, and no way to associate the before and after...
    my ($keys, $where);
    $self->_internal_txn(sub {
        ($keys, $where) = $self->_get_keys($sqla_source, $query->{+QUERY_WHERE});
        $do_it->($where);
    });

    $self->{+MANAGER}->invalidate($query->query_pairs, old_primary_key => $_) for @$keys;

    return;
}

sub delete {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    $query = $query->clone(@extra) if @extra;
    $self->pid_check;
    $self->async_check;

    croak "delete() cannot be used asynchronously" if $query->{+QUERY_ASYNC} || $query->{+QUERY_ASIDE} || $query->{+QUERY_FORKED};

    my $row = $query->{+QUERY_ROW};

    croak "delete() with a 'limit' clause is not currently supported"     if $query->{+QUERY_LIMIT};
    croak "delete() with an 'order_by' clause is not currently supported" if $query->{+QUERY_ORDER_BY};

    my $dialect  = $self->dialect;
    my $do_cache = $self->{+MANAGER}->does_cache;
    my $ret      = $do_cache && $dialect->supports_returning_delete;

    my $pk_fields = $sqla_source->primary_key;

    my $deleted_keys;
    my $do_it = sub {
        my $where = shift // $query->{+QUERY_WHERE};
        my ($stmt, $bind) = $self->sqla->qorm_delete($sqla_source, $where, $ret ? $pk_fields : ());
        my $sth = $self->_make_sth($sqla_source, $stmt, $bind, $query);
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
            ($deleted_keys, $where) = $self->_get_keys($sqla_source, $query->{+QUERY_WHERE});
            $do_it->($where);
        });
    }

    if ($do_cache && $deleted_keys && @$deleted_keys) {
        $self->{+MANAGER}->delete($query->query_pairs, sqla_source => $sqla_source, connection => $self, old_primary_key => $_) for @$deleted_keys;
    }

    return;
}

sub select {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    $self->pid_check;
    $self->async_check;

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

sub count {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    $query = $query->clone(@extra) if @extra;
    $self->pid_check;

    croak "count() cannot be used asynchronously" if $query->{+QUERY_ASYNC} || $query->{+QUERY_ASIDE} || $query->{+QUERY_FORKED};

    $query = $query->clone(QUERY_FIELDS() => 'COUNT(*) AS cnt');

    my $sth  = $self->_execute_select($sqla_source, $query);
    my $data = $sth->fetchrow_hashref or return 0;
    return $data->{cnt};
}

sub by_id {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my $id = shift;
    my %query = @_;

    my $where;
    my $ref = ref($id);
    #<<<
    if    ($ref eq 'HASH')  { $where = $id; $id = [ map { $where->{$_} } @{$sqla_source->primary_key} ] }
    elsif ($ref eq 'ARRAY') { $where = +{ mesh($sqla_source->primary_key, $id) } }
    elsif (!$ref)           { $id = [ $id ]; $where = +{ mesh($sqla_source->primary_key, $id) } }
    #>>>

    croak "Unrecognized primary key format: $id" unless ref($id) eq 'ARRAY';

    my $row = $self->{+MANAGER}->do_cache_lookup($sqla_source, undef, undef, $id);

    $query{+QUERY_WHERE} = $where;
    return $row //= $self->one($sqla_source, \%query);
}

sub by_ids {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);

    my @ids = @_;
    my (@out, %query);
    while (my $id = shift @ids) {
        if ($id =~ s/^-//) {
            $query{$id} = shift(@ids);
            next;
        }

        push @out => $self->by_id($sqla_source, $id, %query);
    }

    return \@out;
}

sub all {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    $query = $query->clone(@extra) if @extra;

    croak "all() cannot be used asynchronously, use iterate() to get an async iterator instead"
        if $query->{+QUERY_ASYNC} || $query->{+QUERY_ASIDE} || $query->{+QUERY_FORKED};

    my $sth = $self->_execute_select($sqla_source, $query);

    $self->pid_check;
    $self->async_check;

    return $sth->fetchall_arrayref({}) if $query->{+QUERY_DATA_ONLY};

    my @out;
    while (my $fetched = $sth->fetchrow_hashref) {
        push @out => $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
    }

    return @out;
}

sub iterate {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    my $cb = pop @extra;

    $query = $query->clone(@extra) if @extra;

    croak "iterate() cannot be used asynchronously" if $query->{+QUERY_ASYNC} || $query->{+QUERY_ASIDE} || $query->{+QUERY_FORKED};

    $self->pid_check;
    $self->async_check;

    my $sth = $self->_execute_select($sqla_source, $query);

    while (my $fetched = $sth->fetchrow_hashref) {
        my $arg;
        if ($query->{+QUERY_DATA_ONLY}) {
            $arg = $fetched
        }
        else {
            $arg = $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
        }
        $cb->($arg);
    }

    return;
}

sub iterator {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    $query = $query->clone(@extra) if @extra;

    $self->pid_check;
    $self->async_check;

    my $sth = $self->_execute_select($sqla_source, $query);

    my ($next, $ready);
    if ($sth->DOES('DBIx::QuickORM::Role::Async')) {
        $ready = sub { $sth->ready };
        $next  = sub {
            my $fetched = $sth->next or return;
            return $fetched if $query->{+QUERY_DATA_ONLY};
            return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
        };
    }
    else {
        $next = sub {
            my $fetched = $sth->fetchrow_hashref or return;
            return $fetched if $query->{+QUERY_DATA_ONLY};
            return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
        };
    }

    return DBIx::QuickORM::Iterator->new($next, $ready);
}

sub any {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    $query = $query->clone(@extra, QUERY_ORDER_BY() => undef, QUERY_LIMIT() => 1);

    $self->pid_check;

    my $sth = $self->_execute_select($sqla_source, $query);

    return DBIx::QuickORM::Row::Async->new(async => $sth) if $sth->DOES('DBIx::QuickORM::Role::Async');

    my $fetched = $sth->fetchrow_hashref;

    return unless $fetched;
    return $fetched if $query->{+QUERY_DATA_ONLY};
    return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
}

sub first {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    $query = $query->clone(@extra, QUERY_LIMIT() => 1);

    $self->pid_check;
    $self->async_check;

    my $sth = $self->_execute_select($sqla_source, $query);

    return DBIx::QuickORM::Row::Async->new(async => $sth) if $sth->DOES('DBIx::QuickORM::Role::Async');

    my $fetched = $sth->fetchrow_hashref;

    return unless $fetched;
    return $fetched if $query->{+QUERY_DATA_ONLY};
    return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
}

sub one {
    my $self = shift;
    my ($sqla_source, $query, @extra) = $self->_resolve_source_and_query(@_);
    $query = $query->clone(@extra) if @extra;

    $self->pid_check;
    $self->async_check;

    my $sth = $self->_execute_select($sqla_source, $query);

    if ($sth->DOES('DBIx::QuickORM::Role::Async')) {
        $sth->set_only_one(1);
        return DBIx::QuickORM::Row::Async->new(async => $sth);
    }

    my $fetched = $sth->fetchrow_hashref;
    croak "Expected only 1 row, but got more than one" if $sth->fetchrow_hashref;

    return unless $fetched;
    return $fetched if $query->{+QUERY_DATA_ONLY};
    return $self->{+MANAGER}->select(sqla_source => $sqla_source, connection => $self, fetched => $fetched);
}

sub find_or_insert {
    my $self = shift;
    my $sqla_source = $self->_resolve_source(shift);
    my ($data) = @_;
    $self->pid_check;
    $self->async_check;

    my $row;

    $self->_internal_txn(sub {
        my $sth = $self->_execute_select($sqla_source, {QUERY_WHERE() => $data, QUERY_LIMIT() => 2});

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

##############################
# }}} ROW/QUERY MANIPULATION #
##############################

1;
