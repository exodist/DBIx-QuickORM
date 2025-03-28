package DBIx::QuickORM::Connection;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <orm
    <dbh
    <dialect
    <pid

    <schema
};

sub db { $_[0]->{+ORM}->db }

sub init {
    my $self = shift;

    my $orm = $self->{+ORM} or croak "An orm is required";
    my $db = $orm->db;

    $self->{+PID} //= $$;

    $self->{+DBH} = $db->new_dbh;

    $self->{+DIALECT} = $db->dialect->new(dbh => $self->{+DBH}, db_name => $db->db_name);

    if ($orm->autofill) {
        my $schema = $self->{+DIALECT}->build_schema_from_db;

        if (my $schema2 = $orm->schema) {
            $self->{+SCHEMA} = $schema->merge($schema2);
        }
        else {
            $self->{+SCHEMA} = $schema;
        }
    }
    else {
        $self->{+SCHEMA} = $orm->schema->clone;
    }
}

1;
