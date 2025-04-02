package DBIx::QuickORM::Source;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::Handle';

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <sqla_source
};

# sub init comes from DBIx::QuickORM::Role::Handle

sub all      { shift->search->all(@_) }
sub iterator { shift->search->iterator(@_) }
sub iterate  { shift->search->iterate(@_) }
sub any      { shift->search->any(@_) }
sub count    { shift->search->count(@_) }
sub first    { shift->search->first(@_) }
sub one      { shift->search->one(@_) }
sub delete   { shift->search->delete(@_) }
sub update   { shift->search->update(@_) }

*select = \&search;
sub search {
    my $self = shift;
    my ($where, $order_by, $limit) = @_;

    require DBIx::QuickORM::Select;
    return DBIx::QuickORM::Select->new(
        CONNECTION()  => $self->{+CONNECTION},
        SQLA_SOURCE() => $self->{+SQLA_SOURCE},
        where         => $where,
        order_by      => $order_by,
        limit         => $limit,
    );
}

sub insert {
    my $self = shift;
    my $data;

    if    (@_ > 1) { $data = {@_} }
    elsif (@_)     { $data = $_[0] }
    else           { croak "Not enough arguments" }

    croak "Refusing to insert an empty row" unless keys %$data;
    if (blessed($data)) {
        croak "Refusing to insert a blessed row, use insert_row() instead" if $data->isa('DBIx::QuickORM::Row');
        croak "Refusing to insert a blessed reference ($data)";
    }

    return $self->_insert($data);
}

sub _deflate {
    my $self = shift;
    my ($data) = @_;

    my $sqla_source = $self->sqla_source;
    my $dialect     = $self->dialect;
    my $quote_bin   = $dialect->quote_binary_data;
    my $dbh         = $dialect->dbh;

    my $out = {};

    for my $field (keys %$data) {
        my $val = $data->{$field};

        my $affinity = $sqla_source->column_affinity($field, $dialect);

        if (blessed($val) && $val->DOES('DBIx::QuickORM::Role::Type'))  {
            $val = $val->qorm_deflate($affinity);
        }
        elsif(my $type = $sqla_source->column_type($field)) {
            $val = $type->qorm_deflate($val, $affinity);
        }

        if ($quote_bin && $affinity eq 'binary') {
            $val = \($dbh->quote($val, $quote_bin));
        }

        $out->{$field} = $val;
    }

    return $out;
}

sub _insert {
    my $self = shift;
    my ($data, $row) = @_;

    my $ret = $self->dialect->supports_returning_insert;

    my $sqla_source = $self->sqla_source;

    $data = $self->_deflate($data);

    my ($stmt, @bind) = $self->sqla->insert($sqla_source, $data, $ret ? {returning => [$sqla_source->column_db_names]} : ());

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    if ($ret) {
        $data = $sth->fetchrow_hashref;
    }
    else {
        my $pk_fields = $sqla_source->primary_key;

        if ($pk_fields && @$pk_fields) {
            my $where;
            if (@$pk_fields > 1) {
                $where = {map { my $v = $data->{$_} or croak "Auto-generated compound primary keys are not supported for databses that do not support 'returning' functionality"; ($_ => $v) } @$pk_fields};
            }
            else {
                my $kv = $dbh->last_insert_id(undef, undef, $sqla_source->sqla_source);
                $where = {$pk_fields->[0] => $kv};
            }

            $data = $self->search($where)->one(data_only => 1, no_remap => 1);
        }
    }

    return $self->build_row($data, $row);
}

sub insert_row {
    my $self = shift;
    my ($row) = @_;

    my $data = $row->fields();
    $self->_insert($data, $row);
}

sub update_row {
    my $self = shift;
    my ($row) = @_;

    my $data = $row->pending_fields;
    $data = $self->_deflate($data);

    my $ret = $self->dialect->supports_returning_update;

    my $sqla_source = $self->sqla_source;

    my $where = $row->primary_key_where;

    my ($stmt, @bind) = $self->sqla->update($sqla_source, $data, $where, $ret ? {returning => [keys %$data]} : ());

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($stmt);
    $sth->execute(@bind);

    $data = $sth->fetchrow_hashref if $ret;

    return $self->build_row($data, $row);
}

sub refresh_row {
    my $self = shift;
    my ($row) = @_;

    my $data = $self->select($row->primary_key_where)->one(data_only => 1, no_remap => 1);

    return $self->build_row($data, $row, no_desync => 0);
}

# TODO These should enforce a transaction
sub find_or_insert   { }
sub update_or_insert { }

1;
