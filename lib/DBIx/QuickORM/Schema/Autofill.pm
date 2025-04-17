package DBIx::QuickORM::Schema::Autofill;
use strict;
use warnings;

use List::Util qw/first/;

use DBIx::QuickORM::Util::HashBase qw{
    <types
    <affinities
    <hooks
    +skip
};

my %HOOKS = (
    column      => 1,
    columns     => 1,
    index       => 1,
    indexes     => 1,
    links       => 1,
    post_column => 1,
    post_table  => 1,
    pre_column  => 1,
    pre_table   => 1,
    primary_key => 1,
    table       => 1,
    unique_keys => 1,
);

sub is_valid_hook { $HOOKS{$_[-1]} ? 1 : 0 }

sub hook {
    my $self = shift;
    my ($hook, $args) = @_;
    $_->(%$args) for @{$self->{+HOOKS}->{$hook} // []};
}

sub skip {
    my $self = shift;

    my $from = $self->{+SKIP};
    while(my $arg = shift @_) {
        $from = $from->{$arg} or return 0;
    }
    return $from;
}

sub process_column {
    my $self = shift;
    my ($col) = @_;

    my $type = $col->{type};
    my $tref = ref($type);
    return unless $tref && $tref eq 'SCALAR';

    my $new_type;
    $new_type = $self->{+TYPES}->{$$type} // $self->{+TYPES}->{uc($$type)} // $self->{+TYPES}->{lc($$type)};

    unless ($new_type) {
        if (my $aff = $col->{affinity}) {
            if (my $list = $self->{+AFFINITIES}->{$aff}) {
                for my $cb (@$list) {
                    $new_type = $cb->(%$col) and last;
                }
            }
        }
    }

    return unless $new_type;

    $col->{type} = $new_type;
    $col->{affinity} = $new_type->qorm_affinity(sql_type => $$type);
}

1;

__END__


