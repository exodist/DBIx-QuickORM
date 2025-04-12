package DBIx::QuickORM::RowManager;
use strict;
use warnings;

use Carp qw/confess/;
use DBIx::QuickORM::Util qw/load_class/;

use DBIx::QuickORM::Affinity();

use DBIx::QuickORM::Util::HashBase;

sub does_cache { 0 }
sub does_txn   { 0 }

sub cache   { }
sub uncache { }

sub fix_row_post_txn { }

sub touch_row_txn { }

sub cache_lookup {
    my $self = shift;
    return $self->do_lookup($self->parse_params({@_}));
}

sub do_cache_lookup {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;
    return undef;
}

sub invalidate {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_});

    # Remove from passed in row if we got one
    $row->{invalid} = 1 if $row;

    # Now check cache for row, might be same, might not
    $row = $self->uncache($sqla_source, $row, $old_pk, $new_pk);
    $row->{invalid} = 1 if $row;

    return;
}

sub _vivify {
    my $self = shift;
    my ($connection, $sqla_source, %params) = @_;
    my $row_class = load_class($sqla_source->row_class // $connection->schema->row_class // 'DBIx::QuickORM::Row') or die $@;
    return $row_class->new(connection => $connection, sqla_source => $sqla_source, %params);
}

sub vivify {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_}, row => 1);
    return $self->_vivify($connection, $sqla_source, pending => $fetched);
}

sub insert {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_}, row => 1);

    $row = $self->do_insert($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row);
    $self->touch_row_txn($connection => $row, insert => 1);
    $self->cache($sqla_source, $row, $old_pk, $new_pk);

    return $row;
}

sub do_insert {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;

    $row->{stored} = $fetched if $row;

    return $row // $self->_vivify($connection, $sqla_source, stored => $fetched);
}

sub update {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_});

    $row = $self->do_update($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row);
    $self->touch_row_txn($connection => $row, update => 1);
    $self->cache($sqla_source, $row, $old_pk, $new_pk);

    return $row;
}

sub do_update {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;

    return $self->_vivify($connection, $sqla_source, stored => $fetched)
        unless $row;

    $self->sync($row, $fetched, $connection, $sqla_source);

    return $row;
}

sub delete {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_}, fetched => 1);

    $row = $self->do_delete($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row);
    $self->touch_row_txn($connection => $row, delete => 1);
    $self->uncache($sqla_source, $row, $old_pk, $new_pk);

    return $row;
}

sub do_delete {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;

    return unless $row;

    $row->{pending} = { %{delete $row->{stored} // {}}, %{$row->{pending} // {}}, %{$fetched // {}} };
    delete $row->{desync};

    return $row;
}

sub select {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = $self->parse_params({@_});

    $row = $self->do_select($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row);
    $self->touch_row_txn($connection => $row, select => 1);
    $self->cache($sqla_source, $row, $old_pk, $new_pk);

    return $row;
}

sub do_select {
    my $self = shift;
    my ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row) = @_;

    # No existing row, make a new one
    return $self->_vivify($connection, $sqla_source, stored => $fetched)
        unless $row;

    $self->sync($row, $fetched, $connection, $sqla_source);

    return $row;
}

sub sync {
    my $self = shift;
    my ($row, $fetched, $connection, $sqla_source) = @_;

    my $stored  = $row->{stored};
    my $pending = $row->{pending};
    my $desync  = $row->{desync};

    return $row->{stored} = $fetched unless $stored || $pending || $desync;

    $stored  //= {};
    $pending //= {};
    $desync  //= {};

    for my $field (keys %$fetched) {
        # No change?
        next if $self->compare_field($sqla_source, $connection, $field, $stored->{$field}, $fetched->{$field});

        $stored->{$field} = $fetched->{$field};
        if ($pending->{$field} && !$self->compare_field($sqla_source, $connection, $field, $pending->{$field}, $fetched->{$field})) {
            $desync->{$field} = 1;
        }
        else {
            delete $pending->{$field};
            delete $desync->{$field};
        }
    }

    $row->{stored} = $stored;

    if (keys %$pending) { $row->{pending} = $pending }
    else                { delete $row->{pending} }

    if (keys %$desync) { $row->{desync} = $desync }
    else               { delete $row->{desync} }
}

sub compare_field {
    my $self = shift;
    my ($sqla_source, $connection, $field, $a, $b) = @_;

    my $affinity = $sqla_source->field_affinity($field, $connection->dialect);
    my $type     = $sqla_source->field_type($field);

    my $ad = defined($a);
    my $bd = defined($b);
    return 0 if ($ad xor $bd);       # One is defined, one is not
    return 1 if (!$ad) && (!$bd);    # Neither is defined

    # true if different, false if same
    return !$type->qorm_compare($a, $b) if $type;

    # true if same, false if different
    return DBIx::QuickORM::Affinity::compare_affinity_values($affinity, $a, $b);
}

sub parse_params {
    my $self = shift;
    my ($params, %skip) = @_;

    my $sqla_source = $params->{sqla_source} or confess "'source' is a required parameter";
    my $connection  = $params->{connection}  or confess "'connection' is a required parameter";
    confess "'$sqla_source' is not a valid SQLA Source" unless $sqla_source->DOES('DBIx::QuickORM::Role::SQLASource');
    confess "'$connection' is not a valid connection"   unless $connection->isa('DBIx::QuickORM::Connection');

    my $new_pk = $params->{new_primary_key};

    my $fetched = $params->{fetched};
    unless ($skip{fetched}) {
        my @pk_vals;
        confess "'fetched' is a required parameter" unless $fetched;
        confess "'$fetched' is not a valid fetched data set" unless ref($fetched) eq 'HASH';
        if (my $pk_fields = $sqla_source->primary_key) {
            my @bad;
            for my $field (@$pk_fields) {
                if (exists $fetched->{$field}) {
                    push @pk_vals => $fetched->{$field};
                }
                else {
                    push @bad => $field;
                }
            }

            confess "The following primary key fields are missing from the fetched data: " . join(', ' => sort @bad) if @bad;

            $new_pk //= \@pk_vals;
        }
    }

    my $old_pk = $params->{old_primary_key};

    my $row;
    unless ($skip{row}) {
        if ($row = $params->{row}) {
            confess "'$row' is not a valid row"     unless $row->isa('DBIx::QuickORM::Row');
            confess "Row has incorrect sqla_source" unless $row->{sqla_source} == $sqla_source;
            confess "Row has incorrect connection"  unless $row->{connection} == $connection;
            $old_pk //= $row->primary_key_values;
        }

        my $cached = $self->do_cache_lookup($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row);

        confess "Cached row does not match operating row" if $cached && $row && $cached != $row;
        $row //= $cached;
    }

    return ($connection, $sqla_source, $fetched, $old_pk, $new_pk, $row);
}

1;
