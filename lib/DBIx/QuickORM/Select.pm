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

    +where
    +order_by
    +limit
    +fields
    +omit

    +last_sth
};

sub init {
    my $self = shift;
    $self->DBIx::QuickORM::Role::Handle::init();

    $self->{+WHERE} //= {};
    delete $self->{+LAST_STH};
}

sub limit {
    my $self = shift;
    return $self->{+LIMIT} unless @_;
    return $self->clone(LIMIT() => $_[0]);
}

sub where {
    my $self = shift;
    return $self->{+WHERE} unless @_;
    return $self->clone(WHERE() => $_[0]);
}

sub order_by {
    my $self = shift;
    return $self->{+ORDER_BY} unless @_;
    return $self->clone(ORDER_BY() => $_[0]);
}

sub all_fields {
    my $self = shift;
    return $self->clone(FIELDS() => $self->{+SQLA_SOURCE}->db_fields_list_all);
}

sub fields {
    my $self = shift;
    return $self->{+FIELDS} unless @_;

    return $self->clone(FIELDS() => $_[0]) if @_ == 1 && ref($_[0]) eq 'ARRAY';

    my @fields = @{$self->{+FIELDS} // $self->{+SQLA_SOURCE}->db_fields_to_fetch};
    push @fields => @_;

    return $self->clone(FIELDS() => \@fields);
}

sub omit {
    my $self = shift;
    return $self->{+OMIT} unless @_;

    return $self->clone(OMIT() => $_[0]) if @_ == 1 && ref($_[0]) eq 'ARRAY';

    my @omit = @{$self->{+OMIT} // []};
    push @omit => @_;
    return $self->clone(OMIT() => \@omit)
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

sub all { shift->iterator(@_)->list }

sub iterator {
    my $self = shift;
    my %params = @_;

    my $sth = $self->_execute_select();

    return DBIx::QuickORM::Iterator->new(sub {
        my $data = $sth->fetchrow_hashref or return;
        return $self->sqla_source->fields_remap_db_to_orm($data) if $params{data_only};
        return $self->build_row($data);
    });
}

sub iterate {
    my $self = shift;
    my ($cb, %params);
    if (@_ == 1) {
        ($cb) = @_;
    }
    else {
        %params = @_;
        $cb = delete $params{cb};
    }

    croak "No callback provided" unless $cb;

    my $sth = $self->_execute_select();

    while (my $data = $sth->fetchrow_hashref) {
        if ($params{data_only}) {
            $self->sqla_source->fields_remap_db_to_orm($data);
            $cb->($data);
        }
        else {
            my $row = $self->build_row($data);
            $cb->($row);
        }
    }

    return;
}

sub any {
    my $self = shift;
    my %params = @_;

    my $s    = $self->clone(order_by => undef, limit => 1);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;

    return $self->sqla_source->fields_remap_db_to_orm($data) if $params{data_only};
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
    my %params = @_;

    my $s    = $self->clone(limit => 1);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;

    return $self->sqla_source->fields_remap_db_to_orm($data) if $params{data_only};
    return $self->build_row($data);
}

sub one {
    my $self = shift;
    my %params = @_;

    my $s    = $self->clone(limit => 2);
    my $sth  = $s->_execute_select();
    my $data = $sth->fetchrow_hashref or return;
    croak "More than one matching row was found in the database" if $sth->fetchrow_hashref;

    return $data if $params{no_remap} && $params{data_only};
    return $self->sqla_source->fields_remap_db_to_orm($data) if $params{data_only};

    return $self->build_row($data);
}

sub update {
    my $self = shift;
    my ($changes) = @_;

    croak "No changes for update" unless $changes;
    croak "Changes must be a hashref" unless ref($changes) eq 'HASH';

    my $source = $self->{+SQLA_SOURCE}->sqla_db_name;

    my ($stmt, @bind) = $self->sqla->update($source, $changes, $self->{+WHERE});
    my $sth = $self->dbh->prepare($stmt);
    $sth->execute(@bind);
    $self->{+LAST_STH} = $sth;

    state $warned = 0;
    warn "TODO update cache" unless $warned++;

    return;
}

sub _make_sth {
    my $self = shift;
    my ($stmt, $bind) = @_;

    my $sqla_source = $self->{+SQLA_SOURCE};
    my $dialect     = $self->dialect;
    my $quote_bin   = $dialect->quote_binary_data;
    my $dbh         = $dialect->dbh;

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

sub _execute_select {
    my $self = shift;

    my $sqla_source = $self->{+SQLA_SOURCE};
    my $fields      = $self->{+FIELDS} //= $self->{+SQLA_SOURCE}->db_fields_to_fetch;
    my $omit        = $self->{+OMIT};
    my $dialect     = $self->dialect;
    my $quote_bin   = $dialect->quote_binary_data;
    my $dbh         = $dialect->dbh;

    if ($omit) {
        my $r = ref($omit);
        if    ($r eq 'HASH')  { }
        elsif ($r eq 'ARRAY') { $omit = map { $_ => 1 } @$omit }
        elsif (!$r)           { $omit = { $omit => 1 } }
        else                  { croak "$omit is not a valid 'omit' value" }

        $fields = [grep { !$omit->{$_} } @$fields];
    }

    my ($stmt, $bind) = $self->sqla->qorm_select($sqla_source, $fields, $self->{+WHERE}, $self->{+ORDER_BY});
    if (my $limit = $self->limit) {
        $stmt .= " LIMIT ?";
        push @$bind => [undef, $limit];
    }

    my $sth = $self->_make_sth($stmt, $bind);

    return $self->{+LAST_STH} = $sth;
}

sub _and {
    my $self = shift;
    return $self->clone(WHERE() => {'-and' => [$self->{+WHERE}, @_]});
}

sub _or {
    my $self = shift;
    return $self->clone(WHERE() => {'-or' => [$self->{+WHERE}, @_]});
}

sub delete {
    my $self = shift;

    my ($stmt, @bind) = $self->sqla->delete($self->{+SQLA_SOURCE}, $self->{+WHERE});
    my $sth = $self->dbh->prepare($stmt);
    $sth->execute(@bind);
    $self->{+LAST_STH} = $sth;

    return;
}

# Do these last to avoid conflicts with the operators
{
    no warnings 'once';
    *and = \&_and;
    *or  = \&_or;
}

1;
