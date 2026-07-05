use Test2::V0 '!meta', '!pass';
use DBI;
use File::Temp qw/tempdir/;

# The dialect auto-detects volatile columns during introspection: generated and
# identity/auto-increment columns are flagged volatile. Plain columns and
# columns that merely carry a server-side default are not auto-flagged (defaults
# are left to an explicit `volatile` marker).

BEGIN {
    skip_all "DBD::SQLite is required for these tests"
        unless eval { require DBD::SQLite; 1 };
}

require DBIx::QuickORM;

my $dir  = tempdir(CLEANUP => 1);
my $dsn  = "dbi:SQLite:dbname=$dir/vol.sqlite";
{
    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do(<<'    SQL');
        CREATE TABLE widgets (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            name       TEXT NOT NULL,
            status     TEXT NOT NULL DEFAULT 'new',
            full_label TEXT GENERATED ALWAYS AS (name || ':' || status) VIRTUAL
        )
    SQL
    $dbh->disconnect;
}

my $con    = DBIx::QuickORM->quick(credentials => {dsn => $dsn});
my $table  = $con->schema->table('widgets');

ok($table->column('id')->volatile,         "AUTOINCREMENT identity column is auto-volatile");
ok($table->column('full_label')->volatile, "generated column is auto-volatile");
ok(!$table->column('status')->volatile,    "a server-default column is NOT auto-volatile (mark it explicitly)");
ok(!$table->column('name')->volatile,      "a plain NOT NULL column with no default is not volatile");

done_testing;
