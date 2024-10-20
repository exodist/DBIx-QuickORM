package DBIx::QuickORM::Role::HasORM;
use strict;
use warnings;

use Carp qw/croak/;
use DBIx::QuickORM::Util qw/alias/;

use Role::Tiny;

with DBIx::QuickORM::Role::HasTransactions;

requires qw{orm};

sub connection { my $orm = $_[0]->orm; $orm ? $orm->connection      : undef }
sub db         { my $orm = $_[0]->orm; $orm ? $orm->db              : undef }
sub dbh        { my $orm = $_[0]->orm; $orm ? $orm->connection->dbh : undef }
sub schema     { my $orm = $_[0]->orm; $orm ? $orm->schema          : undef }
sub reconnect  { my $orm = $_[0]->orm; $orm ? $orm->reconnect       : croak "orm object is missing" }

sub async_active { $_[0]->connection->async_started       ? 1 : 0 }
sub aside_active { $_[0]->connection->has_side_connection ? 1 : 0 }

sub busy { $_[0]->connection->busy }

alias start_transaction => 'start_txn';
alias transaction_do    => 'txn_do';
alias transactions      => 'txns';
sub start_transaction { shift->orm->start_transaction(@_) }
sub transaction_do    { shift->orm->transaction_do(@_) }
sub transactions      { shift->orm->transactions }

1;
