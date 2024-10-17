package DBIx::QuickORM::Role::HasORM;
use strict;
use warnings;

use Carp qw/croak/;

use Role::Tiny;

requires qw{orm};

sub connection { my $orm = $_[0]->orm; $orm ? $orm->connection      : undef }
sub db         { my $orm = $_[0]->orm; $orm ? $orm->db              : undef }
sub dbh        { my $orm = $_[0]->orm; $orm ? $orm->connection->dbh : undef }
sub schema     { my $orm = $_[0]->orm; $orm ? $orm->schema          : undef }
sub reconnect  { my $orm = $_[0]->orm; $orm ? $orm->reconnect       : croak "orm object is missing" }

sub async_active       { $_[0]->orm->connection->async_started       ? 1 : 0 }
sub aside_active       { $_[0]->orm->connection->has_side_connection ? 1 : 0 }
sub transaction_active { $_[0]->orm->connection->in_transaction      ? 1 : 0 }

sub busy { $_[0]->connection->busy }

sub transaction {
    my $self = shift;
    $self->orm->connection->transaction(@_);
}

1;
