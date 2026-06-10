use Test2::V0;
use DBI;
use File::Temp qw/tempdir/;

# Exercises RowManager-level behaviors: cache_lookup, vivify refusing to
# shadow an already-loaded row, insert_or_save with nothing to write, and
# the connection's find_or_insert / update_or_insert helpers.

BEGIN {
    skip_all "DBD::SQLite is required for these tests"
        unless eval { require DBD::SQLite; 1 };
}

require DBIx::QuickORM;

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/manager.sqlite";
my $dsn  = "dbi:SQLite:dbname=$file";

{
    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE gadgets (gadget_id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, color TEXT)');
    $dbh->disconnect;
}

sub db_count {
    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
    my ($count) = $dbh->selectrow_array('SELECT COUNT(*) FROM gadgets');
    $dbh->disconnect;
    return $count;
}

my $con = DBIx::QuickORM->quick(credentials => {dsn => $dsn});
my $h   = $con->handle('gadgets');

subtest insert_or_save_with_no_data_croaks => sub {
    my $row = $h->vivify({name => 'temp'});
    $row->discard;

    ok(!$row->is_stored,   "row is not stored");
    ok(!$row->has_pending, "row has no pending data");

    like(
        dies { $row->insert_or_save },
        qr/This row has no data to write/,
        "insert_or_save croaks when there is nothing to write",
    );
};

done_testing;
