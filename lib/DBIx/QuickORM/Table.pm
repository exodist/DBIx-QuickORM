package DBIx::QuickORM::Table;
use strict;
use warnings;

use Carp qw/croak/;
use Storable qw/dclone/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <columns
    <is_view
    <is_temp
};

use DBIx::QuickORM::Util::Has qw/Plugins Created SQLSpec/;

sub init {
    my $self = shift;

    croak "The 'name' attribute is required" unless $self->{+NAME};

    my $cols = $self->{+COLUMNS} or croak "The 'columns' attribute is required";
    croak "The 'columns' attribute must be a hashref" unless ref($cols) eq 'HASH';
    croak "The 'columns' hash may not be empty" unless keys %$cols;

    for my $cname (sort keys %$cols) {
        my $cval = $cols->{$cname} or croak "Column '$cname' is empty";
        croak "Columns '$cname' is not an instance of 'DBIx::QuickORM::Table::Column', got: '$cval'" unless blessed($cval) && $cval->isa('DBIx::QuickORM::Table::Column');
    }

    $self->{+IS_VIEW} //= 0;
    $self->{+IS_TEMP} //= 0;
}

sub column {
    my $self = shift;
    my ($cname) = @_;

    return $self->{+COLUMNS}->{$cname} // undef;
}

sub clone {
    my $self   = shift;
    my %params = @_;

    my $class = blessed($self);

    unless ($self->{+CREATED}) {
        my @caller = caller(1);
        $self->{+CREATED} = "$caller[1] line $caller[2]";
    }

    my $new = $class->new(
        %$self,
        columns  => dclone($self->{+COLUMNS}),
        sql_spec => dclone($self->{+SQL_SPEC}),
        %params,
    );
}

1;
