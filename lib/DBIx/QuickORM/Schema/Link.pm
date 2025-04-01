package DBIx::QuickORM::Schema::Link;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/column_key/;

use DBIx::QuickORM::Util::HashBase qw{
    <table
    <local_columns
    <other_columns
    <unique
    <key
    <aliases
    <created
    <compiled
};

sub init {
    my $self = shift;

    croak "'table' is a required attribute"  unless $self->{+TABLE};
    croak "'unique' is a required attribute" unless defined $self->{+UNIQUE};

    croak "'local_columns' is a required attribute" unless $self->{+LOCAL_COLUMNS};
    croak "'other_columns' is a required attribute" unless $self->{+OTHER_COLUMNS};

    croak "'local_columns' must be an arrayref with at least 1 element" unless ref($self->{+LOCAL_COLUMNS}) eq 'ARRAY' && @{$self->{+LOCAL_COLUMNS}} >= 1;
    croak "'other_columns' must be an arrayref with at least 1 element" unless ref($self->{+OTHER_COLUMNS}) eq 'ARRAY' && @{$self->{+OTHER_COLUMNS}} >= 1;

    $self->{+KEY} //= column_key(@{$self->{+LOCAL_COLUMNS}});

    $self->{+ALIASES} //= [];

    return;
}

sub merge {
    my $self = shift;
    my ($other) = @_;

    croak "Links do not have the same table ($self->{table} vs $other->{table})"
        unless $self->{+TABLE} eq $other->{+TABLE};

    croak "Links do not have the same columns ([$self->{key}] vs [$other->{key}])"
        unless $self->{+KEY} eq $other->{+KEY};

    my $new = {%$self, %$self};

    if ($new->{+CREATED}) {
        if ($other->{+CREATED}) {
            $new->{+CREATED} .= ", " . $other->{+CREATED}
                unless $new->{+CREATED} =~ m/\Q$other->{+CREATED}\E/;
        }
    }
    else {
        $new->{+CREATED} = $other->{+CREATED};
    }

    push @{$new->{+ALIASES}} => @{$other->{+ALIASES}};

    return bless($new, blessed($self));
}

sub clone {
    my $self   = shift;
    my %params = @_;

    $params{+LOCAL_COLUMNS} //= [@{$self->{+LOCAL_COLUMNS}}];
    $params{+OTHER_COLUMNS} //= [@{$self->{+OTHER_COLUMNS}}];
    $params{+UNIQUE}        //= [@{$self->{+UNIQUE}}];
    $params{+ALIASES}       //= [@{$self->{+ALIASES}}];
    $params{+KEY}           //= column_key(@{$params{+LOCAL_COLUMNS}});

    my $out = blessed($self)->new(%$self, %params);
    delete $out->{+COMPILED};
    delete $out->{+CREATED};

    return $out;
}

1;
