package DBIx::QuickORM::Test;
use strict;
use warnings;

use Test2::V0;
use Importer 'Test2::Tools::QuickDB' => (get_db => {-as => 'get_qdb'});
use Importer Importer => 'import';

use DBIx::QuickORM::Util qw/debug/;

#BEGIN {
#    $ENV{PATH} = "/home/exodist/percona/bin:$ENV{PATH}" if -d "/home/exodist/percona/bin";
#}

our @EXPORT = qw{
    psql
    mysql
    mariadb
    percona
    sqlite
    debug
};

sub psql    { my @args = @_; eval { get_qdb({driver => 'PostgreSQL', @args}) } or diag(clean_err($@)) }
sub mysql   { my @args = @_; eval { get_qdb({driver => 'MySQL',      @args}) } or diag(clean_err($@)) }
sub mariadb { my @args = @_; eval { get_qdb({driver => 'MariaDB',    @args}) } or diag(clean_err($@)) }
sub percona { my @args = @_; eval { get_qdb({driver => 'Percona',    @args}) } or diag(clean_err($@)) }
sub sqlite  { my @args = @_; eval { get_qdb({driver => 'SQLite',     @args}) } or diag(clean_err($@)) }

sub clean_err {
    my $err = shift;

    my @lines = split /\n/, $err;

    my $out = "";
    while (@lines) {
        my $line = shift @lines;
        next unless $line;
        last if $out && $line =~ m{^Aborting at.*DBIx/QuickDB\.pm};

        $out = $out ? "$out\n$line" : $line;
    }

    return $out;
}

1;
