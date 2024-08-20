package DBIx::QuickORM::DB;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/alias/;

use DBIx::QuickORM::Util::HashBase qw{
    +dbh
    +connect
    <attributes
    <db_name
    +dsn
    <host
    <name
    <pid
    <port
    <socket
    <txn_depth
    <user
    password
};

use DBIx::QuickORM::Util::Has qw/Plugins Created/;

sub dbi_driver { croak "$_[0]->dbi_driver() is not implemented" }

sub start_txn    { $_[0]->dbh->begin_work }
sub commit_txn   { $_[0]->dbh->commit }
sub rollback_txn { $_[0]->dbh->rollback }

sub create_savepoint   { $_[0]->dbh->do("SAVEPOINT $_[1]") }
sub commit_savepoint   { $_[0]->dbh->do("RELEASE SAVEPOINT $_[1]") }
sub rollback_savepoint { $_[0]->dbh->do("ROLLBACK TO SAVEPOINT $_[1]") }

sub init {
    my $self = shift;

    croak "${ \__PACKAGE__ } cannot be used directly, use a subclass" if blessed($self) eq __PACKAGE__;

    $self->{+PID}        //= $$;
    $self->{+ATTRIBUTES} //= {};

    $self->{+ATTRIBUTES}->{RaiseError}          //= 1;
    $self->{+ATTRIBUTES}->{PrintError}          //= 1;
    $self->{+ATTRIBUTES}->{AutoCommit}          //= 1;
    $self->{+ATTRIBUTES}->{AutoInactiveDestroy} //= 1;

    $self->{+TXN_DEPTH} = $self->{+ATTRIBUTES}->{AutoCommit} ? 0 : 1;

    croak "Cannot provide both a socket and a host" if $self->{+SOCKET} && $self->{+HOST};
}

sub dsn {
    my $self = shift;
    return $self->{+DSN} if $self->{+DSN};

    my $driver = $self->dbi_driver;
    my $db_name = $self->db_name;

    my $dsn = "dbi:${driver}:database=${db_name};";

    if (my $socket = $self->socket) {
        $dsn .= "host=$socket;";
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

sub dbh {
    my $self = shift;

    if ($$ != $self->{+PID}) {
        confess "Database connection was forked inside a transaction block"
            if $self->{+TXN_DEPTH};

        delete $self->{+DBH};
        $self->{+PID} = $$;
        $self->{+TXN_DEPTH} = 0;
    }

    return $self->{+DBH} //= $self->connect();
}

sub connect {
    my $self = shift;

    return $self->{+CONNECT}->() if $self->{+CONNECT};

    require DBI;
    my $dbh = DBI->connect($self->dsn, $self->username, $self->password, $self->attributes // {AutoInactiveDestroy => 1, AutoCommit => 1});

    return $dbh;
}

sub transaction {
    my $self = shift;
    my ($code) = @_;

    my $start_depth = $self->{+TXN_DEPTH};
    local $self->{+TXN_DEPTH} = $self->{+TXN_DEPTH} + 1;

    my $sp;
    if ($start_depth) {
        $sp = "SAVEPOINT" . $start_depth;
        $self->create_savepoint($sp);
    }
    else {
        $self->start_txn;
    }

    my ($ok, $out);
    $ok = eval { $out = $code->(); 1 };
    my $err = $@;

    if ($ok) {
        if   ($sp) { $self->commit_savepoint($sp) }
        else       { $self->commit_txn }
        return $out;
    }

    if   ($sp) { $self->rollback_savepoint($sp) }
    else       { $self->rollback_txn }

    die $err;
}

sub generate_schema {
    my $self = shift;
    require DBIx::QuickORM::Util::SchemaBuilder;
    return DBIx::QuickORM::Util::SchemaBuilder->generate($self);
}

1;
