package DBIx::QuickORM::Table::Column;
use strict;
use warnings;

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::HashBase qw{
    <name
    primary_key
    unique
    inflate
    sql_type
    sql_default
    sql_serial
    nullable
    on_delete
};

sub fill {
    my $self = shift;
    my (%params) = @_;

    my $name   = $self->{+NAME};
    my $schema = $params{schema} or croak "'schema' is a required argument";
    my $table  = $params{table}  or croak "'table' is a required argument";

    my $from_db = $params{from_db} // $schema->db->get_table($table)->column($name) or croak "Table '$table' does not appear to have a '$name' column";

    # All fields are a string or boolean
    for my $k (keys %$from_db) {
        if (exists $self->{$k}) {
            # Neither is defined
            next if !defined($self->{$k}) && !defined($from_db->{$k});

            # if sql_type is a ref then it is variable, so use whatever the DB gives us
            if ($k eq 'sql_type' && ref($self->{$k})) {
                $self->{$k} = $from_db->{$k};
                next;
            }

            my $bad = 0;
            $bad ||= !defined($self->{$k});
            $bad ||= !defined($from_db->{$k});
            $bad ||= "$self->{$k}" ne "$from_db->{$k}";
            next unless $bad;

            confess "Field '$k' mismatch '$self->{$k}' vs '$from_db->{$k}' when compiling table '$table' column '$name'";
        }
        else {
            $self->{$k} = $from_db->{$k};
        }
    }
}

sub recompile {
    my $self = shift;
    $self->{+UNIQUE} = 1 if $self->{+PRIMARY_KEY};
}

sub clone {
    my $self = shift;
    return blessed($self)->new(%$self);
}

1;
