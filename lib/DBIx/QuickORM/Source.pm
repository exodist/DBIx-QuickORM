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

sub all      { shift->search(@_)->all() }
sub iterator { shift->search(@_)->iterator() }
sub iterate  { shift->search(@_)->iterate() }
sub any      { shift->search(@_)->any() }
sub count    { shift->search(@_)->count() }
sub first    { shift->search(@_)->first() }
sub one      { shift->search(@_)->one() }
sub delete   { shift->search(@_)->delete() }
sub update   { shift->search(@_)->update() }

{
    no warnings 'once';
    *select = \&search;
}
sub search {
    my $self = shift;
    my ($where, %params);

    $where  = shift if @_ && ref($_[0]) eq 'HASH';
    croak "Got a reference '$_[0]' expected a set of key/value pairs" if @_ && ref($_[0]);
    %params = @_;

    $where //= delete $params{where};

    my $limit  = delete $params{limit};
    my $fields = delete $params{fields};
    my $order  = delete $params{order_by};
    my $omit   = delete $params{omit};

    my @bad = keys %params;
    croak("Invalid search keys: " . join(', ' => map { "'$_'" } @bad) . ". (Did you forget to wrap your 'where' in a hashref?)") if @bad;

    require DBIx::QuickORM::Select;
    return DBIx::QuickORM::Select->new(
        CONNECTION()  => $self->{+CONNECTION},
        SQLA_SOURCE() => $self->{+SQLA_SOURCE},
        where         => $where,
        limit         => $limit,
        fields        => $fields,
        order_by      => $order,
        omit          => $omit,
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

sub _make_sth {
    my $self = shift;
    my ($stmt, $bind) = @_;

    my $sqla_source = $self->sqla_source;
    my $dialect     = $self->dialect;
    my $quote_bin   = $dialect->quote_binary_data;

    my $dbh = $self->dbh;
    my $sth = $dbh->prepare($stmt);
    for (my $i = 0; $i < @$bind; $i++) {
        my ($field, $val) = @{$bind->[$i]};

        my $col = $sqla_source->column($field) // $sqla_source->db_column($field);
        $field = $col->name;

        my $affinity = $sqla_source->column_affinity($field, $dialect);

        if (blessed($val) && $val->DOES('DBIx::QuickORM::Role::Type')) {
            $val = $val->qorm_deflate($affinity);
        }
        elsif (my $type = $sqla_source->column_type($field)) {
            $val = $type->qorm_deflate($val, $affinity);
        }

        my @args;
        if ($quote_bin && $affinity eq 'binary') {
            @args = ($quote_bin);
        }

        $sth->bind_param(1 + $i, $val, @args);
    }

    $sth->execute();

    return $sth;
}

sub _insert {
    my $self = shift;
    my ($data, $row) = @_;

    my $dialect     = $self->dialect;
    my $ret         = $dialect->supports_returning_insert;
    my $sqla_source = $self->sqla_source;

    for my $col ($sqla_source->columns) {
        my $def = $col->perl_default or next;
        my $name = $col->name;

        $data->{$name} = $def->() unless exists $data->{$name};
    }

    my ($stmt, $bind) = $self->sqla->qorm_insert($sqla_source, $data, $ret ? {returning => $sqla_source->sqla_fields} : ());

    my $sth = $self->_make_sth($stmt, $bind);

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
                my $kv = $self->dbh->last_insert_id(undef, undef, $sqla_source->sqla_source);
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

sub _deflate {
    my $self = shift;
    my ($data) = @_;

    my $sqla_source = $self->sqla_source;
    my $dialect     = $self->dialect;
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

        $out->{$field} = $val;
    }

    return $out;
}

sub update_row {
    my $self = shift;
    my ($row) = @_;

    my $data = $self->_deflate($row->pending_fields);

    my $ret = $self->dialect->supports_returning_update;

    my $sqla_source = $self->sqla_source;

    my $where = $row->primary_key_where;

    my ($stmt, $bind) = $self->sqla->qorm_update($sqla_source, $data, $where, $ret ? {returning => [keys %$data]} : ());

    my $sth = $self->_make_sth($stmt, $bind);

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

__END__

