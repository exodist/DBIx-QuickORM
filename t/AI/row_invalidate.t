use Test2::V0;
use DBI;
use File::Temp qw/tempdir/;

# Exercises row invalidation: RowManager->invalidate given only a row, and
# the refresh / lazy field fetch paths that invalidate a row whose database
# record no longer exists.

BEGIN {
    skip_all "DBD::SQLite is required for these tests"
        unless eval { require DBD::SQLite; 1 };
}

require DBIx::QuickORM;

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/invalidate.sqlite";
my $dsn  = "dbi:SQLite:dbname=$file";

{
    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE things (thing_id INTEGER PRIMARY KEY, name TEXT NOT NULL, notes TEXT)');
    $dbh->disconnect;
}

sub db_delete {
    my ($pk) = @_;
    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('DELETE FROM things WHERE thing_id = ?', undef, $pk);
    $dbh->disconnect;
}

my $con = DBIx::QuickORM->quick(credentials => {dsn => $dsn});
my $h   = $con->handle('things');

subtest invalidate_with_only_a_row => sub {
    my $row = $h->insert({name => 'goner'});
    my $pk  = $row->field('thing_id');

    ok($row->is_valid, "row starts valid");

    ok(
        lives { $con->state_invalidate(source => $con->source('things'), row => $row, reason => 'test invalidation') },
        "invalidate works when given only a row",
    );

    ok(!$row->is_valid, "row is invalid");
    like(dies { $row->field('name') }, qr/test invalidation/, "invalidation reason is reported");

    ok(!$con->state_cache_lookup('things', {thing_id => $pk}), "row was removed from the cache");
};

done_testing;
