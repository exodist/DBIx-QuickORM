package DBIx::QuickORM::Mixer;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::ORM;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <dbs
    <schemas
    <orms
};

use DBIx::QuickORM::Util::Has qw/Plugins Created/;

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};

    $self->{+DBS}     //= {};
    $self->{+SCHEMAS} //= {};
    $self->{+ORMS}    //= {};
}

sub schema {
    my $self = shift;
    my ($name) = @_;
    return $self->{+SCHEMAS}->{$name};
}

sub database {
    my $self = shift;
    my ($name) = @_;
    return $self->{+DBS}->{$name};
}

sub orm {
    my $self = shift;
    my $name = @_ % 2 ? shift : undef;
    my %params = @_;

    my $db_in     = delete $params{db};
    my $schema_in = delete $params{schema};

    my $db     = $db_in     ? blessed($db_in)     && $db_in->isa('DBIx::QuickORM::DB')         ? $db_in     : $self->{+DBS}->{$db_in}         // croak("This mixer does not have a database named '$db_in'")   : undef;
    my $schema = $schema_in ? blessed($schema_in) && $schema_in->isa('DBIx::QuickORM::Schema') ? $schema_in : $self->{+SCHEMAS}->{$schema_in} // croak("This mixer does not have a schema named '$schema_in'") : undef;

    my @caller = caller;

    return DBIx::QuickORM::ORM->new(db => $db, schema => $schema, created => "$caller[1] line $caller[2]")
        unless $name;

    if (my $got = $self->{+ORMS}->{$name}) {
        croak "ORM '$name' already exists, but has a different schema than the one requested"   if $schema && $got->schema != $schema;
        croak "ORM '$name' already exists, but has a different database than the one requested" if $db     && $got->db != $db;

        return $got;
    }

    return $self->{+ORMS}->{$name} = DBIx::QuickORM::ORM->new(name => $name, db => $db, schema => $schema, created => "$caller[1] line $caller[2]");
}

1;
