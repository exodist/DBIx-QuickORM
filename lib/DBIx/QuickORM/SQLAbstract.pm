package DBIx::QuickORM::SQLAbstract;
use strict;
use warnings;

our $VERSION = '0.000005';

use Scalar::Util qw/blessed/;
use parent 'SQL::Abstract';

sub insert {
    my $self = shift;
    my ($source, @args) = @_;

    my $source_name = $source;

    if (blessed($source)) {
        $source_name = $source->sqla_source;
        local $self->{sqla_source} = $source;
        return $self->SUPER::insert($source_name, @args);
    }

    return $self->SUPER::insert($source_name, @args);
}

sub update {
    my $self = shift;
    my ($source, @args) = @_;

    my $source_name = $source;

    if (blessed($source)) {
        $source_name = $source->sqla_source;
        local $self->{sqla_source} = $source;
        return $self->SUPER::update($source_name, @args);
    }

    return $self->SUPER::update($source_name, @args);
}

sub select {
    my $self = shift;
    my ($source, @args) = @_;

    my $source_name = $source;

    my @bind_names;
    local $self->{bind_names} = \@bind_names;

    my ($stmt, @bind);
    if (blessed($source)) {
        $source_name = $source->sqla_source;
        local $self->{sqla_source} = $source;
        ($stmt, @bind) = $self->SUPER::select($source_name, @args);
    }
    else {
        ($stmt, @bind) = $self->SUPER::select($source_name, @args);
    }

    return ($stmt, \@bind, \@bind_names);
}

sub where {
    my $self = shift;

    my @bind_names;
    local $self->{bind_names} = \@bind_names;

    my ($stmt, @bind) = $self->SUPER::where(@_);

    return ($stmt, \@bind, \@bind_names);
}

sub _render_bind {
    my $self = shift;
    my (undef, $bind) = @_;
    if (my $bn = $self->{bind_names}) {
        my $fn = $bind->[0];
        $fn = $self->{sqla_source}->column_orm_name($fn) if $self->{sqla_source};
        push @$bn => $fn;
    }
    return $self->SUPER::_render_bind(@_);
}

sub _render_ident {
    my ($self, undef, $ident) = @_;
    $ident->[0] = $self->{sqla_source}->column_db_name($ident->[0]) if $self->{sqla_source};
    return [$self->_quote($ident)];
}


1;
