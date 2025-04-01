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

sub hook {
    my $self = shift;
    my ($hook) = @_;

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
