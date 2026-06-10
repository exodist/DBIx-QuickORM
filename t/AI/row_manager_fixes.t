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

subtest vivify_of_loaded_row_croaks => sub {
    my $row = $h->insert({name => 'loaded', color => 'red'});
    my $pk  = $row->field('gadget_id');

    like(
        dies { $h->vivify({gadget_id => $pk, name => 'shadow', color => 'blue'}) },
        qr/already loaded/,
        "vivify croaks when the primary key matches an already-loaded row",
    );

    is($row->field('color'), 'red', "the loaded row's data was not touched");

    ok(lives { $h->vivify({name => 'unloaded', color => 'green'}) }, "vivify without a conflicting primary key still works");
};

subtest find_or_insert => sub {
    my $count = db_count();

    my $made = $con->find_or_insert('gadgets', {name => 'felix', color => 'black'});
    ok($made, "got a row back");
    ok($made->is_stored, "row was inserted");
    is(db_count(), $count + 1, "one new database row");
    is($made->field('color'), 'black', "row has the supplied data");

    my $found = $con->find_or_insert('gadgets', {name => 'felix', color => 'black'});
    ref_is($found, $made, "second call found the existing row instead of inserting");
    is(db_count(), $count + 1, "no extra database row");
};

subtest update_or_insert => sub {
    my $count = db_count();

    # The upsert resolves conflicts on the primary key, so supply one.
    my $made = $con->update_or_insert('gadgets', {gadget_id => 1000, name => 'oscar', color => 'white'});
    ok($made, "got a row back");
    ok($made->is_stored, "row was inserted");
    is(db_count(), $count + 1, "one new database row");

    my $updated = $con->update_or_insert('gadgets', {gadget_id => 1000, name => 'oscar', color => 'grey'});
    ok($updated->is_stored, "still stored");
    is(db_count(), $count + 1, "no extra database row");
    is($updated->field('color'), 'grey', "conflicting row was updated");

    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
    my ($color) = $dbh->selectrow_array('SELECT color FROM gadgets WHERE gadget_id = 1000');
    $dbh->disconnect;
    is($color, 'grey', "database reflects the update");
};

done_testing;
