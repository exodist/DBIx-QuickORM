package DBIx::QuickORM::Dialect::SQLite;
use strict;
use warnings;

our $VERSION = '0.000005';

use DBD::SQLite 1.0;

use Carp qw/croak/;
use DBIx::QuickORM::Affinity qw/affinity_from_type/;
use DBIx::QuickORM::Util qw/column_key/;

use parent 'DBIx::QuickORM::Dialect';
use DBIx::QuickORM::Util::HashBase;

use DBIx::QuickORM::Schema;
use DBIx::QuickORM::Schema::Table;
use DBIx::QuickORM::Schema::Table::Column;
use DBIx::QuickORM::Schema::View;
use DBIx::QuickORM::Schema::Link;

sub fallback_ver { 1 }
sub oldest_ver   { 1 }
sub latest_ver   { 1 }
sub dbi_driver   { 'DBD::SQLite' }
sub dialect_name { 'SQLite' }

sub version_search { 0 }

sub db_version { DBD::SQLite->VERSION }

sub dsn {
    my $self_or_class = shift;
    my ($db) = @_;

    my $driver = $db->dbi_driver // $self_or_class->dbi_driver;
    $driver =~ s/^DBD:://;

    my $db_name = $self_or_class->db_name;

    return "dbi:${driver}:dbname=${db_name}";
}

###############################################################################
# {{{ Schema Builder Code
###############################################################################

my %TABLE_TYPES = (
    'table' => 'DBIx::QuickORM::Schema::Table',
    'view'  => 'DBIx::QuickORM::Schema::View',
);

sub build_tables_from_db {
    my $self = shift;

    my $dbh = $self->{+DBH};

    my @queries = (
        "SELECT name, type, 0 FROM sqlite_schema      WHERE type IN ('table', 'view')",
        "SELECT name, type, 1 FROM sqlite_temp_schema WHERE type IN ('table', 'view')",
    );

    my %tables;

    for my $q (@queries) {
        my $sth = $dbh->prepare($q);
        $sth->execute();

        while (my ($tname, $type, $temp) = $sth->fetchrow_array) {
            next if $tname =~ m/^sqlite_/;

            #push @out => {name => $table, type => $type, temp => $temp};
            my $table = {name => $tname, db_name => $tname, is_temp => $temp};
            my $class = $TABLE_TYPES{lc($type)} // 'DBIx::QuickORM::Schema::Table';

            $table->{columns} = $self->build_columns_from_db($tname);
            $table->{indexes} = $self->build_indexes_from_db($tname);
            @{$table}{qw/primary_key unique _links/} = $self->build_table_keys_from_db($tname);

            $tables{$tname} = $class->new($table);
        }
    }

    return \%tables;
}

sub build_table_keys_from_db {
    my $self = shift;
    my ($table) = @_;

    my $dbh = $self->{+DBH};

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT il.name AS grp,
               origin  AS type,
               ii.name AS column
         FROM pragma_index_list(?)       AS il,
              pragma_index_info(il.name) AS ii
     ORDER BY seq, il.name, seqno, cid
    EOT

    $sth->execute($table);

    my ($pk, %unique, @links);

    my %index;
    while (my $row = $sth->fetchrow_hashref()) {
        my $idx = $index{$row->{grp}} //= {};
        $idx->{type} = $row->{type};
        push @{$idx->{cols} //= []} => $row->{column};
    }

    for my $idx (sort values %index) {
        $unique{column_key(@{$idx->{cols}})} = $idx->{cols};
        $pk = $idx->{cols} if $idx->{type} eq 'pk';
    }

    unless ($pk && @$pk) {
        my @found = $self->_primary_key($table);

        if (@found) {
            $pk = \@found;
            $unique{column_key(@found)} = \@found;
        }
        else {
            $pk = undef;
        }
    }

    %index = ();
    $sth = $dbh->prepare("SELECT `id`, `table`, `from`, `to` FROM pragma_foreign_key_list(?) order by id, seq");
    $sth->execute($table);
    while (my $row = $sth->fetchrow_hashref()) {
        my $idx = $index{$row->{id}} //= {};

        push @{$idx->{columns} //= []} => $row->{from};

        $idx->{ftable} //= $row->{table};
        push @{$idx->{fcolumns} //= []} => $row->{to};
    }

    @links = map { [[$table, $_->{columns}], [$_->{ftable}, $_->{fcolumns}]] } values %index;

    return($pk, \%unique, \@links);
}

sub build_columns_from_db {
    my $self = shift;
    my ($table) = @_;

    croak "A table name is required" unless $table;
    my $dbh = $self->{+DBH};

    my $sth = $dbh->prepare("SELECT * FROM pragma_table_info(?)");
    $sth->execute($table);

    my (%columns, @links);
    while (my $res = $sth->fetchrow_hashref) {
        my $col = {};
        $col->{name}    = $res->{name};
        $col->{db_name} = $res->{name};
        $col->{order}   = $res->{cid} + 1;

        my $type = $res->{type};
        $type =~ s/\(.*$//;
        $col->{type} = \$type;

        $col->{nullable} = $res->{notnull} ? 0 : 1;
        $col->{affinity} //= affinity_from_type($type) // 'string';

        $columns{$col->{name}} = DBIx::QuickORM::Schema::Table::Column->new($col);
    }

    return \%columns;
}

sub build_indexes_from_db {
    my $self = shift;
    my ($table) = @_;

    my $dbh = $self->dbh;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT il.`name`   AS name,
               il.`unique` AS u,
               ii.`name`   AS column
          FROM pragma_index_list(?)       AS il,
               pragma_index_info(il.name) AS ii
      ORDER BY il.name, ii.seqno
    EOT

    $sth->execute($table);

    my %out;
    while (my ($name, $u, $col) = $sth->fetchrow_array) {
        my $idx = $out{$name} //= {name => $name, columns => [], unique => $u ? 1 : 0};
        push @{$idx->{columns}} => $col;
    }

    if (my @pk = $self->_primary_key($table)) {
        $out{"${table}:pk"} = {name => "${table}:pk", unique => 1, columns => \@pk};
    }

    return [map { $out{$_} } sort keys %out];
}

sub _primary_key {
    my $self = shift;
    my ($table) = @_;

    my $sth = $self->dbh->prepare("SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk ASC");
    $sth->execute($table);

    my @out;
    while (my $row = $sth->fetchrow_hashref()) {
        push @out => $row->{name};
    }

    return @out;
}

###############################################################################
# }}} Schema Builder Code
###############################################################################

1;
