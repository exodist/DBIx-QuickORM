package DBIx::QuickORM::DB;
use strict;
use warnings;

use Carp qw/confess croak/;

use DBIx::QuickORM::Util qw/alias mod2file/;

use DBIx::QuickORM::HashBase qw{
    name
    username
    password
    attributes
    hostname
    port
    <type
    <dbd
    +dsn
    +connect
    +dbh
    <txn_depth
    <pid
    <compiled
};

alias txn_depth => 'transaction_depth';

sub init {
    my $self = shift;
    $self->{+PID} //= $$;
    $self->{+ATTRIBUTES} //= {};
    $self->{+TXN_DEPTH} = 0;
}

sub recompile { die "FIXME" }
sub build_dsn { die "FIXME" }

sub transaction { shift->txn(@_) }

sub get_table          { croak "$_[0]->get_table() is not implemented" }
sub get_tables         { croak "$_[0]->get_tables() is not implemented" }
sub start_txn          { croak "$_[0]->start_txn() is not implemented" }
sub commit_txn         { croak "$_[0]->commit_txn() is not implemented" }
sub rollback_txn       { croak "$_[0]->start_txn() is not implemented" }
sub create_savepoint   { croak "$_[0]->create_savepoint() is not implemented" }
sub commit_savepoint   { croak "$_[0]->commit_savepoint() is not implemented" }
sub rollback_savepoint { croak "$_[0]->rollback_savepoint() is not implemented" }

sub default_dbd { }

sub set_dsn { $_[0]->{+DSN} = $_[1] }

sub dsn {
    my $self = shift;
    return $self->{+DSN} //= $self->build_dsn;
}

my %DBD_TO_TYPE = (
    'DBD::Pg'      => 'DBIx::QuickORM::DB::PostgreSQL',
    'DBD::mysql'   => 'DBIx::QuickORM::DB::MySQL',
    'DBD::MariaDB' => 'DBIx::QuickORM::DB::MariaDB',
    'DBD::SQLite'  => 'DBIx::QuickORM::DB::SQLite',
);

sub set_dbd {
    my $self = shift;
    my ($driver) = @_;

    $driver = "DBD::$driver" unless $driver =~ m/:/;
    eval { require(mod2file($driver)); 1 } or croak "Could not load database driver '$driver': $@";

    $self->{+DBD} = $driver;

    $self->set_type($DBD_TO_TYPE{$driver}) if $DBD_TO_TYPE{$driver} && !$self->{+TYPE};

    return $driver;
}

sub set_type {
    my $self = shift;
    my ($type) = @_;

    $type = 'PostgreSQL' if $type eq 'Pg';
    $type = "DBIx::QuickORM::DB::$type" unless $type =~ m/:/;
    eval { require(mod2file($type)); 1 } or croak "Could not load database type '$type': $@";

    croak "'$type' does not subclass 'DBIx::QuickORM::DB'" unless $type->isa('DBIx::QuickORM::DB');

    $self->{+TYPE} = $type;

    # Upgrade
    bless($self, $type);

    $self->set_dbd($self->default_dbd) if $type->default_dbd && !$self->{+DBD};

    return $type;
}

sub set_connect {
    my $self = shift;
    my ($code) = @_;
    $self->{+CONNECT} = $code;
}

sub connect {
    my $self = shift;

    if ($$ != $self->{+PID}) {
        delete $self->{+DBH};
        $self->{+PID} = $$;
    }

    return $self->{+DBH} //= $self->_connect();
}

sub _connect {
    my $self = shift;

    return $self->{+CONNECT}->() if $self->{+CONNECT};

    require DBI;
    return DBI->connect($self->dsn, $self->username, $self->password, $self->attributes // {});
}

sub txn {
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

1;
