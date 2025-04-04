package DBIx::QuickORM::SQLAbstract;
use strict;
use warnings;

our $VERSION = '0.000005';

use Scalar::Util qw/blessed/;
use parent 'SQL::Abstract';

sub sqla_source { $_[0]->{sqla_source} }

for my $meth (qw/insert update select delete/) {
    my $code = sub {
        my $self = shift;
        my ($source, @args) = @_;

        my $source_name = $source;

        my ($stmt, @bind);
        if (blessed($source)) {
            $source_name = $source->sqla_source;
            local $self->{sqla_source} = $source;
            ($stmt, @bind) = $self->$meth($source_name, @args);
        }
        else {
            ($stmt, @bind) = $self->$meth($source_name, @args);
        }

        return ($stmt, \@bind);
    };

    no strict 'refs';
    *{"qorm_$meth"} = $code;
}

our $IN_TARGET = 0;
sub _render_insert_clause_target {
    my $self = shift;

    local $IN_TARGET = 1;

    $self->SUPER::_render_insert_clause_target(@_);
}

sub _render_ident {
    my $self = shift;
    my (undef, $ident) = @_;

    unless ($IN_TARGET) {
        if (my $s = $self->{sqla_source}) {
            if (my $c = $s->column($ident->[0])) {
                $ident->[0] = $c->db_name;
            }
        }
    }

    $self->SUPER::_render_ident(@_);
}

sub _expand_insert_value {
    my ($self, $v) = @_;

    my $k = $SQL::Abstract::Cur_Col_Meta;

    if (my $s = $self->{sqla_source}) {
        if (my $c = $s->column($k)) {
            my $r = ref($v);
            if (!ref($c->type) && $r eq 'HASH' || $r eq 'ARRAY') {
                return +{-bind => [$k, $v]};
            }
        }
    }

    return $self->SUPER::_expand_insert_value($v);
}

1;
