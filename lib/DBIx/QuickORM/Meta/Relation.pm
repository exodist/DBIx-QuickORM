package DBIx::QuickORM::Meta::Relation;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::HashBase qw{
    <name
    <members
    +index
    <compiled
};

sub clone {
    my $self = shift;
    return blessed($self)->new(
        name  => $self->{+NAME},
        index => $self->{+INDEX},
        members => [ map { my $m = { %{$_} }; delete $m->{has_one}; delete $m->{has_many}; $m } @{$self->{+MEMBERS}} ],
    );
}

sub init {
    my $self = shift;

    croak "A name is required" unless $self->{+NAME};

    $self->{+MEMBERS} //= [];

    croak "A relationship cannot have more than 2 members" if @{$self->{+MEMBERS}} > 2;
}

sub from {
    my $self = shift;
    my ($table) = @_;

    my $ms = $self->{+MEMBERS};

    my ($m1, $m2) = sort { $a->{table} eq $table ? -1 : $b->{table} eq $table ? 1 : 0 } @$ms, @$ms;

    return ($m1->{columns}, $m1->{has_many}, $m2->{table}, $m2->{columns});
}

sub add_member {
    my $self = shift;
    my (%params) = @_;

    croak "A relationship cannot have more than 2 members" if @{$self->{+MEMBERS}} >= 2;

    croak "Each member must have a table"           unless $params{table};
    croak "Each member must have 1 or more columns" unless $params{columns};

    $params{name} //= $self->{+NAME};

    if (@{$self->{+MEMBERS}}) {
        my ($other) = @{$self->{+MEMBERS}};
        croak "All members must have the same number of columns" unless @{$other->{columns}} == @{$params{columns}};
    }

    push @{$self->{+MEMBERS}} => \%params;

    delete $self->{+INDEX};
}

sub index {
    my $self = shift;
    return $self->{+INDEX} //= join " " => map { "$_->{table}(" . join(',' => @{$_->{columns}} ) . ")" } sort { $a->{table} cmp $b->{table} } @{$self->{+MEMBERS}};
}

sub recompile {
    my $self = shift;
    my %params = @_;

    my $schema = $params{schema} or croak "'schema' is a required argument";

    my $name = $self->{+NAME};

    croak "Relationship '$name' has no members" unless @{$self->{+MEMBERS}};

    # Allow for a relationship with only 1 member.
    my $a = $self->{+MEMBERS}->[0];
    my $b = $self->{+MEMBERS}->[-1];

    my $atab_n = $a->{table};
    my $btab_n = $b->{table};

    my $atab = $schema->meta_table($atab_n) or confess "Database has no '$atab_n' table (compiling relation '$name')";
    my $btab = $schema->meta_table($btab_n) or confess "Database has no '$btab_n' table (compiling relation '$name')";

    my $acols = $a->{columns};
    my $bcols = $b->{columns};

    for (my $i = 0; $i < @$acols; $i++) {
        my $acol_n = $acols->[$i];
        my $bcol_n = $bcols->[$i];

        my $acol = $atab->column($acol_n) or confess "Table '$atab_n' has no '$acol_n' column (compiling relation '$name')";
        my $bcol = $btab->column($bcol_n) or confess "Table '$btab_n' has no '$bcol_n' column (compiling relation '$name')";

        my $atype = $acol->sql_type;
        my $btype = $bcol->sql_type;

        confess "Table '$atab_n' column '$acol_n' has type '$atype' vs Table '$btab_n' column '$bcol_n' which has type '$btype' (compiling relation '$name')"
            unless $atype eq $btype;
    }

    my %seen;
    for my $set ([$atab, $acols, $b], [$btab, $bcols, $a]) {
        my ($tab, $cols, $member) = @$set;
        next if $seen{$member}++;

        if ($tab->is_unique(@$cols)) {
            $member->{has_one}  = 1;
            $member->{has_many} = 0;
        }
        else {
            $member->{has_one}  = 0;
            $member->{has_many} = 1;
        }
    }

    $self->{+COMPILED} = 1;

    return $self->index;
}

1;
