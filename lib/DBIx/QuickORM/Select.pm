package DBIx::QuickORM::Select;
use strict;
use warnings;

use Carp qw/croak/;

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
    croak "'where' is a required attribute" unless $self->{+WHERE};

    $self->{+INDEX} = 0;
}

sub reset   { shift->{+INDEX} = 0 }
sub discard { delete(shift->{+ROWS}); return }

sub params {
    my $self = shift;

    return $self->{+PARAMS} if $self->{+PARAMS};

    my %out = (
        WHERE() => $self->{+WHERE},
    );

    $out{+LIMIT}    = $self->{+LIMIT}    if $self->{+LIMIT};
    $out{+ORDER_BY} = $self->{+ORDER_BY} if $self->{+ORDER_BY};
    $out{+PREFETCH} = $self->{+PREFETCH} if $self->{+PREFETCH};

    return $self->{+PARAMS} = \%out;
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

1;
