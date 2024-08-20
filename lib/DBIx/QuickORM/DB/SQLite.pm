package DBIx::QuickORM::DB::SQLite;
use strict;
use warnings;

use Carp qw/croak/;
use DBD::SQLite;

use parent 'DBIx::QuickORM::DB';
use DBIx::QuickORM::Util::HashBase;

sub dbi_driver { 'DBD::SQLite' }

sub tables {
    my $self = shift;
    my %params = @_;

    my $dbh = $self->dbh;

    my @queries = (
        "SELECT name, type, 0 FROM sqlite_schema      WHERE type IN ('table', 'view')",
        "SELECT name, type, 1 FROM sqlite_temp_schema WHERE type IN ('table', 'view')",
    );

    my @out;

    for my $q (@queries) {
        my $sth = $dbh->prepare($q);
        $sth->execute();

        while (my ($table, $type, $temp) = $sth->fetchrow_array) {
            next if $table =~ m/^sqlite_/;

            if ($params{details}) {
                push @out => {name => $table, type => $type, temp => $temp};
            }
            else {
                push @out => $table;
            }
        }
    }

    return @out;
}

sub columns {
    my $self = shift;
    my ($table) = @_;

    croak "A table name is required" unless $table;

    my $dbh = $self->dbh;

    my $sth = $dbh->prepare("SELECT name, type FROM pragma_table_info(?)");

    $sth->execute($table);

    my @out;
    while (my $col = $sth->fetchrow_hashref) {
        $col->{is_datetime} = undef;
        push @out => $col;
    }

    return @out;
}

sub keys {
    my $self = shift;
    my ($table) = @_;

    croak "A table name is required" unless $table;

    my %out;

    my $dbh = $self->dbh;

    my $sth = $dbh->prepare(<<"    EOT");
        SELECT il.name AS grp,
               origin  AS type,
               ii.name AS column
         FROM pragma_index_list(?)       AS il,
              pragma_index_info(il.name) AS ii
     ORDER BY seq, il.name, seqno, cid
    EOT

    $sth->execute($table);

    my %index;
    while (my $row = $sth->fetchrow_hashref()) {
        my $idx = $index{$row->{grp}} //= {};
        $idx->{type} = $row->{type};
        push @{$idx->{cols} //= []} => $row->{column};
    }

    for my $idx (values %index) {
        push @{$out{unique} //= []} => $idx->{cols};
        $out{pk} = $idx->{cols} if $idx->{type} eq 'pk';
    }

    unless ($out{pk} && @{$out{pk}}) {
        $out{pk} //= [];
        my $sth = $dbh->prepare("SELECT name FROM pragma_table_info(?) WHERE pk > 0 ORDER BY pk ASC");
        $sth->execute($table);

        my $found = 0;
        while (my $row = $sth->fetchrow_hashref()) {
            $found++;
            push @{$out{pk}} => $row->{name};
        }

        if ($found) {
            push @{$out{unique} //= []} => $out{pk};
        }
        else {
            delete $out{pk};
        }
    }

    %index = ();
    $sth = $dbh->prepare("SELECT `id`, `table`, `from`, `to` FROM pragma_foreign_key_list(?) order by id, seq");
    $sth->execute($table);
    while (my $row = $sth->fetchrow_hashref()) {
        my $idx = $index{$row->{id}} //= {};

        push @{$idx->{columns} //= []} => $row->{from};

        $idx->{foreign_table} //= $row->{table};
        push @{$idx->{foreign_columns} //= []} => $row->{to};
    }

    $out{fk} = [values %index] if keys %index;

    return \%out;
}

1;
