package DBIx::QuickORM::SQLBuilder::SQLAbstract;
use strict;
use warnings;

our $VERSION = '0.000011';

use Carp qw/croak/;
use Sub::Util qw/set_subname/;
use Scalar::Util qw/blessed/;
use parent 'SQL::Abstract';

use Role::Tiny::With qw/with/;
with 'DBIx::QuickORM::Role::SQLBuilder';

sub new {
    my $class = shift;
    return $class->SUPER::new(bindtype => 'columns', @_);
}

BEGIN {
    for my $meth (qw/insert update select delete where/) {
        my $arg_meth = "_${meth}_args";
        my $new_meth = "qorm_${meth}";

        my $code = sub {
            my $self   = shift;
            my %params = @_;

            my $source = delete $params{source} or croak "No source provided";

            my @args = $self->$arg_meth(\%params);

            my ($stmt, @bind);
            if (blessed($source)) {
                croak "'$source' does not implement the 'DBIx::QuickORM::Role::Source' role" unless $source->DOES('DBIx::QuickORM::Role::Source');
                my $moniker = $source->source_db_moniker;
                ($stmt, @bind) = $self->$meth($moniker, @args);
            }
            else {
                ($stmt, @bind) = $self->$meth($source, @args);
            }

            my $param = 1;
            @bind = map { my ($f, $v) = @{$_}; +{param => $param++, value => $v, type => 'field', field => $f} } @bind;

            if (my $limit = $params{limit}) {
                $stmt .= " LIMIT ?";
                push @bind => {param => $param++, value => $limit, type => 'limit'};
            }

            return {statement => $stmt, bind => \@bind, source => $source};
        };

        no strict 'refs';
        *$new_meth = set_subname $new_meth => $code;
    }
}

sub _insert_args { ($_[1]->{values} // croak "'values' is required", $_[1]->{options}) }
sub _update_args { ($_[1]->{values} // croak "'values' is required", $_[1]->{where} // undef, $_[1]->{options}) }
sub _select_args { ($_[1]->{fields} // croak "'fields' is required", $_[1]->{where} // croak "'where' is required", $_[1]->{order}) }
sub _delete_args { ($_[1]->{where}  // undef, $_[1]->{options}) }
sub _where_args  { ($_[1]->{where}  // croak "'where' is required", $_[1]->{order}) }

sub qorm_where_for_row {
    my $self = shift;
    my ($row) = @_;
    return $row->primary_key_hashref;
}

sub qorm_and {
    my $self = shift;
    my ($a, $b) = @_;
    return +{'-and' => [$a, $b]}
}

sub qorm_or {
    my $self = shift;
    my ($a, $b) = @_;
    return +{'-or' => [$a, $b]}
}

1;

__END__

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
        if (my $s = $self->{query_source}) {
            if (my $db_name = $s->field_db_name($ident->[0])) {
                $ident->[0] = $db_name;
            }
        }
    }

    $self->SUPER::_render_ident(@_);
}

 -value => HASH    should work, no need for this
sub _expand_insert_value {
    my ($self, $v) = @_;

    my $k = $SQL::Abstract::Cur_Col_Meta;

    if (my $s = $self->{query_source}) {
        my $r = ref($v);
        if ($r eq 'HASH' || $r eq 'ARRAY') {
            if (my $type = $s->field_type($k)) {
                return +{-bind => [$k, $v]};
            }
        }
    }

    return $self->SUPER::_expand_insert_value($v);
}
