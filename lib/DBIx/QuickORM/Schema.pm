package DBIx::QuickORM::Schema;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util qw/merge_hash_of_objs/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    +tables
    <created
    <compiled
    <row_class
    <sql
};

sub init {
    my $self = shift;

    delete $self->{+NAME} unless defined $self->{+NAME};

    $self->{+ROW_CLASS} //= 'DBIx::QuickORM::Row';

    $self->_distribute_links(delete $self->{links}) if $self->{links};
}

sub tables       { values %{$_[0]->{+TABLES}} }
sub table        { $_[0]->{+TABLES}->{$_[1]} or croak "Table '$_[1]' is not defined" }
sub maybe_table  { return $_[0]->{+TABLES}->{$_[1]} // undef }

sub add_table {
    my $self = shift;
    my ($name, $table) = @_;

    croak "Table '$name' already defined" if $self->{+TABLES}->{$name};

    return $self->{+TABLES}->{$name} = $table;
}

sub merge {
    my $self = shift;
    my ($other, %params) = @_;

    $params{+TABLES}  //= merge_hash_of_objs($self->{+TABLES}, $other->{+TABLES}, \%params);
    $params{+NAME}    //= $self->{+NAME} if $self->{+NAME};

    return ref($self)->new(%$self, %params, __MERGE__ => 1);
}

sub clone {
    my $self   = shift;
    my %params = @_;

    $params{+TABLES}  //= {map { $_ => $self->{+TABLES}->{$_}->clone } keys %{$self->{+TABLES}}};
    $params{+NAME}    //= $self->{+NAME} if $self->{+NAME};

    return blessed($self)->new(%$self, %params, __CLONE__ => 1);
}

sub _distribute_links {
    my $self = shift;
    my ($links) = @_;

    for my $link (@$links) {
        my ($node_a, $node_b, $params) = @$link;

        my $debug = "link from $params->{caller}->[1] line $params->{caller}->[2]";

        my $tname_a = $node_a->{table};
        my $tname_b = $node_b->{table};

        my $table_a = $self->{+TABLES}->{$tname_a} or die "Could not find table '$tname_a' (Defined in $debug)\n";
        my $table_b = $self->{+TABLES}->{$tname_b} or die "Could not find table '$tname_b' (Defined in $debug)\n";

        if (my $acc = $node_a->{accessor}) {
            $table_a->{links}->{$acc} = $link;
        }

        if (my $acc = $node_b->{accessor}) {
            $table_b->{links}->{$acc} = [$node_b, $node_a, {%$params, type => scalar(reverse($params->{type}))}];
        }
    }

    return;
}

1;

__END__

