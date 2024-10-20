package DBIx::QuickORM::Connection;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed weaken isweak/;
use DBIx::QuickORM::Util qw/alias/;

require DBIx::QuickORM::SQLAbstract;
require DBIx::QuickORM::Util::SchemaBuilder;

use DBIx::QuickORM::Util::HashBase qw{
    <db
    +dbh
    <pid
    <txn_depth
    <txn_id
    <column_type_cache
    <sqla
    +cache
    +cache_stack
    +async
    +side
    <created
};

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

sub commit_txn         { my $self = shift; $self->{+TXN_DEPTH} -= 1; $self->{+DB}->commit_txn($self->dbh, @_) }
sub rollback_txn       { my $self = shift; $self->{+TXN_DEPTH} -= 1; $self->{+DB}->rollback_txn($self->dbh, @_) }
sub create_savepoint   { my $self = shift; $self->{+TXN_DEPTH} += 1; $self->{+DB}->create_savepoint($self->dbh, @_) }
sub commit_savepoint   { my $self = shift; $self->{+TXN_DEPTH} -= 1; $self->{+DB}->commit_savepoint($self->dbh, @_) }
sub rollback_savepoint { my $self = shift; $self->{+TXN_DEPTH} -= 1; $self->{+DB}->rollback_savepoint($self->dbh, @_) }

sub load_schema_sql { my $self = shift; $self->{+DB}->load_schema_sql($self->dbh, @_) }

sub supports_uuid     { my $self = shift; $self->{+DB}->supports_uuid($self->dbh, @_) }
sub supports_json     { my $self = shift; $self->{+DB}->supports_json($self->dbh, @_) }
sub supports_datetime { my $self = shift; $self->{+DB}->supports_datetime($self->dbh, @_) }

sub supports_async  { my $self = shift; $self->{+DB}->supports_async($self->dbh, @_) }
sub async_query_arg { my $self = shift; $self->{+DB}->async_query_arg($self->dbh, @_) }
sub async_ready     { my $self = shift; $self->{+DB}->async_ready($self->dbh, @_) }
sub async_result    { my $self = shift; $self->{+DB}->async_result($self->dbh, @_) }
sub async_cancel    { my $self = shift; $self->{+DB}->async_cancel($self->dbh, @_) }

sub start_txn {
    my $self = shift;

    croak "Cannnot start a transaction while an async query is running"
        if $self->{+ASYNC};

    croak 'Cannnot start a transaction while side connections have active queries (use $sel->ignore_transactions() to bypass)'
        if $self->{+SIDE};

    $self->{+TXN_DEPTH} += 1;
    $self->{+DB}->start_txn($self->dbh, @_)
}

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

sub quote_binary_data { my $self = shift; $self->{+DB}->quote_binary_data($self->dbh, @_) }
sub dbi_driver        { my $self = shift; $self->{+DB}->dbi_driver($self->dbh, @_) }

sub in_transaction {
    my $self = shift;
    return 1 if $self->{+TXN_DEPTH};
    return 1 if $self->{+DB}->in_txn($self->dbh);
    return 0;
}

sub init {
    my $self = shift;

    croak "A database is required"        unless $self->{+DB};
    croak "A database handle is required" unless $self->{+DBH};

    $self->{+PID}  //= $$;
    $self->{+SQLA} //= DBIx::QuickORM::SQLAbstract->new();

    $self->{+COLUMN_TYPE_CACHE} //= {};

    $self->{+TXN_DEPTH} = $self->dbh->{AutoCommit} ? 0 : 1;
    $self->{+TXN_ID}    = 0;

    $self->{+CACHE} = {};
    $self->{+CACHE_STACK} = [];
}

sub dbh {
    my $self = shift;

    if ($$ != $self->{+PID}) {
        if ($self->{+DBH}) {
            confess "Forked while inside a transaction block"
                if $self->{+TXN_DEPTH};

            confess "Forked while inside a transaction"
                unless $self->in_transaction;
        }

        $self->{+DBH} = $self->db->connect(dbh_only => 1);
    }
    elsif (!($self->{+DBH}) || !($self->{+ASYNC} || eval { $self->{+DBH}->ping })) {
        croak "Lost database connection during transaction" if $self->in_transaction;
        warn "Lost db connection, reconnecting...\n";
        $self->{+DBH} = $self->db->connect(dbh_only => 1);
    }

    return $self->{+DBH};
}

my $TXN_ID = 1;
sub transaction {
    my $self = shift;
    my ($code) = @_;

    # Make sure this gets loaded/reset
    my $dbh = $self->dbh;

    my $start_depth = $self->{+TXN_DEPTH};
    local $self->{+TXN_DEPTH} = $self->{+TXN_DEPTH};

    my $sp;
    if ($start_depth) {
        $sp = "SAVEPOINT" . $start_depth;
        $self->create_savepoint($sp);
    }
    else {
        $self->start_txn;
    }

    local $self->{+TXN_ID} = $TXN_ID++;

    push @{$self->{+CACHE_STACK} //= []} => $self->{+CACHE};
    $self->{+CACHE} = {};

    my ($ok, $out);
    $ok = eval { $out = $code->(); 1 };
    my $err = $@;

    $self->{+CACHE} = pop @{$self->{+CACHE_STACK} //= []};

    if ($ok) {
        if   ($sp) { $self->commit_savepoint($sp) }
        else       { $self->commit_txn }
        return $out;
    }

    eval {
        if   ($sp) { $self->rollback_savepoint($sp) }
        else       { $self->rollback_txn }
        1;
    } or warn $@;

    die $err;
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

sub from_cache {
    my $self = shift;
    my ($source, $data) = @_;

    my $cache_key = $self->_cache_key($source, $data) or return undef;
    my $cache_ref = $self->_cache_ref($source, $cache_key);

    return undef unless $$cache_ref;

    return $$cache_ref;
}

sub cache_row {
    my $self = shift;
    my ($row) = @_;
    return $self->cache_source_row($row->source, $row);
}

sub cache_source_row {
    my $self = shift;
    my ($source, $row, %params) = @_;

    $params{weak} //= 1;

    my $cache_key = $self->_cache_key($source, $row) or return undef;
    my $cache_ref = $self->_cache_ref($source, $cache_key);

    $$cache_ref = $row;

    weaken(${$cache_ref}) if $params{weak};

    return $row;
}

sub clear_cache {
    my $self = shift;
    $self->remove_source_cache($_) for keys %{$self->{+CACHE}};
}

sub prune_cache {
    my $self = shift;
    $self->prune_source_cache($_) for keys %{$self->{+CACHE}};
}

sub uncache_source_row {
    my $self = shift;
    my ($source, $row) = @_;

    my $cache_key = $self->_cache_key($source, $row) or return undef;

    my ($ref, $key) = $self->_cache_ref($source, $cache_key, parent => 1);

    croak "Found wrong object in cache (${$ref}->{$key} vs $row)" unless $row eq ${$ref}->{$key};
    delete ${$ref}->{$key};

    $row->set_uncached();

    return $row;
}

sub prune_source_cache {
    my $self = shift;
    my ($source) = @_;

    my @sets = map { $_->{$source} ? ([$_, $source, $_->{$source}]) : ()} $self->{+CACHE}, @{$self->{+CACHE_STACK} // []};
    while (my $set = shift @sets) {
        my ($parent, $key, $item) = @$set;
        @$set = ();

        if (!$item) {
            delete $parent->{$key};    # Prune empty hash keys
        }
        elsif (blessed($item) && $item->isa('DBIx::QuickORM::Row')) {
            my $cnt = Internals::SvREFCNT(%$item);

            next if $cnt > 2;                                 # The cache copy, and the copy here
            next if $cnt == 1 && is_weak($parent->{$key});    # in cache weakly

            delete $parent->{$key};

            $item->set_uncached();
        }
        else {
            push @sets => map { [$item, $_, $item->{$_}] } grep { $item->{$_} } keys %$item;
        }
    }
}

sub remove_source_cache {
    my $self = shift;
    my ($source) = @_;

    delete $_->{$source} for $self->{+CACHE}, @{$self->{+CACHE_STACK} // []};
}

sub _cache_key {
    my $self = shift;
    my ($source, $data) = @_;

    my $table = $source->table;
    my $pk_fields = $table->primary_key;
    return unless $pk_fields && @$pk_fields;

    if (blessed($data) && $data->isa('DBIx::QuickORM::Row')) {
        return [ map { $data->column($_) // return } @$pk_fields ];
    }

    return [ map { $data->{$_} // return } @$pk_fields ];
}

sub _cache_ref {
    my $self = shift;
    my ($source, $keys, %params) = @_;

    my $cache = $self->{+CACHE};

    my ($prev, $key);
    my $ref;
    for my $ck ("$source", @$keys) {
        if ($ref) {
            ${$ref} //= {};
            $prev = $ref;
            $key  = $ck;
            $ref  = \(${$ref}->{$ck});
        }
        else {
            $prev = $ref;
            $key  = $ck;
            $ref  = \($cache->{$ck});
        }
    }

    return ($prev, $key) if $params{parent};

    return $ref;
}

1;
