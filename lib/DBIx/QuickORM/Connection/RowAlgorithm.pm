package DBIx::QuickORM::Connection::RowAlgorithm;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <cache
    +cachable
    <connection
    +dialect
    <no_desync
    +row
    +row_data
    <row_class
    <sqla_source
    <transaction
    +source_name
};

sub dialect     { $_[0]->{+DIALECT}     //= $_[0]->{+CONNECTION}->dialect }
sub source_name { $_[0]->{+SOURCE_NAME} //= $_[0]->{+SQLA_SOURCE}->orm_name }

sub init {
    my $self = shift;

    croak "'row_data' cannot be specified at construction" if $self->{+ROW_DATA};

    my $con = $self->{+CONNECTION} // croak "'connection' is required";
    $con = $con->() if ref($con) eq 'CODE';
    $self->{+CONNECTION} = $con;

    my $sqla_source = $self->{+SQLA_SOURCE} // croak "'sqla_source' is required";
    $sqla_source = $sqla_source->() if ref($sqla_source) eq 'CODE';
    $self->{+SQLA_SOURCE} = $sqla_source;

    my $row_class = $self->{+ROW_CLASS} //= $sqla_source->row_class // $con->schema->row_class // croak "No 'row_class' specified";
    $row_class = load_class($row_class) or confess $@;
    $self->{+ROW_CLASS} = $row_class;

    $self->{+TRANSACTION} //= $con->current_txn;
    $self->{+CACHE}       //= $con->cache;
}

sub vivify {
    my $self = shift;
    ($self->{+ROW_DATA}) = @_;

    confess "Cannot vivify row as a matching row already exist in cache"
        if $self->cached_row();

    my $row = $self->{+ROW} //= $self->create_row;

    $row->orm_set_pending($self->{+ROW_DATA});

    return $row;
}

sub inserted {
    my $self = shift;
    ($self->{+ROW_DATA}) = @_;

    my $row = $self->get_row;

    $row->orm_set_stored($self->{+ROW_DATA});
    $row->orm_clear_pending();
    $row->orm_set_insert_transaction($self->{+TRANSACTION}) if $self->{+TRANSACTION};
    $self->normalize_txns($row);

    $self->cache_row($row);
    return $row;
}

sub updated {
    my $self = shift;
    ($self->{+ROW_DATA}) = @_;

    my $row = $self->get_row;
    my $old = $row->orm_get_stored();
    my $old_pk = $old ? $self->get_pk($old) : undef;

    my $new = $old ? { %$old, %{$self->{+ROW_DATA}} } : $self->{+ROW_DATA};
    $row->orm_set_stored($new);
    $row->orm_clear_pending();

    $self->normalize_txns($row);
    $self->cache_row($row, $old_pk);
    return $row;
}

sub refreshed {
    my $self = shift;
    ($self->{+ROW_DATA}) = @_;

    my $row = $self->row();
    my $old = $row->orm_get_stored();
    my $old_pk = $old ? $self->get_pk($old) : undef; # Can this change in a refresh?

    my $pending = $self->{+NO_DESYNC} ? undef : $row->orm_get_pending;

    unless ($pending && keys %$pending) {
        $row->orm_set_stored($self->{+ROW_DATA});
        $self->normalize_txns($row);
        $self->cache_row($row, $old_pk);
        return $row;
    }

    my $new = $self->{+ROW_DATA};
    my $desync = $row->orm_get_desync // {};

    for my $field (keys %$new) {
        next if $self->compare_field($field, $old->{$field}, $new->{$field}); # No change
        push @{$desync->{$field} //= [$old->{$field}]} => $new->{$field};
        $old->{$field} = $new->{$field};
    }

    if (keys %$desync) {
        $row->orm_set_desync($desync);
    }
    else {
        $row->orm_clear_desync;
    }

    return $row;
}

sub deleted {
    my $self = shift;
    ($self->{+ROW_DATA}) = @_;

    my $row = $self->row();
    my $old = $row->orm_get_stored();
    my $old_pk = $old ? $self->get_pk($old) : undef; # Can this change in a refresh?

    $row->set_deleted_transaction($self->{+TRANSACTION}) if $self->{+TRANSACTION};
    $row->orm_clear_stored;
    $row->orm_clear_pending;
    $row->orm_clear_desync;

    $self->uncache($row, $old_pk);
    return $row;
}

sub row {
    my $self = shift;

    my $cached = $self->cached_row();
    my $passed = $self->{+ROW};

    confess "Operation attempted on a row ($passed) that does not match the one in cache ($cached)"
        if $cached && $passed && $cached != $passed;

    return $self->{+ROW} //= $cached // $self->create_row;
}

sub create_row {
    my $self = shift;
    $self->{+ROW_CLASS}->new(
        sqla_source => $self->{+SQLA_SOURCE},
        connection  => $self->{+CONNECTION},
    );
}

sub cached_row {
    my $self = shift;
    my $cache = $self->{+CACHE} or return;
    return unless $self->cachable;

    my $tcache = $cache->{$self->source_name} or return;

    my $cache_key = $self->cache_key($self->{+ROW_DATA}) or return;
    my $out = $tcache->{$cache_key} or return;
    return $out;
}

sub cache_row {
    my $self = shift;
    my ($row, $old_pk) = @_;
    my $cache = $self->{+CACHE} or return;
    return unless $self->cachable;

    my $tcache = $cache->{$self->source_name} //= {};

    my $new_key = $self->cache_key($row) or confess "Could not get cache key for row";
    my $old_key = $old_pk ? $self->cache_key($old_pk) : undef;

    delete $tcache->{$old_key} if $old_key;
    $tcache->{$new_key} = $row;
}

sub uncache {
    my $self = shift;
    my ($row, $pk) = @_;

    my $cache = $self->{+CACHE} or return;
    return undef unless $self->cachable;

    my $sname = $self->source_name;
    my $tcache = $cache->{$sname} or return;

    my @keys;
    push @keys => $self->cache_key($row) if $row;
    push @keys => $self->cache_key($pk)  if $pk;

    delete $tcache->{$_} for @keys;
    delete $cache->{$sname} unless keys %$tcache;

    return;
}

sub cache_key {
    my $self = shift;
    my ($in) = @_;

    my @vals;
    my $r = ref($in);
    if ($r eq 'ARRAY') {
        @vals = @$in;
    }
    else {
        my $pk_fields = $self->{+SQLA_SOURCE}->primary_key;

        if (blessed($in) && $in->DOES('DBIx::QuickORM::Role::Row')) {
            $in = $in->primary_key_where;
            $r = ref($in);
        }

        if ($r eq 'HASH') {
            return if grep { !exists($in->{$_}) } @$pk_fields;
            @vals = @{$in}{@$pk_fields};
        }
        else {
            croak "Not sure how to get cache key from '$in'"
        }
    }

    return join chr(31) => @vals;
}

sub get_pk {
    my $self = shift;
    my ($data) = @_;

    my $pk_fields = $self->{+SQLA_SOURCE}->primary_key or return;
    return unless @$pk_fields;
    return if grep { !exists($data->{$_}) } @$pk_fields;
    return [@{$data}{@$pk_fields}];
}

sub cachable { $_[0]->{+CACHABLE} //= $_[0]->{+SQLA_SOURCE}->cachable }

sub _compare_field {
    my $self = shift;
    my ($field, $a, $b) = @_;

    my $sqla_source = $self->{+SQLA_SOURCE};
    my $affinity    = $sqla_source->field_affinity($field, $self->dialect);
    my $type        = $sqla_source->field_type($field);

    my $ad = defined($a);
    my $bd = defined($b);
    return 0 if ($ad xor $bd);       # One is defined, one is not
    return 1 if (!$ad) && (!$bd);    # Neither is defined

    # true if different, false if same
    return !$type->qorm_compare($a, $b) if $type;

    # true if same, false if different
    return DBIx::QuickORM::Affinity::compare_affinity_values($affinity, $a, $b);
}

sub normalize_txns {
    my $self = shift;
    my ($row) = @_;

    my $txn = $self->{+TRANSACTION};

    my $last_txn = $row->last_transaction;

    # Nothing has changed
    return unless $txn || $last_txn;
    return if $txn && $last_txn && $last_txn == $txn;

    my $txns = $row->active_transactions;

    if ($txn) {
        confess "Attempt to update row using a completed transaction" if $txn->complete;

        # Always update these
        $row->set_last_transaction($txn);
        $txns->{$txn} //= [$txn, $row->primary_key_where];
    }
    else {
        $row->clear_last_transaction;
        $row->clear_active_transactions;
    }

    my @todo = sort { $b->id <=> $a->id } values %$txns;
    while (my $x = shift @todo) {
        my $res = $x->result // last; # No result, then it is still open
        delete $txns->{$x};

        my $remaining = scalar @todo;
        my $insert_txn = $row->insert_transaction;
        my $delete_txn = $row->delete_transaction;

        if ($res) {    # Commited
            if ($remaining && ($insert_txn || $delete_txn)) {
                my $y   = $todo[-1];
                my $yid = $y->id;

                $row->swap_insert_transaction($y) if $insert_txn && $insert_txn->id > $yid;
                $row->swap_delete_transaction($y) if $delete_txn && $delete_txn->id > $yid;
            }

            $row->commit_transaction($x, $remaining);

            next if $remaining;
            $row->clear_insert_transaction($remaining) if $insert_txn;
            $row->clear_delete_transaction($remaining) if $delete_txn;
        }
        else {         # Rolled back
            if ($insert_txn && $insert_txn->id >= $x->id) {
                $row->rollback_insert_transaction($x);
                $row->clear_insert_transaction($remaining);
            }

            if ($delete_txn && $delete_txn->id >= $x->id) {
                $row->rollback_delete_transaction($x);
                $row->clear_delete_transaction($remaining);
            }

            $row->rollback_transaction($x, $remaining);
        }
    }

    return scalar @todo;
}

1;
