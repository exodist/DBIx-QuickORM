use Test2::V0 -target => 'DBIx::QuickORM', '!meta', '!pass';
use DBIx::QuickORM;

use Test2::Tools::QuickDB;
skipall_unless_can_db(driver => 'PostgreSQL');

use lib 't/lib';
use DBIx::QuickORM::Test;

my $psql_file = __FILE__;
$psql_file =~ s/\.t/.sql/;
my $psql = psql(load_sql => [quickdb => $psql_file]);

db mydb => sub {
    dialect 'PostgreSQL';
    db_name 'quickdb';
    connect sub { $psql->connect };
};

orm myorm => sub {
    db 'mydb';
    autofill;
};

my $orm = orm('myorm');
my $con = $orm->connect;
diag "Using dialect '" . $con->dialect->dialect_name . "'";

my $schema = $con->schema;

my $s = $orm->source('simple2');

my $one = $s->insert({simple2_id => 3});
ref_is($one, $s->one, "Same ref");
debug($one, $con->cache);
$one->update({simple2_id => 5});
debug($one, $con->cache);
$one->delete;
debug($one, $con->cache);

done_testing;
