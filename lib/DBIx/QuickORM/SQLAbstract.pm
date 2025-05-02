package DBIx::QuickORM::SQLAbstract;
use strict;
use warnings;

our $VERSION = '0.000007';

use Scalar::Util qw/blessed/;
use parent 'SQL::Abstract';

for my $meth (qw/insert update select delete/) {
    my $code = sub {
        my $self = shift;
        my ($source, @args) = @_;


        my ($stmt, @bind);
        if (blessed($source)) {
            my $source_name = $source->sqla_db_name;
            ($stmt, @bind) = $self->$meth($source_name, @args);
        }
        else {
            ($stmt, @bind) = $self->$meth($source, @args);
        }

        return ($stmt, \@bind);
    };

    no strict 'refs';
    *{"qorm_$meth"} = $code;
}

#our $IN_TARGET = 0;
#sub _render_insert_clause_target {
#    my $self = shift;
#
#    local $IN_TARGET = 1;
#
#    $self->SUPER::_render_insert_clause_target(@_);
#}
#
#sub _render_ident {
#    my $self = shift;
#    my (undef, $ident) = @_;
#
#    unless ($IN_TARGET) {
#        if (my $s = $self->{sqla_source}) {
#            if (my $db_name = $s->field_db_name($ident->[0])) {
#                $ident->[0] = $db_name;
#            }
#        }
#    }
#
#    $self->SUPER::_render_ident(@_);
#}

# -value => HASH    should work, no need for this
#sub _expand_insert_value {
#    my ($self, $v) = @_;
#
#    my $k = $SQL::Abstract::Cur_Col_Meta;
#
#    if (my $s = $self->{sqla_source}) {
#        my $r = ref($v);
#        if ($r eq 'HASH' || $r eq 'ARRAY') {
#            if (my $type = $s->field_type($k)) {
#                return +{-bind => [$k, $v]};
#            }
#        }
#    }
#
#    return $self->SUPER::_expand_insert_value($v);
#}

1;
