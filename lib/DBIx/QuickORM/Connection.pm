package DBIx::QuickORM::Connection;
use strict;
use warnings;

use Carp qw/confess croak/;
use Scalar::Util qw/blessed/;
use DBIx::QuickORM::Util qw/alias/;

require SQL::Abstract;
require DBIx::QuickORM::Util::SchemaBuilder;

use DBIx::QuickORM::Util::HashBase qw{
    <db
    +dbh
    <pid
    <txn_depth
    <column_type_cache
    <sqla
};

use DBIx::QuickORM::Util::Has qw/Plugins Created/;

sub tables      { my $self = shift; $self->{+DB}->tables($self->dbh, @_) }
sub table       { my $self = shift; $self->{+DB}->table($self->dbh, @_) }
sub db_keys     { my $self = shift; $self->{+DB}->db_keys($self->dbh, @_) }
sub indexes     { my $self = shift; $self->{+DB}->indexes($self->dbh, @_) }
sub column_type { my $self = shift; $self->{+DB}->column_type($self->dbh, $self->{+COLUMN_TYPE_CACHE}, @_) }
sub columns     { my $self = shift; $self->{+DB}->columns($self->dbh, $self->{+COLUMN_TYPE_CACHE}, @_) }

sub create_temp_view     { my $self = shift; $self->{+DB}->create_temp_view($self->dbh, @_) }
sub create_temp_table    { my $self = shift; $self->{+DB}->create_temp_table($self->dbh, @_) }
sub temp_table_supported { my $self = shift; $self->{+DB}->temp_table_supported($self->dbh, @_) }
sub temp_view_supported  { my $self = shift; $self->{+DB}->temp_view_supported($self->dbh, @_) }

sub start_txn          { my $self = shift; $self->{+TXN_DEPTH} += 1; $self->{+DB}->start_txn($self->dbh, @_) }
sub commit_txn         { my $self = shift; $self->{+TXN_DEPTH} -= 1; $self->{+DB}->commit_txn($self->dbh, @_) }
sub rollback_txn       { my $self = shift; $self->{+TXN_DEPTH} -= 1; $self->{+DB}->rollback_txn($self->dbh, @_) }
sub create_savepoint   { my $self = shift; $self->{+TXN_DEPTH} += 1; $self->{+DB}->create_savepoint($self->dbh, @_) }
sub commit_savepoint   { my $self = shift; $self->{+TXN_DEPTH} -= 1; $self->{+DB}->commit_savepoint($self->dbh, @_) }
sub rollback_savepoint { my $self = shift; $self->{+TXN_DEPTH} -= 1; $self->{+DB}->rollback_savepoint($self->dbh, @_) }

sub load_schema { my $self = shift; $self->{+DB}->load_schema($self->dbh, @_) }

sub init {
    my $self = shift;

    croak "A database is required"        unless $self->{+DB};
    croak "A database handle is required" unless $self->{+DBH};

    $self->{+PID}  //= $$;
    $self->{+SQLA} //= SQL::Abstract->new();

    $self->{+COLUMN_TYPE_CACHE} //= {};

    $self->{+TXN_DEPTH} = $self->dbh->{AutoCommit} ? 0 : 1;
}

sub dbh {
    my $self = shift;

    if ($$ != $self->{+PID}) {
        if ($self->{+DBH}) {
            confess "Forked while inside a transaction block"
                if $self->{+TXN_DEPTH};

            confess "Forked while inside a transaction"
                unless $self->{+DBH}->{AutoCommit};
        }

        confess "Attempt to reuse a connection in a forked process";
    }

    return $self->{+DBH};
}

sub transaction {
    my $self = shift;
    my ($code) = @_;

    # Make sure this gets loaded/reset
    my $dbh = $self->dbh;

    my $start_depth = $self->{+TXN_DEPTH};
    local $self->{+TXN_DEPTH} = $self->{+TXN_DEPTH};

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

    eval {
        if   ($sp) { $self->rollback_savepoint($sp) }
        else       { $self->rollback_txn }
        1;
    } or warn $@;

    die $err;
}

sub generate_schema {
    my $self = shift;
    return DBIx::QuickORM::Util::SchemaBuilder->generate_schema($self, $self->plugins);
}

sub generate_table_schema {
    my $self = shift;
    my ($name) = @_;

    my $table = $self->table($name, details => 1);
    return DBIx::QuickORM::Util::SchemaBuilder->generate_table($self, $table, $self->plugins);
}

1;

