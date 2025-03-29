package DBIx::QuickORM::Select;
use strict;
use warnings;
use feature qw/state/;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Iterator;

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::Handle';

use DBIx::QuickORM::Util::HashBase qw{
    <connection
    <sqla_source

    <where
    <order_by
    <limit
    <fields
    <field_renames

    +last_sth
};

sub init {
    my $self = shift;
    $self->DBIx::QuickORM::Role::Handle::init();

    unless ($self->{+FIELDS}) {
        $self->{+FIELDS}        = $self->{+SQLA_SOURCE}->sqla_fields;
        $self->{+FIELD_RENAMES} = $self->{+SQLA_SOURCE}->sqla_rename;
    }

    $self->{+WHERE} //= {};
    delete $self->{+LAST_STH};
}

sub clone {
    my $self   = shift;
    my %params = @_;

    my $class = blessed($self);

    $class->new(%$self, %params);
}

sub source {
    my $self = shift;

    require DBIx::QuickORM::Source;
    return DBIx::QuickORM::Source->new(
        CONNECTION()  => $self->{+CONNECTION},
        SQLA_SOURCE() => $self->{+SQLA_SOURCE},
    );
}

sub and {

}

sub or {

}

sub all { shift->iterator->list }

sub iterator {
    my $self = shift;

    my $sth = $self->_execute_select();

    return DBIx::QuickORM::Iterator->new(sub {
        my $data = $sth->fetchrow_hashref or return;
        return $self->build_row($data);
    });
}

sub iterate {
    my $self = shift;
    my ($cb) = @_;

    my $sth = $self->_execute_select();

    while (my $data = $sth->fetchrow_hashref) {
        my $row = $self->build_row($data);
        $cb->($row);
    }

    return;
}

sub any {
    my $self = shift;
    my $s    = $self->clone(order_by => undef, limit => 1);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;
    return $self->build_row($data);
}

sub count {
    my $self = shift;
    my $s    = $self->clone(order_by => undef, fields => 'COUNT(*) AS cnt');
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return 0;
    return $data->{cnt};
}

sub first {
    my $self = shift;
    my $s    = $self->clone(limit => 1);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;
    return $self->build_row($data);
}

sub one {
    my $self = shift;
    my $s    = $self->clone(limit => 2);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;
    croak "More than one matching row was found in the database" if $sth->fetchrow_hashref;
    return $self->build_row($data);
}

sub delete { }

sub update { }

sub _execute_select {
    my $self = shift;

    my $source = $self->{+SQLA_SOURCE}->sqla_source;
    my $fields = $self->{+FIELDS};
    my $rename = $self->{+FIELD_RENAMES};

    my ($stmt, $bind, $bind_names) = $self->sqla->select($source, @{$self}{FIELDS(), WHERE(), ORDER_BY()});
    if (my $limit = $self->limit) {
        $stmt .= " LIMIT ?";
        push @$bind => $limit;
    }

    my $sth = $self->dbh->prepare($stmt);
    $sth->execute(@$bind);

    state $warned = 0;
    warn "TODO rename fields" unless $warned++;

    return $self->{+LAST_STH} = $sth;
}

1;

__END__

1;
