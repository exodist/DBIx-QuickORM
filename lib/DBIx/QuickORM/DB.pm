package DBIx::QuickORM::DB;
use strict;
use warnings;

our $VERSION = '0.000005';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;

use DBIx::QuickORM::Util::HashBase qw{
    <name
    +connect
    <attributes
    <db_name
    +dsn
    <host
    <port
    <socket
    <user
    <pass
    <created
    <compiled
    <dialect
};

sub dbi_driver { confess "Not Implemented" }

sub dsn_socket_field { 'host' };

sub init {
    my $self = shift;

    croak "'dialect' is a required attribute" unless $self->{+DIALECT};

    delete $self->{+NAME} unless defined $self->{+NAME};

    $self->{+ATTRIBUTES} //= {};
    $self->{+ATTRIBUTES}->{RaiseError}          //= 1;
    $self->{+ATTRIBUTES}->{PrintError}          //= 1;
    $self->{+ATTRIBUTES}->{AutoCommit}          //= 1;
    $self->{+ATTRIBUTES}->{AutoInactiveDestroy} //= 1;

    croak "Cannot provide both a socket and a host" if $self->{+SOCKET} && $self->{+HOST};
}

sub driver_name {
    my $self_or_class = shift;
    my $class = blessed($self_or_class) || $self_or_class;
    $class =~ s/^DBIx::QuickORM::DB:://;
    return $class;
}

sub dsn {
    my $self = shift;
    return $self->{+DSN} if $self->{+DSN};

    my $driver = $self->dbi_driver;
    $driver =~ s/^DBD:://;

    my $db_name = $self->db_name;

    my $dsn = "dbi:${driver}:dbname=${db_name};";

    if (my $socket = $self->socket) {
        $dsn .= $self->dsn_socket_field . "=$socket";
    }
    elsif (my $host = $self->host) {
        $dsn .= "host=$host;";
        if (my $port = $self->port) {
            $dsn .= "port=$port;";
        }
    }
    else {
        croak "Cannot construct dsn without a host or socket";
    }

    return $self->{+DSN} = $dsn;
}

sub connect {
    my $self = shift;
    my (%params) = @_;

    my $attrs = $self->attributes;

    my $dbh;
    eval {
        if ($self->{+CONNECT}) {
            $dbh = $self->{+CONNECT}->();
        }
        else {
            require DBI;
            $dbh = DBI->connect($self->dsn, $self->user, $self->pass, $self->attributes);
        }

        1;
    } or confess $@;

    $dbh->{AutoInactiveDestroy} = 1 if $attrs->{AutoInactiveDestroy};

    return $dbh if $params{dbh_only};

    require DBIx::QuickORM::Connection;
    return DBIx::QuickORM::Connection->new(
        dbh => $dbh,
        db  => $self,
    );
}

1;
