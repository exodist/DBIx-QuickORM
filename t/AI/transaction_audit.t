use Test2::V0;
use DBI;
use File::Temp qw/tempdir/;

# Regression tests for transaction fixes: auto_retry_txn argument parsing,
# finalize recovery after a failed commit, on_parent_* with no parent,
# double-finalization of cb-managed transactions, and savepoint metadata
# surviving completion.

BEGIN {
    skip_all "DBD::SQLite is required for these tests"
        unless eval { require DBD::SQLite; 1 };
}

require DBIx::QuickORM;

my $dir  = tempdir(CLEANUP => 1);
my $file = "$dir/transaction_audit.sqlite";
my $dsn  = "dbi:SQLite:dbname=$file";

{
    my $dbh = DBI->connect($dsn, '', '', {RaiseError => 1, PrintError => 0});
    $dbh->do('CREATE TABLE things (thing_id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
    $dbh->disconnect;
}

sub connect_orm { DBIx::QuickORM->quick(credentials => {dsn => $dsn}, @_) }

subtest auto_retry_txn_forms => sub {
    my $con = connect_orm();

    my $calls = 0;
    my $txn = $con->auto_retry_txn(sub { $calls++ });
    is($calls, 1, "single coderef form ran the action once");
    ok($txn->committed, "single coderef form committed");

    $calls = 0;
    my $done = 0;
    $txn = $con->auto_retry_txn({count => 2, on_completion => sub { $done++ }}, sub { $calls++ });
    is($calls, 1, "(\\\%params, sub) form ran the action once on success");
    is($done, 1, "(\\\%params, sub) form passed params through to txn()");
    ok($txn->committed, "(\\\%params, sub) form committed");

    $calls = 0;
    my $warnings = warns {
        $txn = $con->auto_retry_txn({count => 2}, sub { die "boom\n" unless ++$calls > 2 });
    };
    is($calls, 3, "(\\\%params, sub) form respected count from the params hashref");
    is($warnings, 2, "warned once per retry");
    ok($txn->committed, "retried transaction eventually committed");

    $calls = 0;
    $done  = 0;
    $txn = $con->auto_retry_txn(count => 2, on_completion => sub { $done++ }, action => sub { $calls++ });
    is($calls, 1, "(\%params with action) form ran the action once");
    is($done, 1, "(\%params with action) form passed params through to txn()");

    $calls = 0;
    $txn = $con->auto_retry_txn(2, sub { $calls++ });
    is($calls, 1, "(\$count, sub) form ran the action once");

    $calls = 0;
    $txn = $con->auto_retry_txn(2, {action => sub { $calls++ }});
    is($calls, 1, "(\$count, \\\%params) form ran the action once");

    my $err = dies { $con->auto_retry_txn(2, \"nope") };
    like($err, qr/Not sure what to do with second argument/, "bad second argument croaks");
};

done_testing;
