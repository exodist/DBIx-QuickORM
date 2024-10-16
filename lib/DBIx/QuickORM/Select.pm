package DBIx::QuickORM::Select;
use strict;
use warnings;

use Carp qw/croak confess/;
use Sub::Util qw/set_subname/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/parse_hash_arg/;

use DBIx::QuickORM::Util::HashBase qw{
    <source
    <where
    <limit
    <order_by
    <prefetch
    +count
    +rows
    +index
    +params
};

sub init {
    my $self = shift;

    croak "'source' is a required attribute" unless $self->{+SOURCE};

    $self->{+INDEX} = 0;
}

sub reset   { shift->{+INDEX} = 0 }
sub discard { delete(shift->{+ROWS}); return }

BEGIN {
    for my $attr_const (WHERE(), LIMIT(), ORDER_BY(), PREFETCH()) {
        my $attr = "$attr_const";

        my $set_meth     = "set_$attr";
        my $clear_meth   = "clear_$attr";
        my $with_meth    = "with_$attr";
        my $without_meth = "without_$attr";

        my $set = sub {
            my $self = shift;

            if (@_) {
                ($self->{$attr}) = @_;
            }
            else {
                delete $self->{$attr};
            }

            delete $self->{+PARAMS};

            $self->reset;
            $self->discard;

            return $self;
        };

        my $clear = sub {
            my $self = shift;

            delete $self->{$attr};
            delete $self->{+PARAMS};

            $self->reset;
            $self->discard;

            return $self;
        };

        my $with = sub {
            my $self = shift;
            return $self->clone->$set_meth(@_) if @_;
            return $self->clone->$clear_meth();
        };

        my $without = sub { $_[0]->clone->$clear_meth };

        no strict 'refs';
        no warnings 'once';

        *$set_meth     = set_subname($set_meth     => $set);
        *$clear_meth   = set_subname($clear_meth   => $clear);
        *$with_meth    = set_subname($with_meth    => $with);
        *$without_meth = set_subname($without_meth => $without);
    }
}

sub params {
    my $self = shift;

    return $self->{+PARAMS} if $self->{+PARAMS};

    my %out = (
        WHERE() => $self->{+WHERE} // {},
    );

    $out{+LIMIT}    = $self->{+LIMIT}    if $self->{+LIMIT};
    $out{+ORDER_BY} = $self->{+ORDER_BY} if $self->{+ORDER_BY};
    $out{+PREFETCH} = $self->{+PREFETCH} if $self->{+PREFETCH};

    return $self->{+PARAMS} = \%out;
}

sub aggregate { confess "Not implemented" } # FIXME TODO
sub async     { confess "Not Implemented" } # FIXME TODO

sub find {
    my $self = shift;
    my $r = $self->_rows or return undef;
    return undef unless @$r;

    croak "Multiple rows returned for fetch/find operation" if @$r > 1;

    return $r->[0];
}

sub count {
    my $self = shift;

    if (my $rows = $self->{+ROWS}) {
        return scalar @$rows;
    }

    return $self->{+SOURCE}->count_select($self->params);
}

sub _rows {
    my $self = shift;
    return $self->{+ROWS} //= $self->{+SOURCE}->do_select($self->params);
}

sub all   { @{shift->_rows} }
sub any   { my $r = shift->_rows; return undef unless @$r; return $r->[0] }
sub first { my $r = shift->_rows; return undef unless @$r; return $r->[0] }
sub last  { my $r = shift->_rows; return undef unless @$r; return $r->[-1] }

sub next {
    my $self = shift;
    my $i = $self->{+INDEX}++;
    my $rows = $self->_rows;
    return if $i > @$rows;
    return $rows->[$i];
}

sub previous {
    my $self = shift;
    my $i = $self->{+INDEX}--;

    if ($i < 0) {
        $self->{+INDEX} = 0;
        return;
    }

    my $rows = $self->_rows;
    return if $i > @$rows;
    return $rows->[$i];
}

sub clone {
    my $self = shift;
    my %params = @_;

    my $class = blessed($self);

    return $class->new(
        SOURCE()   => $self->{+SOURCE},
        LIMIT()    => $self->{+LIMIT},
        ORDER_BY() => $self->{+ORDER_BY},
        PREFETCH() => $self->{+PREFETCH},
        WHERE()    => $self->{+WHERE},

        %params,
    );
}

sub _parse_boolean_args {
    my $self = shift;

    return parse_hash_arg(@_) unless @_ == 1 && blessed($_[0]) && $_[0]->isa(__PACKAGE__);
    return $_[0]->where;
}

sub _and {
    my $self = shift;
    my $where1 = $self->{+WHERE};
    my $where2 = $self->_parse_boolean_args(@_);

    return $self->clone(WHERE() => $where2) unless $where1;

    my $where = ['-and' => [$where1, $where2]];

    $self->clone(WHERE() => $where);
}

sub _or {
    my $self = shift;
    my $where1 = $self->{+WHERE};
    my $where2 = $self->_parse_boolean_args(@_);

    return $self->clone(WHERE() => $where2) unless $where1;

    my $where = ['-or' => [$where1, $where2]];

    $self->clone(WHERE() => $where);
}

# Do these last to avoid conflicts with the operators
{
    no warnings 'once';
    *and = \&_and;
    *or  = \&_or;
}

1;
