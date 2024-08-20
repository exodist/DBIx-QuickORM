package DBIx::QuickORM::ORM;
use strict;
use warnings;

use Carp qw/confess croak/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    <db
    <schema
    <sources
    <autofill
    +include
};

use DBIx::QuickORM::Util::Has qw/Plugins Created/;

sub init {
    my $self = shift;

    croak "'name' is a required attribute" unless $self->{+NAME};

    my $db = $self->{+DB} or croak "'db' is a required attribute";

    $self->{+SOURCES}  //= {};
    $self->{+AUTOFILL} //= 1;

    if (my $schema = $self->{+SCHEMA}) {
        $self->{+SCHEMA} = $schema->merge($db->generate_schema)
            if $self->{+AUTOFILL};
    }
    elsif($self->{+AUTOFILL}) {
        $self->{+SCHEMA} = $db->generate_schema;
    }
    else {
        croak "You must either provide the 'schema' attribute or enable 'autofill'";
    }

    warn "fixme: handle includes";
}

sub source {
    my $self = shift;
    my ($name) = @_;
}

sub temp_table {
    my $self = shift;
    my ($name, @select) = @_;
}

sub temp_view {
    my $self = shift;
    my ($name, @select) = @_;
}

1;
